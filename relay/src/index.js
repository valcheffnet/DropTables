// Takes an export string from the web page and opens a GitHub issue for the merge workflow, so players don't need a
// GitHub account to share. The Worker only checks the string's shape, and tools/check_export.py decodes and validates
// the issues later.

const MAX_BODY = 256 * 1024;
// The addon puts its install's secret export key after the dot. Only its hash goes into the public issue, and the
// merge pins the first hash of each install, so nobody can send an export as someone else's install.
const EXPORT_PATTERN = /^(DT1:[A-Za-z0-9+/]+={0,2})(?:\.([0-9a-f]{32}))?$/;
const MIN_EXPORT = 24;
const GITHUB_API = "https://api.github.com";
const USER_AGENT = "DropTables-Relay";

let cachedToken = null;
const cachedLatest = new Map();  // "owner/repo" -> { version, at } of its latest release
const LATEST_TTL = 10 * 60 * 1000;
const HEADER_BYTES = 4096;  // the header line is short, so no more than this is ever unpacked

function json(status, body) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
    });
}

function base64url(bytes) {
    let text = "";
    for (const byte of bytes) {
        text += String.fromCharCode(byte);
    }
    return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function hashHex(text) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

// GitHub hands out PKCS#1 keys, so the secret has to be converted to PKCS#8 once (see SETUP.md).
async function importKey(pem) {
    const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
    const der = Uint8Array.from(atob(body), (char) => char.charCodeAt(0));
    return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

async function appJwt(env, now) {
    const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
    const claims = { iat: now - 60, exp: now + 540, iss: String(env.APP_ID) };
    const payload = base64url(new TextEncoder().encode(JSON.stringify(claims)));
    const key = await importKey(env.APP_KEY);
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${payload}`));
    return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

// Installation tokens live for an hour, so we reuse one until five minutes before it runs out.
async function installationToken(env) {
    const now = Math.floor(Date.now() / 1000);
    if (cachedToken && cachedToken.expires - 300 > now) {
        return cachedToken.token;
    }
    const response = await fetch(`${GITHUB_API}/app/installations/${env.APP_INSTALLATION_ID}/access_tokens`, {
        method: "POST",
        headers: {
            authorization: `Bearer ${await appJwt(env, now)}`,
            accept: "application/vnd.github+json",
            "user-agent": USER_AGENT,
        },
    });
    if (!response.ok) {
        throw new Error(`installation token: ${response.status}`);
    }
    const data = await response.json();
    cachedToken = { token: data.token, expires: Math.floor(Date.parse(data.expires_at) / 1000) };
    return cachedToken.token;
}

async function turnstileOk(env, token, ip) {
    if (typeof token !== "string" || token.length === 0 || token.length > 2048) {
        return false;
    }
    const form = new FormData();
    form.append("secret", env.TURNSTILE_SECRET);
    form.append("response", token);
    if (ip) {
        form.append("remoteip", ip);
    }
    const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form });
    if (!response.ok) {
        return false;
    }
    const result = await response.json();
    return result.success === true;
}

// The same layout GitHub wrote for the old issue form, so the workflow reads either kind of issue.
// The addon version in the header line of an export, "DTX|1|<install id>|<version>|...", or null when it can't be read.
// Only the first bytes are unpacked.
async function exportVersion(data) {
    try {
        const bytes = Uint8Array.from(atob(data.slice(4)), (char) => char.charCodeAt(0));
        const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate")).getReader();
        const decoder = new TextDecoder();
        let text = "";
        while (!text.includes("\n") && text.length < HEADER_BYTES) {
            const { value, done } = await reader.read();
            if (done) {
                break;
            }
            text += decoder.decode(value, { stream: true });
        }
        reader.cancel().catch(() => {});
        const fields = text.split("\n", 1)[0].split("|");
        return fields[0] === "DTX" && /^\d+\.\d+\.\d+$/.test(fields[3]) ? fields[3] : null;
    } catch {
        return null;
    }
}

// The version of the latest release on GitHub, or null when GitHub can't say right now.
async function latestVersion(env) {
    const repo = `${env.REPO_OWNER}/${env.REPO_NAME}`;
    const cached = cachedLatest.get(repo);
    if (cached && Date.now() - cached.at < LATEST_TTL) {
        return cached.version;
    }
    try {
        const response = await fetch(`${GITHUB_API}/repos/${repo}/releases/latest`, {
            headers: {
                authorization: `Bearer ${await installationToken(env)}`,
                accept: "application/vnd.github+json",
                "user-agent": USER_AGENT,
            },
        });
        if (!response.ok) {
            return cached ? cached.version : null;
        }
        const match = /^v?(\d+\.\d+\.\d+)$/.exec((await response.json()).tag_name || "");
        const version = match ? match[1] : null;
        cachedLatest.set(repo, { version, at: Date.now() });
        return version;
    } catch {
        return cached ? cached.version : null;
    }
}

function older(version, than) {
    const a = version.split(".").map(Number);
    const b = than.split(".").map(Number);
    for (let i = 0; i < 3; i++) {
        if (a[i] !== b[i]) {
            return a[i] < b[i];
        }
    }
    return false;
}

function issueBody(data, keyHash) {
    const key = keyHash ? `Install key: \`${keyHash}\`\n\n` : "";
    return `### Export text\n\n\`\`\`text\n${data}\n\`\`\`\n\n${key}_Sent through the web page._\n`;
}

async function submit(request, env) {
    const length = Number(request.headers.get("content-length") || "0");
    if (!length || length > MAX_BODY) {
        return json(413, { error: "The text is too long. Paste one part at a time." });
    }
    const ip = request.headers.get("cf-connecting-ip") || "";
    const { success } = await env.SUBMIT_LIMIT.limit({ key: ip || "unknown" });
    if (!success) {
        return json(429, { error: "Too many tries in a short time. Wait a minute and send it again." });
    }
    let input;
    try {
        input = await request.json();
    } catch {
        return json(400, { error: "The request could not be read." });
    }
    const text = typeof input.data === "string" ? input.data.replace(/\s+/g, "") : "";
    const match = EXPORT_PATTERN.exec(text);
    const data = match ? match[1] : "";
    if (data.length < MIN_EXPORT) {
        return json(400, { error: "This is not Drop Tables export text. It starts with DT1: and is copied from /dt export." });
    }
    // Counts from an old version can miss what a newer one fixed, so the player updates and exports again first. When
    // GitHub can't say which version is the latest, the export goes through.
    const version = await exportVersion(data);
    const latest = version && (await latestVersion(env));
    if (latest && older(version, latest)) {
        return json(409, {
            error: `This text comes from Drop Tables ${version}, and ${latest} is out. Update the addon first, then `
                + "type /dt export in game again and send the new text.",
            update: `https://github.com/${env.REPO_OWNER}/${env.REPO_NAME}/releases/latest`,
        });
    }
    if (!(await turnstileOk(env, input.token, ip))) {
        return json(403, { error: "The check that you are not a bot failed. Reload the page and try again." });
    }
    const hash = await hashHex(data);
    const keyHash = match[2] ? await hashHex(`DropTables export key ${match[2]}`) : null;
    try {
        const response = await fetch(`${GITHUB_API}/repos/${env.REPO_OWNER}/${env.REPO_NAME}/issues`, {
            method: "POST",
            headers: {
                authorization: `Bearer ${await installationToken(env)}`,
                accept: "application/vnd.github+json",
                "content-type": "application/json",
                "user-agent": USER_AGENT,
            },
            body: JSON.stringify({ title: `Drop tables (web) ${hash.slice(0, 8)}`, body: issueBody(data, keyHash), labels: ["share", "relay"] }),
        });
        if (!response.ok) {
            console.error("create issue", response.status, await response.text());
            return json(502, { error: "GitHub did not take it right now. Try again later." });
        }
        // The page links to the issue, where the bot answers, so a sender without a GitHub account sees the outcome.
        const issue = await response.json();
        return json(200, { ok: true, issue: issue.number, url: issue.html_url });
    } catch (error) {
        console.error(error);
        return json(502, { error: "GitHub could not be reached. Try again later." });
    }
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        if (url.pathname === "/config" && request.method === "GET") {
            return json(200, { sitekey: env.TURNSTILE_SITEKEY });
        }
        if (url.pathname === "/submit") {
            if (request.method !== "POST") {
                return json(405, { error: "Use POST." });
            }
            return submit(request, env);
        }
        return env.ASSETS.fetch(request);
    },
};

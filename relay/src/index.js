// Takes an export string from the web page and opens the same GitHub issue the share form would,
// so players without a GitHub account can share. The string is checked for shape only; decoding
// and validation happen in the repository's Actions workflow.

const MAX_BODY = 256 * 1024;
const EXPORT_PATTERN = /^DT1:[A-Za-z0-9+/]+={0,2}$/;
const MIN_EXPORT = 24;
const GITHUB_API = "https://api.github.com";
const USER_AGENT = "DropTables-Relay";

let cachedToken = null;

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

// GitHub hands out PKCS#1 keys; the secret must be converted to PKCS#8 once (see SETUP.md).
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

// Installation tokens live for an hour; one is reused until five minutes before it runs out.
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

// Same layout GitHub writes for the issue form, so the workflow reads both kinds of issue alike.
function issueBody(data) {
    return `### Export text\n\n\`\`\`text\n${data}\n\`\`\`\n\n_Sent through the web page._\n`;
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
    const data = typeof input.data === "string" ? input.data.replace(/\s+/g, "") : "";
    if (data.length < MIN_EXPORT || !EXPORT_PATTERN.test(data)) {
        return json(400, { error: "This is not Drop Tables export text. It starts with DT1: and is copied from /dt export." });
    }
    if (!(await turnstileOk(env, input.token, ip))) {
        return json(403, { error: "The check that you are not a bot failed. Reload the page and try again." });
    }
    const hash = await hashHex(data);
    try {
        const response = await fetch(`${GITHUB_API}/repos/${env.REPO_OWNER}/${env.REPO_NAME}/issues`, {
            method: "POST",
            headers: {
                authorization: `Bearer ${await installationToken(env)}`,
                accept: "application/vnd.github+json",
                "content-type": "application/json",
                "user-agent": USER_AGENT,
            },
            body: JSON.stringify({ title: `Drop tables (web) ${hash.slice(0, 8)}`, body: issueBody(data), labels: ["share", "relay"] }),
        });
        if (!response.ok) {
            console.error("create issue", response.status, await response.text());
            return json(502, { error: "GitHub did not take it right now. Try again later." });
        }
    } catch (error) {
        console.error(error);
        return json(502, { error: "GitHub could not be reached. Try again later." });
    }
    return json(200, { ok: true });
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

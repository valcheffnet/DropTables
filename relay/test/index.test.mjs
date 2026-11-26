import { test } from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import worker from "../src/index.js";

const EXPORT = "DT1:" + "eJzLSM3JyVcozy/KSQEAGgQEXQ".repeat(3) + "==";

async function makeKey() {
    const pair = await crypto.subtle.generateKey(
        { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
        true,
        ["sign", "verify"],
    );
    const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(der).toString("base64")}\n-----END PRIVATE KEY-----\n`;
    return { pem, publicKey: pair.publicKey };
}

const { pem, publicKey } = await makeKey();

function makeEnv(overrides = {}) {
    return {
        APP_ID: "123",
        APP_INSTALLATION_ID: "456",
        APP_KEY: pem,
        REPO_OWNER: "owner",
        REPO_NAME: "repo",
        TURNSTILE_SECRET: "secret",
        TURNSTILE_SITEKEY: "sitekey",
        SUBMIT_LIMIT: { limit: async () => ({ success: true }) },
        ASSETS: { fetch: async () => new Response("page") },
        ...overrides,
    };
}

// Records every outgoing call and answers like Turnstile and GitHub would.
function mockFetch({ turnstile = true, issueStatus = 201, latest = null } = {}) {
    const calls = [];
    globalThis.fetch = async (url, init = {}) => {
        calls.push({ url: String(url), init });
        if (String(url).endsWith("/releases/latest")) {
            return latest ? Response.json({ tag_name: latest }) : Response.json({}, { status: 404 });
        }
        if (String(url).includes("siteverify")) {
            return Response.json({ success: turnstile });
        }
        if (String(url).includes("/access_tokens")) {
            return Response.json({ token: "inst-token", expires_at: new Date(Date.now() + 3600e3).toISOString() }, { status: 201 });
        }
        if (String(url).endsWith("/issues")) {
            const issue = { number: 12, html_url: "https://github.com/owner/repo/issues/12" };
            return Response.json(issueStatus < 300 ? issue : {}, { status: issueStatus });
        }
        throw new Error(`unexpected fetch ${url}`);
    };
    return calls;
}

function post(body, headers = {}) {
    const text = typeof body === "string" ? body : JSON.stringify(body);
    return new Request("https://relay.example/submit", {
        method: "POST",
        headers: { "content-type": "application/json", "content-length": String(text.length), "cf-connecting-ip": "1.2.3.4", ...headers },
        body: text,
    });
}

function decode(part) {
    return JSON.parse(Buffer.from(part, "base64url").toString());
}

test("config hands out the Turnstile site key", async () => {
    const response = await worker.fetch(new Request("https://relay.example/config"), makeEnv());
    assert.deepEqual(await response.json(), { sitekey: "sitekey" });
});

test("other paths go to the static page", async () => {
    const response = await worker.fetch(new Request("https://relay.example/"), makeEnv());
    assert.equal(await response.text(), "page");
});

test("submit only takes POST", async () => {
    const response = await worker.fetch(new Request("https://relay.example/submit"), makeEnv());
    assert.equal(response.status, 405);
});

test("a body over the size cap is refused before anything else", async () => {
    const calls = mockFetch();
    const response = await worker.fetch(post({ data: EXPORT }, { "content-length": String(300 * 1024) }), makeEnv());
    assert.equal(response.status, 413);
    assert.equal(calls.length, 0);
});

test("rate limited clients get 429", async () => {
    const calls = mockFetch();
    const keys = [];
    const env = makeEnv({ SUBMIT_LIMIT: { limit: async ({ key }) => { keys.push(key); return { success: false }; } } });
    const response = await worker.fetch(post({ data: EXPORT, token: "t" }), env);
    assert.equal(response.status, 429);
    assert.deepEqual(keys, ["1.2.3.4"], "limited per client address");
    assert.equal(calls.length, 0);
});

test("text that is not an export string is refused", async () => {
    for (const data of ["hello", "DT1:abc", "DT2:" + "A".repeat(40), "DT1:" + "A".repeat(40) + "<script>", 42]) {
        const calls = mockFetch();
        const response = await worker.fetch(post({ data, token: "t" }), makeEnv());
        assert.equal(response.status, 400, String(data));
        assert.equal(calls.length, 0);
    }
});

test("invalid JSON is refused", async () => {
    mockFetch();
    const response = await worker.fetch(post("{not json"), makeEnv());
    assert.equal(response.status, 400);
});

test("a failed Turnstile check stops the issue", async () => {
    const calls = mockFetch({ turnstile: false });
    const response = await worker.fetch(post({ data: EXPORT, token: "t" }), makeEnv());
    assert.equal(response.status, 403);
    assert.ok(!calls.some((call) => call.url.endsWith("/issues")));
});

test("a missing token never reaches Turnstile", async () => {
    const calls = mockFetch();
    const response = await worker.fetch(post({ data: EXPORT }), makeEnv());
    assert.equal(response.status, 403);
    assert.equal(calls.length, 0);
});

test("a valid export opens an issue in the form's layout, signed by the app", async () => {
    const calls = mockFetch();
    const spaced = EXPORT.slice(0, 20) + "\n  " + EXPORT.slice(20) + "\n";
    const response = await worker.fetch(post({ data: spaced, token: "t" }), makeEnv());
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true, issue: 12, url: "https://github.com/owner/repo/issues/12" },
        "the page gets the issue to link to");

    const tokenCall = calls.find((call) => call.url.endsWith("/app/installations/456/access_tokens"));
    const [header, payload, signature] = tokenCall.init.headers.authorization.replace("Bearer ", "").split(".");
    assert.equal(decode(header).alg, "RS256");
    const claims = decode(payload);
    assert.equal(claims.iss, "123");
    const now = Math.floor(Date.now() / 1000);
    assert.ok(claims.iat <= now - 59, "issued in the past to allow for clock drift");
    assert.ok(claims.exp - now <= 600, "GitHub rejects tokens that live over 10 minutes");
    const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, Buffer.from(signature, "base64url"),
        new TextEncoder().encode(`${header}.${payload}`));
    assert.ok(valid, "JWT signature verifies with the app's public key");

    const issueCall = calls.find((call) => call.url === "https://api.github.com/repos/owner/repo/issues");
    assert.equal(issueCall.init.headers.authorization, "Bearer inst-token");
    const issue = JSON.parse(issueCall.init.body);
    assert.ok(issue.body.includes("### Export text\n\n```text\n" + EXPORT + "\n```"));
    assert.deepEqual(issue.labels, ["share", "relay"]);
    assert.match(issue.title, /^Drop tables \(web\) [0-9a-f]{8}$/);

    const verify = calls.find((call) => call.url.includes("siteverify"));
    assert.equal(verify.init.body.get("remoteip"), "1.2.3.4");
});

test("the installation token is reused while it is valid", async () => {
    const calls = mockFetch();
    const response = await worker.fetch(post({ data: EXPORT, token: "t" }), makeEnv());
    assert.equal(response.status, 200);
    assert.ok(!calls.some((call) => call.url.includes("/access_tokens")));
});

test("a GitHub error comes back as 502", async () => {
    mockFetch({ issueStatus: 500 });
    const original = console.error;
    console.error = () => {};
    const response = await worker.fetch(post({ data: EXPORT, token: "t" }), makeEnv());
    console.error = original;
    assert.equal(response.status, 502);
});

test("the install's export key never reaches the issue, only its hash", async () => {
    const calls = mockFetch();
    const key = "0123456789abcdef".repeat(2);
    const response = await worker.fetch(post({ data: `${EXPORT}.${key}`, token: "t" }), makeEnv());
    assert.equal(response.status, 200);
    const issue = JSON.parse(calls.find((call) => call.url.endsWith("/issues")).init.body);
    assert.ok(issue.body.includes("```text\n" + EXPORT + "\n```"), "the export text goes in without the key");
    assert.ok(!issue.body.includes(key), "the key itself stays out");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`DropTables export key ${key}`));
    const hash = Buffer.from(digest).toString("hex");
    assert.ok(issue.body.includes("Install key: `" + hash + "`"), "its hash goes in for the merge to pin");
});

test("an export from an addon without a key opens an issue without one", async () => {
    const calls = mockFetch();
    await worker.fetch(post({ data: EXPORT, token: "t" }), makeEnv());
    const issue = JSON.parse(calls.find((call) => call.url.endsWith("/issues")).init.body);
    assert.ok(!issue.body.includes("Install key"));
});

test("a key that isn't 32 hex digits is refused", async () => {
    mockFetch();
    for (const tail of [".xyz", ".0123456789abcdef", "." + "0".repeat(33)]) {
        const response = await worker.fetch(post({ data: EXPORT + tail, token: "t" }), makeEnv());
        assert.equal(response.status, 400, tail);
    }
});

function exportOf(version) {
    const text = `DTX|1|0123456789abcdef|${version}|1795000000|1/1
@0123456789abcdef
M1.1.1.1.1.0.0..
`;
    return "DT1:" + deflateSync(Buffer.from(text)).toString("base64");
}

test("an export from an older version is refused with a link to the latest", async () => {
    const calls = mockFetch({ latest: "v0.6.5" });
    const response = await worker.fetch(post({ data: exportOf("0.6.3"), token: "t" }), makeEnv());
    assert.equal(response.status, 409);
    const body = await response.json();
    assert.match(body.error, /0\.6\.3, and 0\.6\.5 is out\. Update the addon first/);
    assert.equal(body.update, "https://github.com/owner/repo/releases/latest");
    assert.ok(!calls.some((call) => call.url.endsWith("/issues")), "no issue is opened");
    assert.ok(!calls.some((call) => call.url.includes("siteverify")), "and the Turnstile check isn't spent");
});

test("an export from the latest version or a newer one goes through", async () => {
    for (const version of ["0.6.5", "0.6.10", "1.0.0"]) {
        mockFetch({ latest: "v0.6.5" });
        const response = await worker.fetch(post({ data: exportOf(version), token: "t" }), makeEnv());
        assert.equal(response.status, 200, version);
    }
});

test("versions compare by number, so 0.6.10 is newer than 0.6.9", async () => {
    mockFetch({ latest: "v0.6.10" });
    const response = await worker.fetch(post({ data: exportOf("0.6.9"), token: "t" }), makeEnv({ REPO_NAME: "other" }));
    assert.equal(response.status, 409);
});

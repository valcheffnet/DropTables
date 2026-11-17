import { test } from "node:test";
import assert from "node:assert/strict";
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
function mockFetch({ turnstile = true, issueStatus = 201 } = {}) {
    const calls = [];
    globalThis.fetch = async (url, init = {}) => {
        calls.push({ url: String(url), init });
        if (String(url).includes("siteverify")) {
            return Response.json({ success: turnstile });
        }
        if (String(url).includes("/access_tokens")) {
            return Response.json({ token: "inst-token", expires_at: new Date(Date.now() + 3600e3).toISOString() }, { status: 201 });
        }
        if (String(url).endsWith("/issues")) {
            return new Response("{}", { status: issueStatus });
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

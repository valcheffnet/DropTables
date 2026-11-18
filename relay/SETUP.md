# Share page setup

The share page lets players send their `/dt export` text without a GitHub account. It is a Cloudflare Worker on the free plan: it checks the text, asks Cloudflare Turnstile whether the visitor is a person, and opens a GitHub issue with the labels `share` and `relay`. The workflow `.github/workflows/merge-shares.yml` takes the issue in, adds the counts to the shared database and closes it. A GitHub App owned by the valcheffnet organization writes the issue, so nothing depends on one person's token.

Everything below is done once. After that, a push to `main` that touches `relay/` deploys the page through `.github/workflows/deploy-relay.yml`, and anyone who is an owner of the organization can redo any step.

## 1. Cloudflare account

Sign up at cloudflare.com with an email address meant for the project, not a personal one, and turn on two-factor authentication. Keep the recovery codes where a second maintainer can get to them. Later, add that maintainer under Manage Account, Members.

Note the Account ID (shown on the account home page, right side).

## 2. Turnstile widget

In the Cloudflare dashboard open Turnstile, Add widget. Name it Drop Tables share, mode Managed, and add the hostname `droptables-relay.<your-subdomain>.workers.dev`. The subdomain is shown under Workers & Pages, the first time you open it. You get a site key (public) and a secret key.

## 3. Cloudflare API token

Manage Account, Account API Tokens, Create Token, template Edit Cloudflare Workers. Leave the expiry empty. An account token keeps working when the person who made it leaves.

## 4. GitHub App

In the valcheffnet organization: Settings, Developer settings, GitHub Apps, New GitHub App.

- Name: Drop Tables Share. Homepage URL: the repository.
- Webhook: off.
- Repository permissions: Issues, Read and write. Nothing else.
- Where can it be installed: Only on this account.

After creating it, note the App ID, then Generate a private key. GitHub gives a PKCS#1 key and the Worker needs PKCS#8, so convert it once:

```
openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in downloaded-key.pem -out app-key-pkcs8.pem
```

Install the app on the DropTables repository only. The installation ID is the number at the end of the page address after installing (`.../installations/<id>`).

In the repository, create the labels `share` and `relay` if they don't exist yet.

## 5. Secrets and variables

Repository (or organization) Settings, Secrets and variables, Actions.

Secrets:

| Name | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | token from step 3 |
| `CLOUDFLARE_ACCOUNT_ID` | Account ID from step 1 |
| `RELAY_APP_KEY` | whole content of `app-key-pkcs8.pem` |
| `TURNSTILE_SECRET` | Turnstile secret key |

Variables:

| Name | Value |
|---|---|
| `RELAY_APP_ID` | App ID |
| `RELAY_INSTALLATION_ID` | installation ID |
| `TURNSTILE_SITEKEY` | Turnstile site key |

Delete the downloaded key files afterwards. A new key can be generated in the app settings at any time; an app can hold several, so swapping one causes no downtime.

## 6. Deploy

Actions, Deploy share page, Run workflow. The log shows the page address. Open it, paste an export and check that an issue with the `relay` label shows up.

## Limits and what to watch

- Free plan: 100,000 requests a day. Past that the Worker answers with an error until midnight UTC; nothing gets billed.
- Each address may send 10 times a minute. Change it in `wrangler.jsonc` (`ratelimits`).
- The Worker only checks the shape of the text. `tools/check_export.py` decodes and validates it. The same text sent twice opens two issues, so merging has to skip duplicates.
- If the Cloudflare account is lost, make a new one, repeat steps 1 to 3, put the new values into the secrets and run the deploy again. The page address changes, so the link in the addon has to change too.

## Tests

```
cd relay
node --test "test/*.test.mjs"
```

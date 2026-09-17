# Cloudflare Web Deployment

This guide creates a private, password-protected transcription website on
Cloudflare Workers. It uses Workers AI for transcription and Workers KV for
encrypted transcripts that expire after 24 hours.

## Requirements

- A Cloudflare account with Workers AI enabled
- Node.js 20 or newer
- Wrangler authentication (`npx wrangler login`)

Cloudflare secrets are entered through Wrangler and are never committed to Git.
Free Workers AI allowance is account-wide, so multiple sites under one account
share the same daily allowance.

## Create a site from the template

Copy either `StealthWhisperWeb/` or `SisterWhisperWeb/` to a new directory. Do
not copy `node_modules/`. Then change these values:

1. Set a unique Worker `name` in `wrangler.jsonc`.
2. Change the visible title and brand in `src/content.ts`.
3. Change the storage salt prefix in `src/storage.ts` so copied sites do not
   reuse the same encryption context.
4. Create a dedicated KV namespace:

```sh
cd YourWhisperWeb
npm install
npx wrangler kv namespace create your-whisper-data
```

Copy the returned namespace ID into the `DATA` binding in `wrangler.jsonc`.
Never reuse another person's KV namespace.

## Configure private secrets

Generate two independent random values and choose a website password:

```sh
openssl rand -hex 32
openssl rand -hex 32
npx wrangler secret put SITE_PASSWORD
npx wrangler secret put AUTH_SECRET
npx wrangler secret put SHORTCUT_TOKEN
```

- `SITE_PASSWORD` unlocks the website.
- `AUTH_SECRET` signs sessions and encrypts stored settings and transcripts.
- `SHORTCUT_TOKEN` authorizes uploads from an iPhone Shortcut.

Use a different set for every site. Changing `AUTH_SECRET` invalidates existing
sessions and makes previously stored encrypted records unreadable, so delete old
KV records when rotating it.

## Test and deploy

```sh
npm test
npm run check
npx wrangler deploy --dry-run
npm run deploy
```

Wrangler prints the final `https://<worker>.<subdomain>.workers.dev` URL. Open
it in a private browser window and confirm that a wrong password is rejected,
the correct password opens the app, and refresh keeps the session.

## Create the iPhone Shortcut

Create a Shortcut that accepts files and media from the Share Sheet:

1. Add **Get Contents of URL**.
2. Use `POST` with the URL `https://<worker>.<subdomain>.workers.dev/api/transcribe`.
3. Set the request body to **File** and pass the Shortcut Input directly.
4. Add header `Authorization` with value `Bearer <SHORTCUT_TOKEN>`.
5. Add header `Content-Type` using the shared file's media type, or use
   `application/octet-stream`.
6. Add header `X-Filename` containing the URL-encoded file name.
7. Show the returned `text` value or open the website to view recent results.

From Voice Memos, open a synced recording, tap Share, and select the Shortcut.
Apple Watch recordings normally reach the Shortcut through Voice Memos sync on
the paired iPhone; the website does not access the Watch directly.

## Telegram delivery

Telegram is optional. After logging in, open Settings and enter a bot token and
chat ID. They are encrypted before storage. Delete the connection from the same
screen to remove those saved settings.

## Privacy and operational limits

- Original audio is not written to Worker storage.
- Completed transcripts are encrypted and use a 24-hour KV expiration.
- The browser keeps a local 24-hour copy so refresh does not immediately lose a
  completed result while KV propagates.
- Each upload is limited to 20 MiB to fit Worker memory during Base64 encoding.
- Failed transcription requires uploading the original recording again.
- Cloudflare may retain platform-level security or billing metadata even though
  the application does not save the audio.

For stronger separation between people, use separate Cloudflare accounts as
well as separate Workers, KV namespaces, passwords, and secrets.

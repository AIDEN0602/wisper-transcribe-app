# Sister Whisper

Private Cloudflare Worker for audio transcription. It accepts an audio file from the password-protected web UI or an iPhone Shortcut and transcribes it with `@cf/openai/whisper-large-v3-turbo`.

Original audio is held only in memory for the active request and is never written to storage. Completed transcripts are encrypted with AES-GCM, stored in Workers KV for 24 hours, and then deleted automatically by KV expiration. The browser also caches its own completed responses for at most 24 hours so an immediate refresh does not lose a result while KV propagates. Invocation logs are disabled. If a request fails, upload the original again from Voice Memos/iCloud.

## Configure

```sh
npm install
npx wrangler kv namespace create sister-whisper-data
# Copy the returned namespace ID into wrangler.jsonc before deployment.
npx wrangler secret put SITE_PASSWORD
npx wrangler secret put AUTH_SECRET
npx wrangler secret put SHORTCUT_TOKEN
npm run deploy
```

Cloudflare secrets are not stored in the repository. Optional Telegram credentials can be entered on the authenticated settings screen; they are AES-GCM encrypted before being stored in KV and can be deleted there at any time.

## iPhone Shortcut

The shortcut is named **Sister Whisper** and accepts audio or media from the iOS share sheet.

1. Open the synced recording in iPhone Voice Memos.
2. Tap `…`, then Share.
3. Choose **Sister Whisper**.
4. The shortcut sends the recording as the HTTP request body with these headers:
   - `Authorization: Bearer <SHORTCUT_TOKEN>`
   - `Content-Type`: the shared file's media type, or `application/octet-stream`
   - `X-Filename`: the URL-encoded file name

The web service limits each file to 20 MiB to remain within the Worker's 128 MiB memory limit while Base64-encoding audio. Split or compress larger recordings before upload. The intended free-tier usage is about three total audio hours per day.

## Verify

```sh
npm test
npm run check
npx wrangler deploy --dry-run
```

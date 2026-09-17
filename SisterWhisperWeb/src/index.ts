import { Buffer } from "node:buffer";
import { appPage, appScript, loginPage, styles } from "./content";
import { createSession, expiredSessionCookie, readCookie, secureEqual, sessionCookie, verifySession } from "./security";
import { decryptJson, encryptJson } from "./storage";

export interface Env {
  AI: Ai;
  DATA: KVNamespace;
  SITE_PASSWORD: string;
  AUTH_SECRET: string;
  SHORTCUT_TOKEN: string;
}

interface StoredJob { filename: string; text: string; createdAt: number; expiresAt: number; telegramDelivered: boolean }
interface TelegramSettings { botToken: string; chatId: string }

const MAX_AUDIO_BYTES = 20 * 1024 * 1024;
const RETENTION_SECONDS = 24 * 60 * 60;
const TELEGRAM_KEY = "settings:telegram";
const ALLOWED_EXTENSIONS = new Set(["aac", "caf", "flac", "m4a", "mp3", "mp4", "ogg", "wav", "webm"]);
const SECURITY_HEADERS: HeadersInit = {
  "Cache-Control": "no-store, max-age=0",
  "Content-Security-Policy": "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

function response(body: BodyInit | null, init: ResponseInit = {}): Response {
  const headers = new Headers(init.headers);
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) if (!headers.has(name)) headers.set(name, value);
  return new Response(body, { ...init, headers });
}
function html(body: string): Response { return response(body, { headers: { "Content-Type": "text/html; charset=utf-8" } }); }
function json(body: unknown, status = 200): Response { return response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } }); }
function redirect(location: string, cookie?: string): Response { const headers = new Headers({ Location: location }); if (cookie) headers.set("Set-Cookie", cookie); return response(null, { status: 303, headers }); }

export function safeFilename(raw: string | null): string {
  let decoded = raw ?? "recording.m4a";
  try { decoded = decodeURIComponent(decoded); } catch { decoded = "recording.m4a"; }
  const name = decoded.split(/[\\/]/).pop() ?? "recording.m4a";
  const cleaned = name.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 120);
  return cleaned || "recording.m4a";
}
function supportedAudio(request: Request, filename: string): boolean {
  const type = (request.headers.get("Content-Type") ?? "").split(";", 1)[0].toLowerCase();
  const extension = filename.includes(".") ? filename.split(".").pop()!.toLowerCase() : "";
  return type.startsWith("audio/") || type === "video/mp4" || (type === "application/octet-stream" && ALLOWED_EXTENSIONS.has(extension));
}
async function authorized(request: Request, env: Env, allowShortcut = true): Promise<boolean> {
  if (allowShortcut) {
    const bearer = request.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
    if (bearer && await secureEqual(bearer, env.SHORTCUT_TOKEN)) return true;
  }
  return verifySession(readCookie(request, "sw_session"), env.AUTH_SECRET);
}
function transcriptName(audioName: string): string {
  const base = audioName.replace(/\.[^.]+$/, "").replace(/[^\p{L}\p{N} _.-]/gu, "_").slice(0, 80) || "transcript";
  return `${base}.txt`;
}
async function telegramSettings(env: Env): Promise<TelegramSettings | null> {
  const encrypted = await env.DATA.get(TELEGRAM_KEY);
  if (!encrypted) return null;
  try { return await decryptJson<TelegramSettings>(encrypted, env.AUTH_SECRET); } catch { return null; }
}
async function sendTelegram(text: string, audioName: string, settings: TelegramSettings | null): Promise<boolean> {
  if (!settings) return false;
  const form = new FormData();
  form.set("chat_id", settings.chatId);
  form.set("caption", `위스퍼 전사 완료 · ${audioName}`.slice(0, 1024));
  form.set("document", new Blob([text], { type: "text/plain;charset=utf-8" }), transcriptName(audioName));
  const endpoint = `https://api.telegram.org/bot${settings.botToken}/sendDocument`;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try { const result = await fetch(endpoint, { method: "POST", body: form }); if (result.ok && ((await result.json()) as { ok?: boolean }).ok) return true; } catch { /* Never log credentials or transcript content. */ }
  }
  return false;
}
async function storeJob(job: StoredJob, env: Env): Promise<string> {
  const key = `job:${String(job.createdAt).padStart(13, "0")}:${crypto.randomUUID()}`;
  await env.DATA.put(key, await encryptJson(job, env.AUTH_SECRET), { expirationTtl: RETENTION_SECONDS });
  return key;
}
async function listJobs(env: Env): Promise<Array<StoredJob & { key: string }>> {
  const listed = await env.DATA.list({ prefix: "job:", limit: 100 });
  const jobs = await Promise.all(listed.keys.map(async ({ name }) => {
    const encrypted = await env.DATA.get(name);
    if (!encrypted) return null;
    try { return { ...(await decryptJson<StoredJob>(encrypted, env.AUTH_SECRET)), key: name }; } catch { return null; }
  }));
  return jobs.filter((job): job is StoredJob & { key: string } => Boolean(job)).sort((a, b) => b.createdAt - a.createdAt);
}

async function transcribe(request: Request, env: Env): Promise<Response> {
  if (!await authorized(request, env)) return json({ ok: false, message: "인증이 필요합니다." }, 401);
  const declaredLength = Number(request.headers.get("Content-Length") ?? "0");
  if (declaredLength > MAX_AUDIO_BYTES) return json({ ok: false, message: "파일당 최대 크기는 20MB입니다." }, 413);
  const filename = safeFilename(request.headers.get("X-Filename"));
  if (!supportedAudio(request, filename)) return json({ ok: false, message: "지원하는 음성 파일을 선택해 주세요." }, 415);
  const audio = await request.arrayBuffer();
  if (!audio.byteLength) return json({ ok: false, message: "빈 파일은 전사할 수 없습니다." }, 400);
  if (audio.byteLength > MAX_AUDIO_BYTES) return json({ ok: false, message: "파일당 최대 크기는 20MB입니다." }, 413);
  try {
    const result = await env.AI.run("@cf/openai/whisper-large-v3-turbo", { audio: Buffer.from(audio).toString("base64"), task: "transcribe", vad_filter: true, condition_on_previous_text: false, no_speech_threshold: 0.6, compression_ratio_threshold: 2.4, hallucination_silence_threshold: 2 });
    const text = result.text?.trim();
    if (!text) return json({ ok: false, message: "음성을 찾지 못했습니다. 원본을 확인해 주세요." }, 422);
    const createdAt = Date.now(), expiresAt = createdAt + RETENTION_SECONDS * 1000;
    const telegramDelivered = await sendTelegram(text, filename, await telegramSettings(env));
    let key: string | null = null;
    try { key = await storeJob({ filename, text, createdAt, expiresAt, telegramDelivered }, env); } catch { /* The result can still be copied from this response. */ }
    const url = new URL(request.url);
    if (url.searchParams.get("shortcut") === "1") return response(text, { headers: { "Content-Type": "text/plain; charset=utf-8", "X-Telegram-Delivered": String(telegramDelivered) } });
    return json({ ok: true, key, filename, text, createdAt, expiresAt, telegramDelivered, persisted: Boolean(key) });
  } catch (error) {
    const detail = error instanceof Error ? error.message.toLowerCase() : "";
    if (/limit|quota|rate|429|neuron/.test(detail)) {
      return json({ ok: false, message: "오늘의 무료 전사 한도에 도달했습니다. 내일 다시 시도해 주세요." }, 429);
    }
    return json({ ok: false, message: "전사 처리에 실패했습니다. 원본은 저장되지 않았으니 잠시 후 다시 보내 주세요." }, 502);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/assets/styles.css") return response(styles, { headers: { "Content-Type": "text/css; charset=utf-8", "Cache-Control": "no-cache" } });
    if (request.method === "GET" && url.pathname === "/assets/app.js") return response(appScript, { headers: { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "no-cache" } });
    if (request.method === "POST" && url.pathname === "/login") { const form = await request.formData(); if (!await secureEqual(String(form.get("password") ?? ""), env.SITE_PASSWORD)) return redirect("/?error=1"); return redirect("/", sessionCookie(await createSession(env.AUTH_SECRET))); }
    if (request.method === "POST" && url.pathname === "/logout") return redirect("/", expiredSessionCookie());
    if (request.method === "POST" && url.pathname === "/api/transcribe") return transcribe(request, env);
    if (url.pathname === "/api/jobs" && request.method === "GET") { if (!await authorized(request, env, false)) return json({ ok: false }, 401); return json({ ok: true, jobs: await listJobs(env) }); }
    if (url.pathname.startsWith("/api/jobs/") && request.method === "DELETE") { if (!await authorized(request, env, false)) return json({ ok: false }, 401); const key = decodeURIComponent(url.pathname.slice("/api/jobs/".length)); if (!/^job:\d{13}:[0-9a-f-]{36}$/.test(key)) return json({ ok: false }, 400); await env.DATA.delete(key); return json({ ok: true }); }
    if (url.pathname === "/api/settings" && request.method === "GET") { if (!await authorized(request, env, false)) return json({ ok: false }, 401); const value = await telegramSettings(env); return json({ ok: true, telegramConfigured: Boolean(value), chatIdHint: value ? `••••${value.chatId.slice(-4)}` : null }); }
    if (url.pathname === "/api/settings/telegram" && request.method === "PUT") { if (!await authorized(request, env, false)) return json({ ok: false }, 401); const body = await request.json() as Partial<TelegramSettings>; const botToken = body.botToken?.trim() ?? "", chatId = body.chatId?.trim() ?? ""; if (!/^\d{6,}:[A-Za-z0-9_-]{20,}$/.test(botToken) || !/^-?\d{5,}$/.test(chatId)) return json({ ok: false, message: "Bot Token 또는 Chat ID 형식을 확인해 주세요." }, 400); const check = await fetch(`https://api.telegram.org/bot${botToken}/getMe`); if (!check.ok || !((await check.json()) as { ok?: boolean }).ok) return json({ ok: false, message: "Telegram Bot Token을 확인할 수 없습니다." }, 400); await env.DATA.put(TELEGRAM_KEY, await encryptJson({ botToken, chatId }, env.AUTH_SECRET)); return json({ ok: true }); }
    if (url.pathname === "/api/settings/telegram" && request.method === "DELETE") { if (!await authorized(request, env, false)) return json({ ok: false }, 401); await env.DATA.delete(TELEGRAM_KEY); return json({ ok: true }); }
    if (request.method === "GET" && url.pathname === "/") { const loggedIn = await verifySession(readCookie(request, "sw_session"), env.AUTH_SECRET); return loggedIn ? html(appPage) : html(loginPage(url.searchParams.get("error") === "1")); }
    return json({ ok: false, message: "찾을 수 없습니다." }, 404);
  },
} satisfies ExportedHandler<Env>;

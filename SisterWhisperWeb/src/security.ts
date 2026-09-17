const encoder = new TextEncoder();
const SESSION_SECONDS = 7 * 24 * 60 * 60;

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

export async function secureEqual(left: string, right: string): Promise<boolean> {
  const [leftHash, rightHash] = await Promise.all([sha256(left), sha256(right)]);
  let difference = 0;
  for (let index = 0; index < leftHash.length; index += 1) {
    difference |= leftHash[index] ^ rightHash[index];
  }
  return difference === 0;
}

async function hmac(payload: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return toBase64Url(new Uint8Array(signature));
}

export async function createSession(secret: string, nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
  const payload = `v1.${nowSeconds + SESSION_SECONDS}`;
  return `${payload}.${await hmac(payload, secret)}`;
}

export async function verifySession(token: string | undefined, secret: string, nowSeconds = Math.floor(Date.now() / 1000)): Promise<boolean> {
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") return false;
  const expiresAt = Number(parts[1]);
  if (!Number.isSafeInteger(expiresAt) || expiresAt < nowSeconds) return false;
  const payload = `${parts[0]}.${parts[1]}`;
  return secureEqual(parts[2], await hmac(payload, secret));
}

export function readCookie(request: Request, name: string): string | undefined {
  const cookieHeader = request.headers.get("Cookie") ?? "";
  for (const entry of cookieHeader.split(";")) {
    const [key, ...value] = entry.trim().split("=");
    if (key === name) return decodeURIComponent(value.join("="));
  }
  return undefined;
}

export function sessionCookie(token: string): string {
  return `sw_session=${encodeURIComponent(token)}; Path=/; Max-Age=${SESSION_SECONDS}; HttpOnly; Secure; SameSite=Strict`;
}

export function expiredSessionCookie(): string {
  return "sw_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict";
}

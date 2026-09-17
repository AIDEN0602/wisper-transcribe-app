import { describe, expect, it } from "vitest";
import { createSession, secureEqual, verifySession } from "../src/security";
import { safeFilename } from "../src/index";

describe("authentication", () => {
  it("compares secret strings", async () => {
    await expect(secureEqual("same", "same")).resolves.toBe(true);
    await expect(secureEqual("same", "different")).resolves.toBe(false);
  });

  it("accepts a valid session and rejects tampering or expiry", async () => {
    const token = await createSession("long-test-secret", 1_000);
    await expect(verifySession(token, "long-test-secret", 1_001)).resolves.toBe(true);
    await expect(verifySession(`${token}x`, "long-test-secret", 1_001)).resolves.toBe(false);
    await expect(verifySession(token, "long-test-secret", 1_000 + 8 * 24 * 60 * 60)).resolves.toBe(false);
  });
});

describe("filename handling", () => {
  it("removes directories and control characters", () => {
    expect(safeFilename(encodeURIComponent("../../회의\u0000.m4a"))).toBe("회의.m4a");
  });

  it("falls back for invalid encoding", () => {
    expect(safeFilename("%ZZ")).toBe("recording.m4a");
  });
});

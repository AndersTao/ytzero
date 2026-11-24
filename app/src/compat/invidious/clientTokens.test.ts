import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { runIsolatedTestFile } from "../../../tests/isolatedTestFile";

const ISOLATION_FLAG = "YTZERO_CLIENT_TOKENS_TEST_ISOLATED";
if (process.env[ISOLATION_FLAG] !== "1") {
  test("client token suite runs in an isolated application runtime", async () => {
    await runIsolatedTestFile("src/compat/invidious/clientTokens.test.ts", ISOLATION_FLAG);
  });
} else {
  const root = mkdtempSync(resolve(tmpdir(), "ytzero-client-tokens-"));
  process.env.DB_PATH = resolve(root, "tokens.db");
  process.env.DOWNLOADS_DIR = resolve(root, "downloads");
  const { db } = await import("../../db");
  const { database } = await import("../../database");
  const { api } = await import("../../routes");
  const { MAX_TOKENS_PER_PROFILE, profileForToken } = await import("./tokens");

  const ask = (path: string, init: RequestInit = {}) => api.request(`http://localhost${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", Cookie: "ytzero_profile=1", ...(init.headers ?? {}) },
  });
  const mint = async (name: string) => (await ask("/invidious/tokens", { method: "POST", body: JSON.stringify({ name }) })).json() as Promise<{ id: number; token: string }>;
  const list = async () => ((await (await ask("/invidious/tokens")).json()) as { tokens: Array<{ id: number; name: string }> }).tokens;

  afterAll(async () => { db.close(); await database.close(); rmSync(root, { recursive: true, force: true }); });

  describe("a profile's client tokens", () => {
    test("are several, each under its own name, newest first", async () => {
      const ipad = await mint("  Yattee   on the iPad ");
      const tv = await mint("Rivulet on TV Stue");
      expect((await list()).map((token) => token.name)).toEqual(["Rivulet on TV Stue", "Yattee on the iPad"]);
      expect(await profileForToken(ipad.token)).toBe(1);
      expect(await profileForToken(tv.token)).toBe(1);
    });

    test("go one at a time: revoking one leaves the others signed in", async () => {
      const kept = await mint("Kept");
      const gone = await mint("Gone");
      expect((await ask(`/invidious/tokens/${gone.id}`, { method: "DELETE" })).status).toBe(200);
      expect(await profileForToken(gone.token)).toBeNull();
      expect(await profileForToken(kept.token)).toBe(1);
      expect((await ask(`/invidious/tokens/${gone.id}`, { method: "DELETE" })).status).toBe(404);
    });

    test("can be renamed, and never show the token again", async () => {
      const { id } = await mint("Old name");
      expect((await ask(`/invidious/tokens/${id}`, { method: "PATCH", body: JSON.stringify({ name: "New name" }) })).status).toBe(200);
      const listed = (await list()).find((token) => token.id === id)!;
      expect(listed.name).toBe("New name");
      expect(JSON.stringify(listed)).not.toContain("ytz_");
    });

    test("belong to their profile only", async () => {
      db.prepare("INSERT INTO users (id, name) VALUES (2, 'Other')").run();
      const { id } = await mint("Mine");
      expect((await ask(`/invidious/tokens/${id}`, { method: "DELETE", headers: { Cookie: "ytzero_profile=2" } })).status).toBe(404);
      expect((await list()).some((token) => token.id === id)).toBe(true);
    });

    test("stop at a limit, so a runaway script cannot fill the table", async () => {
      while ((await list()).length < MAX_TOKENS_PER_PROFILE) await mint("Filler");
      expect((await ask("/invidious/tokens", { method: "POST", body: JSON.stringify({ name: "One more" }) })).status).toBe(409);
    });
  });
}

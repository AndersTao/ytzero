import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const root = mkdtempSync(resolve(tmpdir(), "ytzero-websub-test-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("WebSub routes", () => {
  test("subscribe, verify, act on signed notifications only, and unsubscribe when turned off", async () => {
    const child = Bun.spawn(["bun", "app/tests/websubHarness.ts"], {
      cwd: resolve(import.meta.dir, "../.."),
      env: {
        ...Bun.env,
        DB_PATH: resolve(root, "db", "websub.db"),
        AVATAR_DIR: resolve(root, "avatars"),
        DOWNLOADS_DIR: resolve(root, "downloads"),
        APP_URL: "",
        YTZERO_BACKGROUND_TASKS: "0",
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ]);
    if (exitCode !== 0) throw new Error(`WebSub harness failed:\n${stderr}\n${stdout}`);
    expect(stdout).toContain("RESULT ok");
  }, 30_000);
});

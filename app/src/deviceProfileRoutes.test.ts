import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const root = mkdtempSync(resolve(tmpdir(), "ytzero-device-profiles-test-"));
let completed = false;

beforeAll(async () => {
  const process = Bun.spawn(["bun", "app/tests/deviceProfilesHarness.ts"], {
    cwd: resolve(import.meta.dir, "../.."),
    env: {
      ...Bun.env,
      DB_PATH: resolve(root, "db", "auth.db"),
      AVATAR_DIR: resolve(root, "avatars"),
      DOWNLOADS_DIR: resolve(root, "downloads"),
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
    process.exited,
  ]);
  if (exitCode !== 0) throw new Error(`TV device profiles harness failed:\n${stderr}\n${stdout}`);
  completed = true;
});

afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("TV device profiles", () => {
  test("holds one paired session per profile, swaps only to profiles paired on the device, and asks for the child lock PIN when leaving a child profile", () => {
    expect(completed).toBe(true);
  });
});

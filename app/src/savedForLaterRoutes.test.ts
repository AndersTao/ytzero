import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { savedForLaterPlaylistName } from "./routes/savedForLaterRoutes";

const root = mkdtempSync(resolve(tmpdir(), "ytzero-saved-for-later-test-"));
let result: Record<string, any> = {};

beforeAll(async () => {
  const process = Bun.spawn(["bun", "app/tests/savedForLaterHarness.ts"], {
    cwd: resolve(import.meta.dir, "../.."),
    env: { ...Bun.env, DB_PATH: resolve(root, "db", "source.db"), AVATAR_DIR: resolve(root, "avatars") },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(process.stdout).text(), new Response(process.stderr).text(), process.exited,
  ]);
  if (exitCode !== 0) throw new Error(`Saved-for-later harness failed:\n${stderr}\n${stdout}`);
  const line = stdout.split("\n").find((entry) => entry.startsWith("RESULT "));
  if (!line) throw new Error(`Saved-for-later harness returned no result:\n${stdout}`);
  result = JSON.parse(line.slice("RESULT ".length));
}, 30_000);

afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("save for later", () => {
  test("names the playlist in the profile's language", () => {
    expect(savedForLaterPlaylistName("da")).toBe("Gemt til senere");
    expect(savedForLaterPlaylistName(null)).toBe("Saved for later");
    expect(savedForLaterPlaylistName("xx")).toBe("Saved for later");
  });

  test("has nothing to show before the first save", () => {
    expect(result.before).toEqual({ playlist: null, videos: [] });
  });

  test("creates one playlist on the first save and reuses it", () => {
    expect(result.firstStatus).toBe(200);
    expect(result.playlistName).toBe("Gemt til senere");
    expect(result.samePlaylist).toBe(true);
    expect(result.primaryPlaylists).toBe(1);
  });

  test("lists newest first and leaves out watched videos", () => {
    expect(result.listedIds).toEqual(["savedVid002", "savedVid001"]);
  });

  test("saving again moves the video to the front without a duplicate", () => {
    expect(result.againAlready).toBe(true);
    expect(result.relistedIds).toEqual(["savedVid001", "savedVid002"]);
    expect(result.primaryRows).toBe(3);
  });

  test("a rejected video leaves the row, and saving it again brings it back", () => {
    expect(result.afterRejectIds).toEqual(["savedVid001"]);
    expect(result.afterResaveIds).toEqual(["savedVid002", "savedVid001"]);
  });

  test("rejects an invalid video id", () => {
    expect(result.invalidStatus).toBe(400);
  });

  test("keeps profiles apart and creates one playlist under concurrent saves", () => {
    expect(result.racedStatuses).toEqual([200, 200]);
    expect(result.secondaryPlaylists).toBe(1);
    expect(result.secondaryName).toBe("Saved for later");
    expect(result.secondaryIds).toEqual(["savedVid001", "savedVid002"]);
  });

  test("a profile can keep the row off Main and still save", () => {
    expect(result.offMainPlaylist).toBe(true);
    expect(result.offMainIds).toEqual([]);
    expect(result.savedWhileOffStatus).toBe(200);
    expect(result.offMainSecondaryIds).toEqual(["savedVid001", "savedVid002"]);
    expect(result.backOnMainIds).toEqual(["savedVid002", "savedVid001"]);
  });
});

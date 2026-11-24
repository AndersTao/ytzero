import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { runIsolatedTestFile } from "../tests/isolatedTestFile";

const ISOLATION_FLAG = "YTZERO_REFILTER_TEST_ISOLATED";
if (process.env[ISOLATION_FLAG] !== "1") {
  test("refilter suite runs in an isolated application runtime", async () => {
    await runIsolatedTestFile("src/filterRulesRefilter.test.ts", ISOLATION_FLAG);
  });
} else {
  const root = mkdtempSync(resolve(tmpdir(), "ytzero-refilter-"));
  process.env.DB_PATH = resolve(root, "refilter.db");
  process.env.DOWNLOADS_DIR = resolve(root, "downloads");
  const { db } = await import("./db");
  const { database } = await import("./database");
  const { api } = await import("./routes");
  const { refilteringWrites } = await import("./filterRules");
  const { RSS_VIDEO_UPSERT_SQL } = await import("./videoUpserts");

  db.prepare("INSERT INTO channels(channel_id,title) VALUES('UCstreams','Stream channel')").run();
  const rule = (pattern: string, action = "reject") => db.prepare(
    "INSERT INTO filter_rules(pattern,match_type,field,action,channel_id,user_id) VALUES(?, 'contains', 'title', ?, 'UCstreams', 1) RETURNING id",
  ).get(pattern, action) as { id: number };
  const arrive = (id: string, title: string) =>
    db.prepare("INSERT INTO videos(video_id,channel_id,title,published_at) VALUES(?, 'UCstreams', ?, datetime('now'))").run(id, title);
  const feed = refilteringWrites(database.prepare(RSS_VIDEO_UPSERT_SQL));
  const retitle = (id: string, title: string) => feed.run(id, "UCstreams", title, title, "", "", null, null, null);
  const status = (id: string) =>
    (db.prepare("SELECT COALESCE((SELECT status FROM user_videos WHERE user_id=1 AND video_id=?), 'inbox') AS s").get(id) as { s: string }).s;

  afterAll(async () => { db.close(); await database.close(); rmSync(root, { recursive: true, force: true }); });

  describe("a video whose title changes after it arrived", () => {
    test("is rejected when its new title fits a reject rule", async () => {
      // As reported: announced under one title, streamed under another.
      rule("2 Players Live");
      arrive("stream00001", "Fine, We'll Make our own Justice League Part 2");
      expect(status("stream00001")).toBe("inbox");
      await retitle("stream00001", "Fine, We'll Make our own Justice League Part 2 | 2 Players Live");
      expect(status("stream00001")).toBe("archived");
    });

    test("is left where it is once the profile has sorted it", async () => {
      arrive("stream00002", "Part 3");
      db.prepare("INSERT INTO user_videos(user_id,video_id,status) VALUES(1,'stream00002','queued')").run();
      await retitle("stream00002", "Part 3 | 2 Players Live");
      expect(status("stream00002")).toBe("queued");
    });

    test("is not looked at again while its words stay the same", async () => {
      // Brought back to the inbox by hand: the next sync saying the same must not undo that.
      arrive("stream00003", "Already 2 Players Live");
      await retitle("stream00003", "Already 2 Players Live");
      expect(status("stream00003")).toBe("inbox");
    });

    test("is never taken out by a whitelist it no longer fits", async () => {
      db.prepare("DELETE FROM filter_rules").run();
      rule("Justice League", "whitelist");
      arrive("stream00004", "Justice League Part 4");
      await retitle("stream00004", "Something else entirely");
      expect(status("stream00004")).toBe("inbox");
    });
  });

  test("an edited rule applies to the inbox, as a new one does", async () => {
    db.prepare("DELETE FROM filter_rules").run();
    const { id } = rule("nothing matches this");
    arrive("stream00005", "Speedrun Live!");
    const response = await api.request(`http://localhost/filter-rules/${id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", Cookie: "ytzero_profile=1" },
      body: JSON.stringify({ pattern: "Live!" }),
    });
    expect(response.status).toBe(200);
    expect(status("stream00005")).toBe("archived");
  });
}

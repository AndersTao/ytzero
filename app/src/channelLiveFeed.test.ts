import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { runIsolatedTestFile } from "../tests/isolatedTestFile";

const ISOLATION_FLAG = "YTZERO_CHANNEL_LIVE_FEED_TEST_ISOLATED";
if (process.env[ISOLATION_FLAG] !== "1") {
  test("channel live feed suite runs in an isolated application runtime", async () => {
    await runIsolatedTestFile("src/channelLiveFeed.test.ts", ISOLATION_FLAG);
  });
} else {
  const root = mkdtempSync(resolve(tmpdir(), "ytzero-channel-live-feed-"));
  process.env.DB_PATH = resolve(root, "db.sqlite");

  const { Hono } = await import("hono");
  const { db, setUserSetting } = await import("./db");
  const { feedVisibilityWhere } = await import("./feedQuery");
  const { registerChannelLiveFeedRoutes } = await import("./routes/channelLiveFeedRoutes");

  db.prepare("INSERT INTO channels(channel_id,title,url) VALUES('UCquiet','Quiet',''),('UCloud','Loud','')").run();
  db.prepare("INSERT INTO user_channels(user_id,channel_id,followed) VALUES(1,'UCquiet',1),(1,'UCloud',1)").run();
  db.prepare(`INSERT INTO videos(video_id,channel_id,title,live_status,published_at) VALUES
    ('quiet-upload','UCquiet','Upload','none','2026-11-10'),
    ('quiet-live','UCquiet','On now','live','2026-11-11'),
    ('quiet-recording','UCquiet','Recording','was_live','2026-11-12'),
    ('quiet-upcoming','UCquiet','Later','upcoming','2026-11-13'),
    ('loud-live','UCloud','On now','live','2026-11-11'),
    ('loud-recording','UCloud','Recording','was_live','2026-11-12')`).run();

  const app = new Hono();
  app.use("*", async (c, next) => { c.set("userId" as never, 1 as never); await next(); });
  registerChannelLiveFeedRoutes(app);
  const put = (channel: string, visibility: unknown) => app.request(`/channels/${channel}/live-feed`, {
    method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ visibility }),
  });

  function mainFeed(): string[] {
    const { where, params } = feedVisibilityWhere({}, 1);
    return db.prepare(`SELECT v.video_id FROM videos v LEFT JOIN user_videos uv ON uv.video_id=v.video_id AND uv.user_id=1 WHERE ${where.join(" AND ")} ORDER BY v.video_id`)
      .all(...params).map((row: any) => row.video_id);
  }

  afterAll(() => {
    db.close();
    rmSync(root, { recursive: true, force: true });
  });

  describe("per-channel livestream visibility", () => {
    test("by default every channel's streams follow the profile rule", async () => {
      await setUserSetting(1, "hide_live_from_feed", "0");
      expect(mainFeed()).toEqual(["loud-live", "loud-recording", "quiet-live", "quiet-recording", "quiet-upcoming", "quiet-upload"]);
    });

    test("only accepts default or hidden", async () => {
      expect((await put("UCquiet", "maybe")).status).toBe(400);
      expect((db.prepare("SELECT live_feed_visibility FROM user_channels WHERE user_id=1 AND channel_id='UCquiet'").get() as any).live_feed_visibility).toBeNull();
    });

    test("hidden leaves that channel's streams out, recordings included, and keeps its uploads", async () => {
      expect((await put("UCquiet", "hidden")).status).toBe(200);
      expect(mainFeed()).toEqual(["loud-live", "loud-recording", "quiet-upload"]);
    });

    test("together with the profile rule, the other channel's recordings still show", async () => {
      await setUserSetting(1, "hide_live_from_feed", "1");
      expect(mainFeed()).toEqual(["loud-recording", "quiet-upload"]);
    });

    test("default brings them back", async () => {
      await setUserSetting(1, "hide_live_from_feed", "0");
      expect((await put("UCquiet", "default")).status).toBe(200);
      expect(mainFeed()).toContain("quiet-recording");
    });
  });
}

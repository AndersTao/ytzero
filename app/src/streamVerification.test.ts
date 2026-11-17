import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { runIsolatedTestFile } from "../tests/isolatedTestFile";

const ISOLATION_FLAG = "YTZERO_STREAM_VERIFICATION_TEST_ISOLATED";
if (process.env[ISOLATION_FLAG] !== "1") {
  test("stream verification suite runs in an isolated application runtime", async () => {
    await runIsolatedTestFile("src/streamVerification.test.ts", ISOLATION_FLAG);
  });
} else {
  const root = mkdtempSync(resolve(tmpdir(), "ytzero-stream-verification-"));
  process.env.DB_PATH = resolve(root, "db.sqlite");

  const { db } = await import("./db");
  const { forgetStreamVerdicts, isRecordedStream, repairStreamBadges } = await import("./streamVerification");
  const { YouTubeRefusalError } = await import("./youtubeRateLimit");

  db.prepare("INSERT INTO channels(channel_id,title,url) VALUES('UCpremieres','Premieres','')").run();
  const recent = new Date(Date.now() - 5 * 86_400_000).toISOString();
  const insert = db.prepare("INSERT INTO videos(video_id,channel_id,title,live_status,published_at) VALUES(?,'UCpremieres','x',?,?)");
  for (const [id, status] of [["premiere001", "none"], ["realstream1", "none"], ["alreadylive", "live"], ["badgedprem1", "was_live"], ["badgedreal1", "was_live"]]) insert.run(id, status, recent);

  const streams = new Set(["realstream1", "badgedreal1", "alreadylive"]);
  const asked: string[] = [];
  const fakeInfo = async (videoId: string) => {
    asked.push(videoId);
    return { videoId, title: "x", channelId: "UCpremieres", channelTitle: "", description: "", thumbnail: "", viewCount: null,
      publishedAt: null, duration: "1:00:00", liveStatus: streams.has(videoId) ? "was_live" as const : "none" as const, playableInEmbed: null };
  };
  const status = (id: string) => (db.prepare("SELECT live_status FROM videos WHERE video_id=?").get(id) as any).live_status;

  afterAll(() => {
    db.close();
    rmSync(root, { recursive: true, force: true });
  });

  describe("videos the Live tab lists", () => {
    test("a premiere is not a recorded stream; a stream is", async () => {
      expect(await isRecordedStream("premiere001", fakeInfo)).toBe(false);
      expect(await isRecordedStream("realstream1", fakeInfo)).toBe(true);
    });

    test("the answer is remembered, so a sync does not ask again", async () => {
      asked.length = 0;
      expect(await isRecordedStream("premiere001", fakeInfo)).toBe(false);
      expect(asked).toEqual([]);
    });

    test("a video already marked something else is not looked up", async () => {
      asked.length = 0;
      expect(await isRecordedStream("alreadylive", fakeInfo)).toBe(false);
      expect(asked).toEqual([]);
    });

    test("an unanswered lookup does not mark it", async () => {
      forgetStreamVerdicts();
      expect(await isRecordedStream("realstream1", async () => { throw new Error("offline"); })).toBe(false);
    });
  });

  describe("repairing marks set before", () => {
    test("a refusal pauses the repair without finishing it", async () => {
      const result = await repairStreamBadges({ gapMs: 0, fetchInfo: async () => { throw new YouTubeRefusalError(Date.now() + 60_000); } });
      expect(result.done).toBe(false);
      expect(status("badgedprem1")).toBe("was_live");
    });

    test("clears the mark from premieres and keeps it on streams, once", async () => {
      const result = await repairStreamBadges({ gapMs: 0, fetchInfo: fakeInfo });
      expect(result).toEqual({ checked: 2, cleared: 1, done: true });
      expect(status("badgedprem1")).toBe("none");
      expect(status("badgedreal1")).toBe("was_live");
      asked.length = 0;
      expect((await repairStreamBadges({ gapMs: 0, fetchInfo: fakeInfo })).checked).toBe(0);
      expect(asked).toEqual([]);
    });
  });
}

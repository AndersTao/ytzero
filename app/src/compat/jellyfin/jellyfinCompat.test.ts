import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { Hono } from "hono";
import { runIsolatedTestFile } from "../../../tests/isolatedTestFile";

const ISOLATION_FLAG = "YTZERO_JELLYFIN_COMPAT_TEST_ISOLATED";
if (process.env[ISOLATION_FLAG] !== "1") {
  test("Jellyfin compat suite runs in an isolated application runtime", async () => {
    await runIsolatedTestFile("src/compat/jellyfin/jellyfinCompat.test.ts", ISOLATION_FLAG);
  });
} else {
  const root = mkdtempSync(resolve(tmpdir(), "ytzero-jellyfin-compat-"));
  process.env.DB_PATH = resolve(root, "db.sqlite");

  const { db } = await import("../../db");
  const { api } = await import("../../routes");
  const { mintToken } = await import("../invidious/tokens");
  const { registerJellyfinCompat } = await import("./index");
  const { presentedToken } = await import("./headers");
  const { jellyfinDate, videoItem } = await import("./items");

  describe("what a Jellyfin client sends and reads", () => {
    test("finds the token where Rivulet puts it, and where other clients do", () => {
      const signedIn = new Headers({ Authorization: 'MediaBrowser Client="Rivulet", Device="Apple TV", DeviceId="abc", Version="1.0", Token="s3ss10n"' });
      expect(presentedToken(signedIn, new URLSearchParams())).toBe("s3ss10n");
      expect(presentedToken(new Headers({ "X-Emby-Token": "t" }), new URLSearchParams())).toBe("t");
      expect(presentedToken(new Headers(), new URLSearchParams("ApiKey=k"))).toBe("k");
      // Signed out: the header names the client but carries no token.
      const anonymous = new Headers({ Authorization: 'MediaBrowser Client="Rivulet", Device="Apple TV", DeviceId="abc", Version="1.0"' });
      expect(presentedToken(anonymous, new URLSearchParams())).toBeNull();
    });

    test("writes dates with the fractions its clients insist on", () => {
      expect(jellyfinDate("2026-11-23T07:21:39Z")).toBe("2026-11-23T07:21:39.0000000Z");
      expect(jellyfinDate("2026-11-23 08:21:39")).toBe("2026-11-23T08:21:39.0000000Z");
      expect(jellyfinDate("")).toBeUndefined();
    });

    test("makes a video a playable film with its picture, length and progress", () => {
      const item = videoItem({
        video_id: "abc123", title: "A video", channel_title: "A channel", channel_id: "UCx",
        duration: "1:02:03", watch_position: 60, published_at: "2026-01-02T03:04:05Z",
      }, "server");
      expect(item.Type).toBe("Movie");
      expect(item.RunTimeTicks).toBe(3723 * 10_000_000);
      expect((item.ImageTags as Record<string, string>).Primary).toBeString();
      expect(item.BackdropImageTags).toHaveLength(1);
      expect(item.UserData).toMatchObject({ PlaybackPositionTicks: 600_000_000, Played: false });
      expect(item.Studios).toEqual([{ Name: "A channel", Id: "UCx" }]);
    });
  });

  db.prepare("INSERT INTO channels(channel_id,title,url) VALUES('UCjf','Jellyfin channel','')").run();
  db.prepare("INSERT INTO user_channels(user_id,channel_id,followed) VALUES(1,'UCjf',1)").run();
  db.prepare(`INSERT INTO videos(video_id,channel_id,title,duration,is_short,published_at,is_unavailable) VALUES
    ('newest00001','UCjf','Newest','10:00',0,'2099-01-03',0),
    ('older000002','UCjf','Older','5:00',0,'2099-01-02',0)`).run();
  const name = (db.prepare("SELECT name FROM users WHERE id = 1").get() as { name: string }).name;

  /** Shaped like the real server: the dialect first, then the guarded API. */
  function server(): Hono {
    process.env.YTZERO_JELLYFIN_COMPAT = "1";
    const app = new Hono();
    registerJellyfinCompat(app);
    app.route("/api", api);
    return app;
  }

  const client = 'MediaBrowser Client="Rivulet", Device="Apple TV", DeviceId="test", Version="1.0"';

  async function signedIn(app: Hono) {
    const token = await mintToken(1);
    const response = await app.request("/jellyfin/Users/AuthenticateByName", {
      method: "POST",
      headers: { Authorization: client, "Content-Type": "application/json" },
      body: JSON.stringify({ Username: name, Pw: token }),
    });
    expect(response.status).toBe(200);
    const body = await response.json() as { AccessToken: string; User: { Id: string } };
    expect(body.User.Id).toBeString();
    const authorization = `${client}, Token="${body.AccessToken}"`;
    return (path: string, init: RequestInit = {}) => app.request(`/jellyfin${path}`, {
      ...init,
      headers: { Authorization: authorization, "Content-Type": "application/json", ...(init.headers ?? {}) },
    });
  }

  afterAll(() => {
    db.close();
    rmSync(root, { recursive: true, force: true });
  });

  describe("a Jellyfin client signed in to this server", () => {
    test("does not exist unless the instance asked for it", async () => {
      delete process.env.YTZERO_JELLYFIN_COMPAT;
      const app = new Hono();
      registerJellyfinCompat(app);
      expect((await app.request("/jellyfin/System/Info/Public")).status).toBe(404);
    });

    test("is recognised as a Jellyfin server new enough for Rivulet", async () => {
      const response = await server().request("/jellyfin/System/Info/Public");
      const info = await response.json() as { ProductName: string; Version: string; Id: string };
      expect(info.ProductName).toBe("Jellyfin Server");
      const [major, minor] = info.Version.split(".").map(Number);
      expect(major * 100 + minor).toBeGreaterThanOrEqual(1010);
      expect(info.Id).toMatch(/^[0-9a-f]{32}$/);
    });

    test("refuses a wrong token, and the library to nobody", async () => {
      const app = server();
      const refused = await app.request("/jellyfin/Users/AuthenticateByName", {
        method: "POST",
        headers: { Authorization: client, "Content-Type": "application/json" },
        body: JSON.stringify({ Username: name, Pw: "ytz_wrong" }),
      });
      expect(refused.status).toBe(401);
      for (const path of ["/UserViews", "/Items", "/Items/Latest", "/UserItems/Resume", "/Items/newest00001"]) {
        expect(`${path} -> ${(await app.request(`/jellyfin${path}`)).status}`).toBe(`${path} -> 401`);
      }
    });

    test("shows Main as a film library, newest first", async () => {
      const ask = await signedIn(server());
      const views = await (await ask("/UserViews")).json() as { Items: Array<{ Id: string; CollectionType: string }> };
      expect(views.Items).toHaveLength(1);
      expect(views.Items[0].CollectionType).toBe("movies");
      const latest = await (await ask(`/Items/Latest?parentId=${views.Items[0].Id}&limit=24`)).json() as Array<{ Id: string; Type: string }>;
      expect(latest.map((item) => item.Id)).toEqual(["newest00001", "older000002"]);
      expect(latest.every((item) => item.Type === "Movie")).toBe(true);
      const grid = await (await ask(`/Items?parentId=${views.Items[0].Id}&recursive=true&includeItemTypes=Movie&startIndex=0&limit=60`)).json() as { Items: unknown[]; TotalRecordCount: number };
      expect(grid.Items).toHaveLength(2);
      expect(grid.TotalRecordCount).toBe(2);
      // Series, episodes and the like: none here, and not an error.
      const episodes = await (await ask("/Items?includeItemTypes=Episode&recursive=true")).json() as { Items: unknown[] };
      expect(episodes.Items).toHaveLength(0);
    });

    test("keeps where playback got to, and hears when it is finished", async () => {
      const ask = await signedIn(server());
      expect((await ask("/Sessions/Playing", { method: "POST", body: JSON.stringify({ ItemId: "older000002", PositionTicks: 0 }) })).status).toBe(204);
      await ask("/Sessions/Playing/Progress", { method: "POST", body: JSON.stringify({ ItemId: "older000002", PositionTicks: 90 * 10_000_000 }) });
      const item = await (await ask("/Items/older000002")).json() as { UserData: { PlaybackPositionTicks: number } };
      expect(item.UserData.PlaybackPositionTicks).toBe(90 * 10_000_000);
      const resume = await (await ask("/UserItems/Resume?limit=20&mediaTypes=Video")).json() as { Items: Array<{ Id: string }> };
      expect(resume.Items.map((entry) => entry.Id)).toContain("older000002");

      await ask("/UserPlayedItems/older000002", { method: "POST" });
      const played = await (await ask("/Items/older000002")).json() as { UserData: { Played: boolean } };
      expect(played.UserData.Played).toBe(true);
    });

    test("serves pictures to an image view that carries no token", async () => {
      const response = await server().request("/jellyfin/Items/nosuchvideo/Images/Primary?tag=x");
      expect(response.status).toBe(404);
    });
  });
}

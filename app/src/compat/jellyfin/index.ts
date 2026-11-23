import { createHash } from "node:crypto";
import { Hono, type Context } from "hono";
import { database } from "../../database";
import { isAllowedRemoteImageUrl } from "../../imageCachePolicy";
import { getCachedImage } from "../../imgcache";
import { log } from "../../logger";
import { mediaSecret } from "../invidious/media";
import { presentedToken, signIn, signOut, userForSession, type JellyfinUser } from "./auth";
import { LIBRARY_ID, libraryView, queryResult, runTimeSeconds, seconds, thumbnailUrl, videoItem, type ApiVideo } from "./items";
import { OwnApi } from "./ownApi";
import { playbackInfo, reportProgress, reportStart, type PlaybackReport } from "./playback";

/**
 * Speaking Jellyfin, so that a Jellyfin client — Rivulet on the Apple TV —
 * can add this server as one of its own and browse and play Main from there.
 *
 * Like the Invidious dialect beside it, everything lives in this folder and is
 * one call in `index.ts`, off unless `YTZERO_JELLYFIN_COMPAT=1`, at
 * `<instance>/jellyfin`. It answers only what such a client needs: who the
 * server is, signing in, one film library holding Main, Continue watching,
 * pictures, and playback with progress. Everything it says comes from this
 * server's own API, asked as the profile that signed in.
 */
export function jellyfinCompatEnabled(): boolean {
  return (process.env.YTZERO_JELLYFIN_COMPAT ?? "").trim() === "1";
}

export const JELLYFIN_BASE = "/jellyfin";
/** The server version clients check for; Rivulet asks for 10.10 or later. */
const JELLYFIN_VERSION = "10.11.0";
const ORIGIN = "http://localhost";

type Env = { Variables: { user: JellyfinUser; own: OwnApi } };

export function registerJellyfinCompat(app: Hono): void {
  if (!jellyfinCompatEnabled()) return;
  const jf = new Hono<Env>();

  jf.get("/System/Info/Public", async (c) => c.json({
    Id: await serverId(),
    ServerName: "YT Zero",
    ProductName: "Jellyfin Server",
    Version: JELLYFIN_VERSION,
    StartupWizardCompleted: true,
  }));

  jf.post("/Users/AuthenticateByName", async (c) => {
    const body = await c.req.json().catch(() => ({})) as { Username?: string; Pw?: string };
    const user = await signIn(body.Username ?? "", body.Pw ?? "");
    if (!user) {
      log.info("jellyfin.sign_in_refused", { name: (body.Username ?? "").slice(0, 60) });
      return c.json({ error: "Invalid user name or password" }, 401);
    }
    log.info("jellyfin.signed_in", { userId: user.userId });
    const id = await serverId();
    return c.json({ AccessToken: user.session, ServerId: id, User: await userDto(user), SessionInfo: { UserId: await userId(user) } });
  });

  // Quick Connect is not offered: signing in takes the profile's client token.
  jf.post("/QuickConnect/Initiate", (c) => c.json({ error: "Quick Connect is not enabled" }, 401));

  // The pictures are fetched by an image view with no credentials, so they are
  // served to anyone asking for a video this server knows.
  jf.get("/Items/:id/Images/:type/:index?", async (c) => {
    const row = await database.prepare("SELECT thumbnail FROM videos WHERE video_id = ?").get(c.req.param("id")) as { thumbnail: string | null } | null;
    if (!row) return c.json({ error: "not found" }, 404);
    const url = thumbnailUrl(c.req.param("id"), row.thumbnail);
    if (!isAllowedRemoteImageUrl(url)) return c.json({ error: "not found" }, 404);
    const image = await getCachedImage(url);
    if (!image) return c.redirect(url, 302);
    return new Response(Bun.file(image.path), { headers: { "Content-Type": image.contentType, "Cache-Control": "public, max-age=604800" } });
  });

  // The stream the playback info named, under this address: handed to the
  // API as it is, where its media ticket is checked.
  jf.get("/api/videos/:id/relay-hls/:file", (c) => {
    const url = new URL(c.req.url);
    return app.request(`${ORIGIN}${url.pathname.slice(JELLYFIN_BASE.length)}${url.search}`, { headers: forwardedRangeHeaders(c) });
  });

  // Everything below is for a signed-in profile.
  jf.use("*", async (c, next) => {
    const url = new URL(c.req.url);
    const user = await userForSession(presentedToken(c.req.raw.headers, url.searchParams));
    if (!user) return c.json({ error: "unauthorised" }, 401);
    c.set("user", user);
    c.set("own", new OwnApi(app, user.session, ORIGIN));
    await next();
  });

  jf.post("/Sessions/Logout", async (c) => {
    await signOut(c.get("user").session);
    return c.body(null, 204);
  });

  jf.get("/Users/Me", async (c) => c.json(await userDto(c.get("user"))));
  jf.get("/Users/:id", async (c) => c.json(await userDto(c.get("user"))));

  jf.get("/UserViews", async (c) => c.json(queryResult([libraryView(await serverId(), "Main")])));

  jf.get("/UserItems/Resume", async (c) => {
    const query = lowerQuery(c);
    if (query.parentid && query.parentid !== LIBRARY_ID) return c.json(queryResult([]));
    const { videos } = await c.get("own").get<{ videos: ApiVideo[] }>("/in-progress");
    const id = await serverId();
    const limit = positive(query.limit) ?? videos.length;
    return c.json(queryResult(videos.slice(0, limit).map((video) => videoItem(video, id)), videos.length));
  });

  jf.get("/Items/Latest", async (c) => {
    const query = lowerQuery(c);
    if (query.parentid && query.parentid !== LIBRARY_ID) return c.json([]);
    const limit = Math.min(100, positive(query.limit) ?? 24);
    const { videos } = await c.get("own").get<{ videos: ApiVideo[] }>(`/feed?page=0&limit=${limit}`);
    const id = await serverId();
    return c.json(videos.map((video) => videoItem(video, id)));
  });

  jf.get("/Items", async (c) => c.json(await items(c)));

  jf.get("/Items/:id", async (c) => {
    const video = await videoById(c.get("own"), c.req.param("id"));
    if (!video) return c.json({ error: "not found" }, 404);
    return c.json(videoItem(video, await serverId()));
  });

  jf.post("/Items/:id/PlaybackInfo", async (c) => {
    const body = await c.req.json().catch(() => ({})) as { StartTimeTicks?: number };
    const own = c.get("own");
    const video = await videoById(own, c.req.param("id"));
    if (!video) return c.json({ error: "not found" }, 404);
    const start = seconds(body.StartTimeTicks) || (video.watch_position ?? 0);
    return c.json(await playbackInfo(own, c.get("user").session, video.video_id, start, runTimeSeconds(video)));
  });

  jf.post("/Sessions/Playing", async (c) => {
    await reportStart(c.get("own"), await report(c));
    return c.body(null, 204);
  });
  jf.post("/Sessions/Playing/Progress", async (c) => {
    await reportProgress(c.get("own"), await report(c), false);
    return c.body(null, 204);
  });
  jf.post("/Sessions/Playing/Stopped", async (c) => {
    await reportProgress(c.get("own"), await report(c), true);
    return c.body(null, 204);
  });
  jf.delete("/Videos/ActiveEncodings", (c) => c.body(null, 204));

  jf.post("/UserPlayedItems/:id", async (c) => {
    await c.get("own").raw("POST", `/videos/${encodeURIComponent(c.req.param("id"))}/complete`, {});
    return c.json({ Played: true });
  });
  // "Remove from Continue watching" sends a position of nought.
  jf.post("/UserItems/:id/UserData", async (c) => {
    const body = await c.req.json().catch(() => ({})) as { PlaybackPositionTicks?: number };
    if (body.PlaybackPositionTicks === 0) await c.get("own").raw("DELETE", `/videos/${encodeURIComponent(c.req.param("id"))}/progress`);
    return c.json({});
  });

  // Anything else a client asks for — series, music, live TV, trailers — this
  // server has none of: an empty answer where a list is expected keeps its
  // screens working.
  jf.get("*", (c) => c.json({ error: "not found" }, 404));
  jf.all("*", (c) => c.body(null, 204));

  app.route(JELLYFIN_BASE, jf);
  log.info("jellyfin.compat_enabled", { base: JELLYFIN_BASE });
}

/** The film library's grid, search, and the many side queries a client makes. */
async function items(c: Context<Env>): Promise<Record<string, unknown>> {
  const query = lowerQuery(c);
  const id = await serverId();
  const own = c.get("own");
  const start = Math.max(0, Number(query.startindex) || 0);
  const types = (query.includeitemtypes ?? "").split(",").filter(Boolean);
  if (query.ids) {
    const found = await Promise.all(query.ids.split(",").map((one) => videoById(own, one)));
    return queryResult(found.filter((video): video is ApiVideo => video !== null).map((video) => videoItem(video, id)));
  }
  // Episodes, series, collections, playlists, people: there are none here.
  if (types.length && !types.some((type) => type === "Movie" || type === "Video")) return queryResult([]);
  if (query.parentid && query.parentid !== LIBRARY_ID) return queryResult([]);
  if (/IsFavorite|IsResumable/i.test(query.filters ?? "") || query.namestartswith || query.namelessthan || query.genreids || query.years) {
    return queryResult([]);
  }
  const limit = Math.min(100, query.limit === undefined ? 60 : Number(query.limit) || 0);
  const search = query.searchterm?.trim();
  if (limit === 0) return queryResult([], 0, start);
  const page = Math.floor(start / limit);
  const path = `/feed?page=${page}&limit=${limit}${search ? `&q=${encodeURIComponent(search)}` : ""}`;
  const { videos } = await own.get<{ videos: ApiVideo[] }>(path);
  const listed = videos.map((video) => videoItem(video, id));
  // The feed does not count itself: one more than shown keeps a full page asking for the next.
  const total = start + listed.length + (listed.length === limit ? 1 : 0);
  return queryResult(listed, total, start);
}

async function videoById(own: OwnApi, videoId: string): Promise<ApiVideo | null> {
  const response = await own.raw("GET", `/videos/${encodeURIComponent(videoId)}`);
  if (!response.ok) return null;
  const body = await response.json() as { video?: ApiVideo };
  return body.video ?? null;
}

async function report(c: Context<Env>): Promise<PlaybackReport> {
  return await c.req.json().catch(() => ({})) as PlaybackReport;
}

function lowerQuery(c: Context): Record<string, string | undefined> {
  const out: Record<string, string> = {};
  for (const [key, value] of new URL(c.req.url).searchParams) out[key.toLowerCase()] = value;
  return out;
}

function positive(value: string | undefined): number | undefined {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : undefined;
}

function forwardedRangeHeaders(c: Context): Headers {
  const headers = new Headers();
  const range = c.req.header("range");
  if (range) headers.set("Range", range);
  return headers;
}

let cachedServerId: string | null = null;

/** Stable for this instance, and saying nothing about the secret it comes from. */
async function serverId(): Promise<string> {
  cachedServerId ??= createHash("sha256").update(`ytzero-jellyfin:${await mediaSecret()}`).digest("hex").slice(0, 32);
  return cachedServerId;
}

async function userId(user: JellyfinUser): Promise<string> {
  return createHash("sha256").update(`${await serverId()}:${user.userId}`).digest("hex").slice(0, 32);
}

async function userDto(user: JellyfinUser): Promise<Record<string, unknown>> {
  return {
    Id: await userId(user),
    Name: user.name,
    ServerId: await serverId(),
    HasPassword: true,
    HasConfiguredPassword: true,
    Policy: { IsAdministrator: false, EnableContentDeletion: false, EnableContentDownloading: false, EnableLiveTvManagement: false },
    Configuration: { LatestItemsExcludes: [] },
  };
}

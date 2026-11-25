const { api } = await import("../src/routes");
const { db, setUserSetting } = await import("../src/db");

db.prepare("INSERT INTO channels(channel_id,title,url) VALUES('UCsavedlater','Saved channel','https://youtube.com/channel/UCsavedlater')").run();
for (const [id, title] of [["savedVid001", "First"], ["savedVid002", "Second"], ["savedVid003", "Watched"]]) {
  db.prepare("INSERT INTO videos(video_id,channel_id,title,description,thumbnail) VALUES(?,'UCsavedlater',?,'','thumb.jpg')").run(id, title);
}
const secondary = db.prepare("INSERT INTO users(name,avatar_color,sort_order,portable_uuid) VALUES('Secondary','#123456',1,?) RETURNING id")
  .get(crypto.randomUUID()) as { id: number };
await setUserSetting(1, "language", "da");

const request = (profileId: number, path: string, method = "GET", body?: unknown) => api.request(`http://localhost${path}`, {
  method,
  headers: { Cookie: `ytzero_profile=${profileId}`, "Content-Type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});
const json = async (response: Response) => ({ status: response.status, body: await response.json() as any });

const before = await json(await request(1, "/saved-for-later"));
const first = await json(await request(1, "/saved-for-later", "POST", { video_id: "savedVid001" }));
await Bun.sleep(1100);
const second = await json(await request(1, "/saved-for-later", "POST", { video_id: "savedVid002" }));
const watched = await json(await request(1, "/saved-for-later", "POST", { video_id: "savedVid003" }));
db.prepare("INSERT INTO user_videos(user_id,video_id,watched) VALUES(1,'savedVid003',1) ON CONFLICT(user_id,video_id) DO UPDATE SET watched=1").run();
const listed = await json(await request(1, "/saved-for-later"));
await Bun.sleep(1100);
const again = await json(await request(1, "/saved-for-later", "POST", { video_id: "savedVid001" }));
const relisted = await json(await request(1, "/saved-for-later"));
const invalid = await json(await request(1, "/saved-for-later", "POST", { video_id: "../etc" }));
const [racedA, racedB] = await Promise.all([
  request(secondary.id, "/saved-for-later", "POST", { video_id: "savedVid001" }).then(json),
  request(secondary.id, "/saved-for-later", "POST", { video_id: "savedVid002" }).then(json),
]);
const secondaryList = await json(await request(secondary.id, "/saved-for-later"));
const count = (sql: string, ...args: unknown[]) => (db.prepare(sql).get(...args) as { n: number }).n;

console.log("RESULT " + JSON.stringify({
  before: before.body,
  firstStatus: first.status,
  playlistName: first.body.playlist?.name,
  samePlaylist: first.body.playlist?.id === second.body.playlist?.id && second.body.playlist?.id === watched.body.playlist?.id,
  listedIds: listed.body.videos.map((video: any) => video.video_id),
  againAlready: again.body.already,
  relistedIds: relisted.body.videos.map((video: any) => video.video_id),
  primaryRows: count("SELECT COUNT(*) AS n FROM user_playlist_videos WHERE playlist_id = ?", first.body.playlist?.id),
  primaryPlaylists: count("SELECT COUNT(*) AS n FROM user_playlists WHERE user_id = 1"),
  invalidStatus: invalid.status,
  racedStatuses: [racedA.status, racedB.status],
  secondaryPlaylists: count("SELECT COUNT(*) AS n FROM user_playlists WHERE user_id = ?", secondary.id),
  secondaryName: secondaryList.body.playlist?.name,
  secondaryIds: secondaryList.body.videos.map((video: any) => video.video_id).sort(),
}));

db.close();

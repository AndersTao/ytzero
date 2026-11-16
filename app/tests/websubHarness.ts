// End-to-end WebSub flow against a throwaway database: subscribe through a
// fake hub, the hub's verification, a signed notification, and the refresh it
// triggers. Run by app/src/websubRoutes.test.ts with DB_PATH pointing at a
// temporary directory.
import { createHmac } from "node:crypto";
import { Hono } from "hono";

const { database } = await import("../src/database");
const websub = await import("../src/websub");
const { registerWebSubAdminRoutes, registerWebSubCallback } = await import("../src/websubRoutes");

const CHANNEL = "UC" + "q".repeat(22);
const BASE = "https://tube.example.com";
const failures: string[] = [];
const check = (condition: unknown, message: string) => { if (!condition) failures.push(message); };

const hubCalls: URLSearchParams[] = [];
websub.setWebSubHubFetch(async (_url, init) => {
  hubCalls.push(new URLSearchParams(String(init.body)));
  return new Response(null, { status: 202 });
});
const refreshed: string[] = [];
websub.setWebSubRefresher(async (channelId) => {
  refreshed.push(channelId);
  await database.prepare("INSERT INTO videos (video_id, channel_id, title, published_at) VALUES (?, ?, 'New', '2026-11-16T12:00:00Z')")
    .run("abcdefghijk", channelId);
});

const user = await database.prepare("SELECT id FROM users ORDER BY id LIMIT 1").get() as { id: number };
await database.prepare("INSERT INTO channels (channel_id, title, url) VALUES (?, 'Test', '')").run(CHANNEL);
await database.prepare("INSERT INTO user_channels (user_id, channel_id, followed) VALUES (?, ?, 1)").run(user.id, CHANNEL);

const app = new Hono();
registerWebSubCallback(app);
const api = new Hono();
let admin = true;
registerWebSubAdminRoutes(api, { isAdmin: () => admin });
app.route("/api", api);

// Off by default: nothing is subscribed.
await websub.maintainWebSub();
check(hubCalls.length === 0, "nothing should be sent to the hub while off");

// Settings: only administrators, and only a valid address.
admin = false;
check((await app.request("/api/websub")).status === 403, "status must be admin only");
admin = true;
const bad = await app.request("/api/websub", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: true, callbackBase: "ftp://x" }) });
check(bad.status === 400, "an invalid address must be refused");
const saved = await app.request("/api/websub", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: true, callbackBase: `${BASE}/` }) });
const savedBody = await saved.json() as any;
check(saved.status === 200 && savedBody.enabled === true && savedBody.effectiveBase === BASE, "saving should enable push with the given base");

await websub.maintainWebSub();
const subscribe = hubCalls.find((call) => call.get("hub.mode") === "subscribe");
check(subscribe?.get("hub.topic") === `https://www.youtube.com/xml/feeds/videos.xml?channel_id=${CHANNEL}`, "subscribe should name the channel topic");
check(subscribe?.get("hub.callback") === `${BASE}/api/websub/callback/${CHANNEL}`, "subscribe should give the per-channel callback");
const secret = subscribe?.get("hub.secret") ?? "";
check(secret.length === 64, "subscribe should send a secret");

const callback = `/api/websub/callback/${CHANNEL}`;
const topic = encodeURIComponent(`https://www.youtube.com/xml/feeds/videos.xml?channel_id=${CHANNEL}`);
// Verification: wrong topic refused, right one echoed and the lease stored.
check((await app.request(`${callback}?hub.mode=subscribe&hub.topic=x&hub.challenge=abc`)).status === 404, "a wrong topic must be refused");
const verify = await app.request(`${callback}?hub.mode=subscribe&hub.topic=${topic}&hub.challenge=abc123&hub.lease_seconds=864000`);
check(verify.status === 200 && await verify.text() === "abc123", "the challenge must be echoed");
const active = await websub.webSubRow(CHANNEL);
check(active?.state === "active" && active.lease_expires_at, "the subscription should be active with a lease");
check((await app.request(`/api/websub/callback/UC${"z".repeat(22)}?hub.mode=subscribe&hub.topic=x&hub.challenge=abc`)).status === 404, "an unknown channel must be refused");

// Notifications: unsigned ignored, signed acted on.
const atom = `<feed><entry><yt:videoId>abcdefghijk</yt:videoId><yt:channelId>${CHANNEL}</yt:channelId></entry></feed>`;
const unsigned = await app.request(callback, { method: "POST", body: atom });
check(unsigned.status === 204, "an unsigned notification still gets a 2xx");
await websub.flushWebSubRefreshes();
check(refreshed.length === 0, "an unsigned notification must not refresh anything");
const signature = "sha1=" + createHmac("sha1", secret).update(atom).digest("hex");
const signed = await app.request(callback, { method: "POST", body: atom, headers: { "X-Hub-Signature": signature } });
check(signed.status === 204, "a signed notification gets a 2xx");
await websub.flushWebSubRefreshes();
check(refreshed.length === 1 && refreshed[0] === CHANNEL, "a signed notification should refresh the channel once");

// Turning it off unsubscribes, and the hub's confirmation is accepted.
hubCalls.length = 0;
await app.request("/api/websub", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: false, callbackBase: "" }) });
await websub.maintainWebSub();
check(hubCalls.some((call) => call.get("hub.mode") === "unsubscribe"), "turning off should unsubscribe");
check((await websub.webSubRows()).length === 0, "rows should be gone after unsubscribing");
const confirm = await app.request(`${callback}?hub.mode=unsubscribe&hub.topic=${topic}&hub.challenge=bye`);
check(confirm.status === 200 && await confirm.text() === "bye", "an unsubscribe confirmation should be echoed");

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("RESULT ok");
process.exit(0);

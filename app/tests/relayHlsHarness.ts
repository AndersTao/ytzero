// relay-hls against a fake yt-dlp that writes indexed fMP4 fixtures into the
// media cache. Run by app/src/relayHls.test.ts with DB_PATH, YTDLP_PATH and
// YTZERO_INVIDIOUS_CACHE_DIR pointing into a temporary directory.
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const { forgetRelayHlsPresentations, relayHlsPlaylist, relayHlsReadiness } = await import("../src/relayHls");
const { mediaTicketPath, ticketAllowsPath } = await import("../src/mediaTickets");

const root = process.env.RELAY_HLS_FIXTURES!;
const cache = process.env.YTZERO_INVIDIOUS_CACHE_DIR!;
const failures: string[] = [];
const check = (condition: unknown, message: string) => { if (!condition) failures.push(message); };

// Tickets: the playlist and both tracks, nothing else.
const ticket = { videoId: "abcdefghijk", kind: "relay-hls" as const };
check(mediaTicketPath(ticket) === "/api/videos/abcdefghijk/relay-hls/index.m3u8", "the ticket should point at the master playlist");
for (const file of ["index.m3u8", "video.m3u8", "audio.m3u8", "video.mp4", "audio.mp4"]) {
  check(ticketAllowsPath(ticket, `/api/videos/abcdefghijk/relay-hls/${file}`, "GET"), `the ticket should allow ${file}`);
}
check(!ticketAllowsPath(ticket, "/api/videos/abcdefghijk/relay", "GET"), "the ticket must not open the plain relay");
check(!ticketAllowsPath(ticket, "/api/videos/otherchanne/relay-hls/video.mp4", "GET"), "the ticket must not open another video");

// The fake writes the front of each file at once and the rest only once
// released, so a start further in has to wait for it.
check(await relayHlsReadiness(1, "abcdefghijk", 0, 5_000) === "ready", "the start of the video should be ready from the front of the files");
check(await relayHlsReadiness(1, "abcdefghijk", 20, 600) === "pending", "a start past what has arrived should be pending");
const master = await relayHlsPlaylist(1, "abcdefghijk", "index.m3u8");
check(master?.includes('CODECS="avc1.640028,mp4a.40.2"') && master.includes("RESOLUTION=1920x1080") && master.includes('CHANNELS="2"'),
  `the master playlist should describe the tracks yt-dlp picked, got ${master}`);
check(master?.includes("/api/videos/abcdefghijk/relay-hls/video.m3u8?v="), "the master playlist should point at this route");
const video = await relayHlsPlaylist(1, "abcdefghijk", "video.m3u8");
check(video?.includes("relay-hls/video.mp4?v=") && /#EXT-X-BYTERANGE:\d+@\d+/.test(video), "the video playlist should address the file by byte range");
const audio = await relayHlsPlaylist(1, "abcdefghijk", "audio.m3u8");
check(audio?.includes("relay-hls/audio.mp4?v="), "the audio playlist should address the audio file");

writeFileSync(join(root, "release"), "");
check(await relayHlsReadiness(1, "abcdefghijk", 20, 5_000) === "ready", "the later start should be ready once its bytes are here");

// Kept: a later play is built from the files and what yt-dlp said about them.
const notes = () => readdirSync(cache).filter((name) => name.endsWith(".mp4.txt"));
for (let waited = 0; waited < 5_000 && notes().length < 2; waited += 50) await Bun.sleep(50);
check(notes().length === 2, `both tracks should keep their description, got ${notes().join(",")}`);
forgetRelayHlsPresentations();
const again = await relayHlsPlaylist(1, "abcdefghijk", "index.m3u8");
check(again === master, "a presentation rebuilt from the kept files should be the same one");

// A file without an index cannot be played this way; the client falls back.
check(await relayHlsReadiness(1, "badvideo123", 0, 5_000) === "failed", "a track without sidx should fail, not hang");

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("RESULT ok");
process.exit(0);

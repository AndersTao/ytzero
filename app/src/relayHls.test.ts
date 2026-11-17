import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

function concat(...parts: Uint8Array[]): Uint8Array {
  const bytes = new Uint8Array(parts.reduce((sum, part) => sum + part.byteLength, 0));
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.byteLength;
  }
  return bytes;
}

function uint32(value: number): Uint8Array {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, value);
  return bytes;
}

function box(type: string, payload: Uint8Array): Uint8Array {
  return concat(uint32(8 + payload.byteLength), new TextEncoder().encode(type), payload);
}

/** An fMP4 track as YouTube serves it: ftyp, moov, sidx, then the fragments. */
function track(durations: number[], lengths: number[]): Uint8Array {
  const entries = durations.map((duration, index) => concat(uint32(lengths[index]), uint32(duration), uint32(0x90000000)));
  const sidx = box("sidx", concat(
    Uint8Array.of(0, 0, 0, 0), uint32(1), uint32(1_000), uint32(0), uint32(0),
    Uint8Array.of(0, 0), Uint8Array.of(0, entries.length), ...entries,
  ));
  const media = Uint8Array.from({ length: lengths.reduce((sum, length) => sum + length, 0) }, (_, index) => (index * 17 + 29) % 251);
  return concat(box("ftyp", concat(new TextEncoder().encode("dash"), uint32(0), new TextEncoder().encode("iso6"))), box("moov", new Uint8Array(16)), sidx, media);
}

test("relay-hls builds a full-quality presentation from cached tracks and waits for a later start", async () => {
  const root = mkdtempSync(join(tmpdir(), "ytzero-relay-hls-"));
  const cache = join(root, "cache");
  mkdirSync(cache);
  const video = track([6_000, 6_000, 6_000, 6_000], [20_000, 20_000, 20_000, 20_000]);
  const audio = track([8_000, 8_000, 8_000], [5_000, 5_000, 5_000]);
  writeFileSync(join(root, "video.mp4"), video);
  writeFileSync(join(root, "audio.mp4"), audio);
  // Prints the line mediaCache asks for, writes the front of the file, and the
  // rest once the harness creates "release". Videos named bad* have no index.
  const ytdlp = join(root, "yt-dlp");
  writeFileSync(ytdlp, `#!/bin/sh
out=""; fmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -f) fmt="$2"; shift ;;
    --version) echo test; exit 0 ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$fmt" in
  bestvideo*) src="${root}/video.mp4"; echo "${video.byteLength} 1080 avc1.640028 none 1920 30 4000 NA" ;;
  *) src="${root}/audio.mp4"; echo "${audio.byteLength} NA none mp4a.40.2 NA NA 128 2" ;;
esac
case "$url" in *v=bad*) head -c 2000 /dev/zero > "$out"; exit 0 ;; esac
head -c 45000 "$src" > "$out"
while [ ! -f "${root}/release" ]; do sleep 0.05; done
cat "$src" > "$out"
`, { mode: 0o700 });
  try {
    const child = Bun.spawn([process.execPath, "app/tests/relayHlsHarness.ts"], {
      cwd: resolve(import.meta.dir, "../.."),
      env: {
        ...Bun.env, DB_PATH: join(root, "db/source.db"), AVATAR_DIR: join(root, "avatars"), DOWNLOADS_DIR: join(root, "downloads"),
        DOWNLOAD_COOKIES_DIR: join(root, "cookies"), YTDLP_PATH: ytdlp, YTZERO_INVIDIOUS_CACHE_DIR: cache, YTZERO_POT_PROVIDER: "off",
        RELAY_HLS_FIXTURES: root,
      },
      stdout: "pipe", stderr: "pipe",
    });
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    if (code !== 0) throw new Error(stderr || stdout || `Harness exited with ${code}`);
    expect(stdout, stderr).toContain("RESULT ok");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}, 30_000);

import { describe, expect, test } from "bun:test";
import { hasYouTubeRedirectMarker, markYouTubeUrl, noteYouTubeRedirect, withoutYouTubeRedirectMarker, youTubeReturnUrl, youtubeVideoId } from "./youtubeUrl";

describe("YouTube no-redirect URL marker", () => {
  test("adds the marker after query parameters", () => {
    expect(markYouTubeUrl("https://www.youtube.com/watch?v=abc&t=30s")).toBe("https://www.youtube.com/watch?v=abc&t=30s#ytNoRedirect");
    expect(markYouTubeUrl("https://youtu.be/abc")).toBe("https://youtu.be/abc#ytNoRedirect");
  });

  test("keeps an existing fragment and leaves other hosts unchanged", () => {
    expect(markYouTubeUrl("https://music.youtube.com/watch?v=abc#section")).toBe("https://music.youtube.com/watch?v=abc#section&ytNoRedirect");
    expect(markYouTubeUrl("https://example.com/watch?v=abc")).toBe("https://example.com/watch?v=abc");
  });

  test("does not duplicate the marker", () => {
    expect(markYouTubeUrl("https://youtube.com/watch?v=abc#ytNoRedirect")).toBe("https://youtube.com/watch?v=abc#ytNoRedirect");
  });
});

describe("YouTube video URL detection", () => {
  test("recognizes standard, shortened and player URLs", () => {
    expect(youtubeVideoId("https://www.youtube.com/watch?v=b6bxeEZ_j9A")).toBe("b6bxeEZ_j9A");
    expect(youtubeVideoId("https://youtu.be/b6bxeEZ_j9A#ytNoRedirect")).toBe("b6bxeEZ_j9A");
    expect(youtubeVideoId("https://youtube.com/shorts/b6bxeEZ_j9A?feature=share")).toBe("b6bxeEZ_j9A");
    expect(youtubeVideoId("https://www.youtube.com/live/b6bxeEZ_j9A")).toBe("b6bxeEZ_j9A");
    expect(youtubeVideoId("https://www.youtube-nocookie.com/embed/b6bxeEZ_j9A")).toBe("b6bxeEZ_j9A");
  });

  test("rejects channels, playlists, other hosts and malformed ids", () => {
    expect(youtubeVideoId("https://youtube.com/channel/UC123")).toBe(null);
    expect(youtubeVideoId("https://youtube.com/playlist?list=PL123")).toBe(null);
    expect(youtubeVideoId("https://example.com/watch?v=b6bxeEZ_j9A")).toBe(null);
    expect(youtubeVideoId("https://youtu.be/too-short")).toBe(null);
  });
});

describe("videos the extension sent here from YouTube", () => {
  const memoryStore = () => {
    const values = new Map<string, string>();
    return { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => { values.set(key, value); } };
  };

  test("reads and strips the marker", () => {
    expect(hasYouTubeRedirectMarker("#ytRedirected")).toBe(true);
    expect(hasYouTubeRedirectMarker("#chapter&ytRedirected")).toBe(true);
    expect(hasYouTubeRedirectMarker("#ytRedirectedX")).toBe(false);
    expect(hasYouTubeRedirectMarker("")).toBe(false);
    expect(withoutYouTubeRedirectMarker("#ytRedirected")).toBe("");
    expect(withoutYouTubeRedirectMarker("#chapter&ytRedirected")).toBe("#chapter");
  });

  test("remembers the redirected video for the tab, and only that video", () => {
    const store = memoryStore();
    expect(noteYouTubeRedirect("", "dQw4w9WgXcQ", store)).toBe(false);
    expect(noteYouTubeRedirect("#ytRedirected", "dQw4w9WgXcQ", store)).toBe(true);
    expect(noteYouTubeRedirect("", "dQw4w9WgXcQ", store)).toBe(true);
    expect(noteYouTubeRedirect("", "jNQXAC9IVRw", store)).toBe(false);
    expect(noteYouTubeRedirect("#ytRedirected", undefined, store)).toBe(false);
  });

  test("still answers when storage is unavailable or holds junk", () => {
    expect(noteYouTubeRedirect("#ytRedirected", "dQw4w9WgXcQ", null)).toBe(true);
    expect(noteYouTubeRedirect("", "dQw4w9WgXcQ", null)).toBe(false);
    const junk = { getItem: () => "{not json", setItem: () => { throw new Error("full"); } };
    expect(noteYouTubeRedirect("#ytRedirected", "dQw4w9WgXcQ", junk)).toBe(true);
  });

  test("goes back at the position reached, past the extension's redirect", () => {
    expect(youTubeReturnUrl("dQw4w9WgXcQ", 83.9)).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=83s#ytNoRedirect");
    expect(youTubeReturnUrl("dQw4w9WgXcQ", 0.5)).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ#ytNoRedirect");
    expect(youTubeReturnUrl("dQw4w9WgXcQ", Number.NaN)).toBe("https://www.youtube.com/watch?v=dQw4w9WgXcQ#ytNoRedirect");
  });
});

import { describe, expect, test } from "bun:test";
import { captionPlayerVars, createCaptionsOffGuard, resolveWatchCaptions } from "./watchCaptions";

describe("watch caption defaults", () => {
  test("follows the profile preference when the channel inherits it", () => {
    expect(resolveWatchCaptions({ playerCc: "1", playerCcLang: "pl" })).toEqual({
      channelOff: false, defaultOn: true, language: "pl",
    });
    expect(resolveWatchCaptions({ playerCc: "0", playerCcLang: "pl" })).toEqual({
      channelOff: false, defaultOn: false, language: "pl",
    });
  });

  test("falls back to the player language and then to English", () => {
    expect(resolveWatchCaptions({ playerCc: "1", playerHl: "de" }).language).toBe("de");
    expect(resolveWatchCaptions({ playerCc: "1" }).language).toBe("en");
  });

  test("lets a channel force one caption language or turn captions off", () => {
    expect(resolveWatchCaptions({ channelMode: "language", channelLanguage: "uk", playerCc: "0" })).toEqual({
      channelOff: false, defaultOn: true, language: "uk",
    });
    expect(resolveWatchCaptions({ channelMode: "off", playerCc: "1" })).toEqual({
      channelOff: true, defaultOn: false, language: "en",
    });
  });
});

describe("caption player vars", () => {
  test("requests the preferred caption track when captions default on", () => {
    expect(captionPlayerVars(true, "pl")).toEqual({ cc_load_policy: 1, cc_lang_pref: "pl" });
  });

  test("always sends cc_load_policy=0 so the browser preference cannot re-enable captions", () => {
    expect(captionPlayerVars(false, "pl")).toEqual({ cc_load_policy: 0 });
  });
});

describe("keeping embed captions off", () => {
  const fakePlayer = () => {
    const unloaded: string[] = [];
    return { unloaded, unloadModule: (module: string) => { unloaded.push(module); } };
  };

  test("unloads captions when ready, on first play and once more after", async () => {
    const player = fakePlayer();
    const guard = createCaptionsOffGuard(true, 5);
    guard.ready(player);
    guard.playing(player);
    expect(player.unloaded).toEqual(["captions", "cc", "captions", "cc"]);
    await new Promise((resolve) => setTimeout(resolve, 15));
    expect(player.unloaded.length).toBe(6);
  });

  test("leaves the viewer's own caption choice alone after the first play", async () => {
    const player = fakePlayer();
    const guard = createCaptionsOffGuard(true, 5);
    guard.playing(player);
    await new Promise((resolve) => setTimeout(resolve, 15));
    const afterStart = player.unloaded.length;
    guard.playing(player);
    guard.ready(player);
    expect(player.unloaded.length).toBe(afterStart);
  });

  test("does nothing when captions should be on", () => {
    const player = fakePlayer();
    const guard = createCaptionsOffGuard(false, 5);
    guard.ready(player);
    guard.playing(player);
    guard.dispose();
    expect(player.unloaded).toEqual([]);
  });

  test("dispose cancels the late unload", async () => {
    const player = fakePlayer();
    const guard = createCaptionsOffGuard(true, 5);
    guard.playing(player);
    guard.dispose();
    await new Promise((resolve) => setTimeout(resolve, 15));
    expect(player.unloaded.length).toBe(2);
  });
});

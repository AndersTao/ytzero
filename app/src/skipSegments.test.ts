import { describe, expect, test } from "bun:test";
import { selectSkipSegments, skipHashPrefix } from "./skipSegments";

describe("the parts a native player skips", () => {
  const answer = [
    { category: "intro", actionType: "skip", segment: [0, 12] as [number, number], UUID: "a" },
    { category: "sponsor", actionType: "skip", segment: [300, 360] as [number, number], UUID: "b" },
    { category: "sponsor", actionType: "mute", segment: [400, 410] as [number, number], UUID: "c" },
    { category: "filler", actionType: "skip", segment: [500, 520] as [number, number], UUID: "d" },
    { category: "sponsor", actionType: "skip", segment: [90, 60] as [number, number], UUID: "e" },
    { category: "selfpromo", actionType: "skip", segment: [120, 150] as [number, number] },
  ];

  test("are the skips of the kinds the profile chose, in order", () => {
    expect(selectSkipSegments("vid", answer, ["sponsor", "intro"]).map((s) => s.uuid)).toEqual(["a", "b"]);
  });

  test("leave out what is not a skip, backwards, or of a kind not chosen", () => {
    expect(selectSkipSegments("vid", answer, ["sponsor"]).map((s) => s.uuid)).toEqual(["b"]);
    expect(selectSkipSegments("vid", answer, [])).toEqual([]);
  });

  test("keep an id when SponsorBlock gave none, so a skip is counted once", () => {
    expect(selectSkipSegments("vid", answer, ["selfpromo"])).toEqual([{ category: "selfpromo", start: 120, end: 150, uuid: "vid:selfpromo:120:150:5" }]);
  });

  test("are asked for by a short hash prefix, never the video id", () => {
    expect(skipHashPrefix("dQw4w9WgXcQ")).toMatch(/^[0-9a-f]{4}$/);
  });
});

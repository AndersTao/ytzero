import { describe, expect, test } from "bun:test";
import { isTvUserAgent, keyDirection, pickNext, type Box } from "./tvNavigation";

const box = (left: number, top: number, width = 100, height = 60): Box =>
  ({ left, top, right: left + width, bottom: top + height });

describe("TV user agents", () => {
  test("recognises LG webOS and other television browsers", () => {
    expect(isTvUserAgent("Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 Chrome/108.0 Safari/537.36")).toBe(true);
    expect(isTvUserAgent("Mozilla/5.0 (SMART-TV; Linux; Tizen 7.0) AppleWebKit/537.36")).toBe(true);
    expect(isTvUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15")).toBe(false);
    expect(isTvUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15")).toBe(false);
  });

  test("reads arrow keys by name or by the remote's key codes", () => {
    expect(keyDirection({ key: "ArrowDown", keyCode: 40 })).toBe("down");
    expect(keyDirection({ key: "Unidentified", keyCode: 37 })).toBe("left");
    expect(keyDirection({ key: "Enter", keyCode: 13 })).toBe(null);
  });
});

describe("picking the next focus target", () => {
  // A 3×2 grid of cards, 20px apart, with a sidebar link to the left.
  const grid = [box(300, 100), box(420, 100), box(540, 100), box(300, 180), box(420, 180), box(540, 180)];
  const sidebar = box(0, 120, 200, 40);
  const all = [...grid, sidebar];

  test("moves along a row and down a column", () => {
    expect(pickNext(grid[0], all, "right")).toBe(1);
    expect(pickNext(grid[1], all, "down")).toBe(4);
    expect(pickNext(grid[4], all, "up")).toBe(1);
    expect(pickNext(grid[2], all, "left")).toBe(1);
  });

  test("goes from the first card to the sidebar on Left", () => {
    expect(pickNext(grid[0], all, "left")).toBe(6);
    expect(pickNext(grid[3], all, "left")).toBe(6);
  });

  test("prefers the aligned card over a closer one off to the side", () => {
    const offset = box(560, 175); // nearer below-right, but not in the column
    const below = box(300, 260);
    expect(pickNext(grid[0], [offset, below], "down")).toBe(1);
  });

  test("returns -1 when nothing lies in that direction", () => {
    expect(pickNext(grid[2], grid, "right")).toBe(-1);
    expect(pickNext(grid[0], grid, "up")).toBe(-1);
  });

  test("starts from the top of the screen when nothing has focus", () => {
    const top = { left: 0, top: -2, right: 1280, bottom: -1 };
    expect(pickNext(top, [box(300, 400), box(10, 60, 200, 40)], "down")).toBe(1);
  });
});

describe("candidates that only overlap the source", () => {
  test("a narrower element above-left is not 'left' of a full-width sidebar link", () => {
    const sidebarLink = box(0, 200, 240, 40);
    const logo = box(10, 10, 120, 40);
    expect(pickNext(sidebarLink, [logo], "left")).toBe(-1);
    expect(pickNext(sidebarLink, [logo], "up")).toBe(0);
  });
});

describe("staying in a column", () => {
  test("Down from a form field picks the next field, not the menu beside it", () => {
    const field = box(552, 242, 600, 32);
    const menuItem = box(292, 274, 240, 32);   // flush with the field's bottom, 20px to the left
    const nextField = box(552, 320, 600, 32);  // 46px further down
    expect(pickNext(field, [menuItem, nextField], "down")).toBe(1);
  });
});

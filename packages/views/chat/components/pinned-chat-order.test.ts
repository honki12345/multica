// @vitest-environment node
import { describe, expect, it } from "vitest";

import { pinnedOrderAfterDrop, pointerOverPinnedRows } from "./pinned-chat-order";

describe("pinnedOrderAfterDrop", () => {
  const ids = ["a", "b", "c", "d"];

  it("moves the dropped chat to the slot it was dropped on", () => {
    expect(pinnedOrderAfterDrop(ids, "a", "c")).toEqual(["b", "c", "a", "d"]);
    expect(pinnedOrderAfterDrop(ids, "d", "a")).toEqual(["d", "a", "b", "c"]);
  });

  it("returns null when nothing moves", () => {
    expect(pinnedOrderAfterDrop(ids, "b", "b")).toBeNull();
    // Dropped outside the pinned group.
    expect(pinnedOrderAfterDrop(ids, "b", null)).toBeNull();
    // Either end is not a pinned chat.
    expect(pinnedOrderAfterDrop(ids, "x", "a")).toBeNull();
    expect(pinnedOrderAfterDrop(ids, "a", "x")).toBeNull();
  });
});

describe("pointerOverPinnedRows", () => {
  const row = (top: number) => ({ top, left: 0, width: 300, height: 56 });
  // The list shows y 0..224; the first row is scrolled above it but mounted.
  const viewport = { top: 0, left: 0, width: 300, height: 224 };
  const rows = [row(-56), row(0), row(56)];

  it("is true over a visible pinned row", () => {
    expect(pointerOverPinnedRows({ x: 100, y: 30 }, rows, viewport)).toBe(true);
  });

  it("is false above the list, even over a row scrolled out of view", () => {
    expect(pointerOverPinnedRows({ x: 100, y: -20 }, rows, viewport)).toBe(false);
  });

  it("is false beside the list and below the last pinned row", () => {
    expect(pointerOverPinnedRows({ x: 600, y: 30 }, rows, viewport)).toBe(false);
    expect(pointerOverPinnedRows({ x: 100, y: 150 }, rows, viewport)).toBe(false);
  });

  it("is false when the visible area or the rows are unknown", () => {
    expect(pointerOverPinnedRows({ x: 100, y: 30 }, rows, null)).toBe(false);
    expect(pointerOverPinnedRows({ x: 100, y: 30 }, [], viewport)).toBe(false);
  });
});

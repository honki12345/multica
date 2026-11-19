// @vitest-environment node
import { describe, expect, it } from "vitest";
import { findPromptTarget, type PromptAnchor } from "./prompt-navigation";

// Rows in list order; `true` marks a message the reader sent.
//            0      1      2     3      4     5
const ROWS = [true, false, true, false, false, true];

function target(
  direction: "previous" | "next",
  anchor: PromptAnchor | null,
  atEnd = false,
  prompts: readonly boolean[] = ROWS,
  hasOlder = false,
) {
  return findPromptTarget({ prompts, anchor, atEnd, hasOlder, direction });
}

describe("findPromptTarget", () => {
  it("steps back to the sent message before the one whose start is on screen", () => {
    expect(target("previous", { index: 2, startVisible: true })).toEqual({ kind: "row", index: 0 });
  });

  it("goes to the start of a sent message that is scrolled partly out of view", () => {
    expect(target("previous", { index: 2, startVisible: false })).toEqual({ kind: "row", index: 2 });
  });

  it("skips replies when stepping back", () => {
    expect(target("previous", { index: 4, startVisible: false })).toEqual({ kind: "row", index: 2 });
  });

  it("does nothing before the first sent message", () => {
    expect(target("previous", { index: 0, startVisible: true })).toBeNull();
    expect(target("previous", { index: 1, startVisible: true }, false, [false, false])).toBeNull();
  });

  it("steps forward to the next sent message, skipping replies", () => {
    expect(target("next", { index: 0, startVisible: true })).toEqual({ kind: "row", index: 2 });
    expect(target("next", { index: 2, startVisible: false })).toEqual({ kind: "row", index: 5 });
  });

  it("goes to the live end after the last sent message", () => {
    expect(target("next", { index: 5, startVisible: true })).toEqual({ kind: "end" });
  });

  it("does nothing going forward once the list cannot scroll further", () => {
    expect(target("next", { index: 3, startVisible: false }, true)).toBeNull();
  });

  it("climbs to the oldest loaded row when earlier sent messages are not loaded yet", () => {
    // Row 0 coming into view is what makes the list fetch the older page.
    expect(target("previous", { index: 3, startVisible: true }, false, [false, false, false, true], true))
      .toEqual({ kind: "row", index: 0 });
    expect(target("previous", { index: 2, startVisible: true }, false, [false, false, false], true))
      .toEqual({ kind: "row", index: 0 });
  });

  it("starts from the newest row going back when no row is measured", () => {
    expect(target("previous", null)).toEqual({ kind: "row", index: 5 });
  });

  it("does not jump to the end going forward when no row is measured", () => {
    expect(target("next", null)).toBeNull();
  });
});

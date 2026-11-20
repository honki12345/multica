// @vitest-environment node
import { describe, expect, it } from "vitest";

import { pinnedOrderAfterDrop } from "./pinned-chat-order";

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

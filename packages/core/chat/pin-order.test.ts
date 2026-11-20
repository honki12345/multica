// @vitest-environment node
import { describe, expect, it } from "vitest";

import type { ChatSession } from "../types/chat";
import { applyPinnedOrder } from "./pin-order";

const session = (over: Partial<ChatSession> & Pick<ChatSession, "id">): ChatSession => ({
  workspace_id: "w",
  agent_id: "a",
  creator_id: "c",
  title: "t",
  status: "active",
  has_unread: false,
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
  ...over,
});

describe("applyPinnedOrder", () => {
  const now = Date.parse("2026-11-20T05:00:00.000Z");

  it("restamps pinned_at top-down so the list sorts into the new order", () => {
    const sessions = [
      session({ id: "a", pinned: true, pinned_at: "2026-11-01T00:00:00Z" }),
      session({ id: "b", pinned: true, pinned_at: "2026-10-01T00:00:00Z" }),
      session({ id: "c", pinned: true, pinned_at: "2026-09-01T00:00:00Z" }),
      session({ id: "u", updated_at: "2026-11-19T00:00:00Z" }),
    ];

    const next = applyPinnedOrder(sessions, ["c", "a", "b"], now);

    expect(next.map((s) => s.id)).toEqual(["c", "a", "b", "u"]);
    expect(next.find((s) => s.id === "c")?.pinned_at).toBe("2026-11-20T05:00:00.000Z");
    expect(next.find((s) => s.id === "a")?.pinned_at).toBe("2026-11-20T04:59:59.999Z");
    expect(next.find((s) => s.id === "b")?.pinned_at).toBe("2026-11-20T04:59:59.998Z");
    // Activity is untouched: a reorder is not a new message.
    expect(next.find((s) => s.id === "c")?.updated_at).toBe("2026-01-01T00:00:00Z");
  });

  it("leaves unpinned and unlisted chats alone and does not mutate the input", () => {
    const u = session({ id: "u" });
    const sessions = [session({ id: "a", pinned: true, pinned_at: "2026-11-01T00:00:00Z" }), u];

    const next = applyPinnedOrder(sessions, ["a"], now);

    expect(next[1]).toBe(u);
    expect(sessions[0]?.pinned_at).toBe("2026-11-01T00:00:00Z");
  });
});

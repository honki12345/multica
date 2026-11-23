// Modified by honki12345, 2026: cover chat bar sessions with no chip cap (CALA-72), the dragged order (CALA-300) and fitting chips by width (CALA-350).

import { describe, expect, it } from "vitest";
import type { ChatSession } from "@multica/core/types";
import { chatActivity, chipsThatFit, selectChatBarSessions } from "./chat-bar-sessions";

function session(id: string, minute: number, overrides: Partial<ChatSession> = {}): ChatSession {
  const at = new Date(Date.UTC(2026, 10, 11, 8, minute)).toISOString();
  return {
    id,
    workspace_id: "ws-1",
    agent_id: "agent-1",
    creator_id: "user-1",
    title: id,
    status: "active",
    has_unread: false,
    created_at: at,
    updated_at: at,
    ...overrides,
  };
}

const ids = (items: { session: ChatSession }[]) => items.map((item) => item.session.id);

function select(
  input: Partial<Parameters<typeof selectChatBarSessions>[0]> & { sessions: ChatSession[] },
) {
  return selectChatBarSessions({
    runningSessionIds: new Set(),
    openSessionId: null,
    kept: [],
    dismissed: {},
    order: [],
    maxVisible: 4,
    ...input,
  });
}

describe("selectChatBarSessions", () => {
  it("keeps only chats that are running, unread or open", () => {
    const { visible, overflow } = select({
      sessions: [
        session("idle", 1),
        session("running", 2),
        session("unread", 3, { has_unread: true }),
        session("open", 4),
      ],
      runningSessionIds: new Set(["running"]),
      openSessionId: "open",
      maxVisible: 4,
    });

    expect(ids(visible)).toEqual(["open", "unread", "running"]);
    expect(visible.map((item) => [item.running, item.unread, item.open])).toEqual([
      [false, false, true],
      [false, true, false],
      [true, false, false],
    ]);
    expect(overflow).toEqual([]);
  });

  it("keeps the chip of a chat that was opened here, after it is read and closed", () => {
    const { visible } = select({
      sessions: [session("opened", 1), session("never-opened", 2)],
      kept: ["opened"],
    });

    expect(ids(visible)).toEqual(["opened"]);
  });

  it("hides a closed chip until its chat moves again", () => {
    const quiet = session("closed", 1, { has_unread: true });
    const moved = session("moved", 2, {
      has_unread: true,
      last_message: { created_at: new Date(Date.UTC(2026, 10, 11, 9)).toISOString() } as ChatSession["last_message"],
    });
    const { visible } = select({
      sessions: [quiet, moved],
      kept: ["closed"],
      dismissed: { closed: chatActivity(quiet), moved: moved.updated_at },
    });

    expect(ids(visible)).toEqual(["moved"]);
  });

  it("shows the open chat even when its chip was closed", () => {
    const closed = session("closed", 1);
    const { visible } = select({
      sessions: [closed],
      openSessionId: "closed",
      dismissed: { closed: chatActivity(closed) },
    });

    expect(ids(visible)).toEqual(["closed"]);
  });

  it("leaves archived chats out even when they are unread or running", () => {
    const { visible } = select({
      sessions: [
        session("archived-unread", 1, { status: "archived", has_unread: true }),
        session("archived-running", 2, { status: "archived" }),
      ],
      runningSessionIds: new Set(["archived-running"]),
      openSessionId: null,
      maxVisible: 4,
    });

    expect(visible).toEqual([]);
  });

  it("orders by creation, so a newer message does not reorder the chips", () => {
    const { visible } = select({
      sessions: [
        session("older", 1, {
          has_unread: true,
          updated_at: new Date(Date.UTC(2026, 10, 11, 9)).toISOString(),
        }),
        session("newer", 2, { has_unread: true }),
      ],
      runningSessionIds: new Set(),
      openSessionId: null,
      maxVisible: 4,
    });

    expect(ids(visible)).toEqual(["newer", "older"]);
  });

  it("follows the order the chips were dragged into", () => {
    const { visible } = select({
      sessions: [1, 2, 3].map((n) => session(`s${n}`, n, { has_unread: true })),
      order: ["s1", "s3", "s2"],
    });

    expect(ids(visible)).toEqual(["s1", "s3", "s2"]);
  });

  it("puts a chip that is not in the dragged order first, newest first", () => {
    const { visible } = select({
      sessions: [1, 2, 3, 4].map((n) => session(`s${n}`, n, { has_unread: true })),
      order: ["s1", "s2"],
    });

    expect(ids(visible)).toEqual(["s4", "s3", "s1", "s2"]);
  });

  it("skips ordered chats that have no chip", () => {
    const { visible } = select({
      sessions: [session("s1", 1, { has_unread: true }), session("s2", 2), session("s3", 3, { has_unread: true })],
      order: ["gone", "s3", "s2", "s1"],
    });

    expect(ids(visible)).toEqual(["s3", "s1"]);
  });

  it("still brings the open chat out of the overflow when the chips were reordered", () => {
    const { visible } = select({
      sessions: [1, 2, 3].map((n) => session(`s${n}`, n, { has_unread: true })),
      order: ["s3", "s2", "s1"],
      openSessionId: "s1",
      maxVisible: 2,
    });

    expect(ids(visible)).toEqual(["s1", "s3"]);
  });

  it("shows every chip with no overflow when there is no limit", () => {
    const sessions = [1, 2, 3, 4, 5, 6].map((n) => session(`s${n}`, n, { has_unread: true }));
    const { visible, overflow } = selectChatBarSessions({
      sessions,
      runningSessionIds: new Set(),
      openSessionId: "s1",
      kept: [],
      dismissed: {},
      order: [],
    });

    expect(ids(visible)).toEqual(["s6", "s5", "s4", "s3", "s2", "s1"]);
    expect(overflow).toEqual([]);
  });

  it("puts what does not fit into the overflow", () => {
    const { visible, overflow } = select({
      sessions: [1, 2, 3, 4].map((n) => session(`s${n}`, n, { has_unread: true })),
      runningSessionIds: new Set(),
      openSessionId: null,
      maxVisible: 2,
    });

    expect(ids(visible)).toEqual(["s4", "s3"]);
    expect(ids(overflow)).toEqual(["s2", "s1"]);
  });

  it("brings the open chat out of the overflow, because the window opens above its chip", () => {
    const { visible, overflow } = select({
      sessions: [1, 2, 3, 4].map((n) => session(`s${n}`, n, { has_unread: true })),
      runningSessionIds: new Set(),
      openSessionId: "s1",
      maxVisible: 2,
    });

    expect(ids(visible)).toEqual(["s1", "s4"]);
    expect(ids(overflow)).toEqual(["s3", "s2"]);
  });

  it("always has room for one chip", () => {
    const { visible } = select({
      sessions: [session("only", 1, { has_unread: true })],
      runningSessionIds: new Set(),
      openSessionId: null,
      maxVisible: 0,
    });

    expect(ids(visible)).toEqual(["only"]);
  });
});

describe("chipsThatFit", () => {
  const item = (id: string, open = false) => ({
    session: session(id, 1),
    running: false,
    unread: true,
    open,
  });
  const fit = (items: ReturnType<typeof item>[], widths: Record<string, number>, room: number) =>
    chipsThatFit({ items, widthOf: (id) => widths[id] ?? 0, room, gap: 2, more: 30 });

  it("fits every chip when they all fit, with no room kept for +N", () => {
    const items = ["a", "b", "c"].map((id) => item(id));
    // 3 x 100 plus 2 gaps of 2px.
    expect(fit(items, { a: 100, b: 100, c: 100 }, 304)).toBe(3);
  });

  it("fits as many chips as there is room for beside the +N button", () => {
    const items = ["a", "b", "c", "d"].map((id) => item(id));
    const widths = { a: 100, b: 100, c: 100, d: 100 };
    // a, b and the +N button: 100 + 2 + 100 + 2 + 30.
    expect(fit(items, widths, 303)).toBe(2);
    expect(fit(items, widths, 234)).toBe(2);
    expect(fit(items, widths, 233)).toBe(1);
  });

  it("measures each chip, so short titles fit more chips", () => {
    const items = ["a", "b", "c", "d", "e"].map((id) => item(id));
    expect(fit(items, { a: 40, b: 40, c: 40, d: 40, e: 160 }, 200)).toBe(4);
  });

  it("has no cap on how many chips fit", () => {
    const items = Array.from({ length: 12 }, (_, n) => item(`s${n}`));
    const widths = Object.fromEntries(items.map((it) => [it.session.id, 60]));
    expect(fit(items, widths, 2000)).toBe(12);
  });

  it("always fits one chip", () => {
    const items = ["a", "b"].map((id) => item(id));
    expect(fit(items, { a: 100, b: 100 }, 50)).toBe(1);
  });

  it("counts the open chat's chip first when it would be folded away", () => {
    // The open chip is brought to the front, so the room it takes is what counts.
    const items = [item("a"), item("b"), item("c"), item("open", true)];
    const widths = { a: 40, b: 40, c: 40, open: 150 };
    // In order, a, b and c fit beside +N; with the open chip first only it and a do.
    expect(fit(items, widths, 200)).toBe(1);
    expect(fit(items, widths, 230)).toBe(2);
  });
});

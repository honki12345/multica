import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { I18nProvider } from "@multica/core/i18n/react";
import { configureShortcutPlatform } from "@multica/core/shortcuts";
import type { ChatMessage } from "@multica/core/types";
import type { ReactElement } from "react";
import enChat from "../../locales/en/chat.json";

// Virtuoso cannot lay out rows in jsdom. The stub renders every row with the
// absolute index the real list puts on its items (`data-item-index`) and
// records each `scrollToIndex`, which is the only way the shortcut may move a
// virtualized list. Row geometry is set per test.
const scrollCalls = new Map<string, unknown[]>();

vi.mock("react-virtuoso", () => ({
  Virtuoso: ({
    ref,
    data,
    firstItemIndex = 0,
    itemContent,
    computeItemKey,
  }: {
    ref?: { current: unknown } | ((handle: unknown) => void);
    data: unknown[];
    firstItemIndex?: number;
    itemContent: (i: number, item: unknown) => ReactElement;
    computeItemKey: (i: number, item: unknown) => string;
  }) => {
    const handle = {
      scrollToIndex: (location: unknown) => {
        const key = computeItemKey(0, data[0]);
        scrollCalls.set(key, [...(scrollCalls.get(key) ?? []), location]);
      },
    };
    if (typeof ref === "function") ref(handle);
    else if (ref) ref.current = handle;
    return (
      <div>
        {data.map((item, i) => (
          <div key={computeItemKey(i, item)} data-item-index={firstItemIndex + i}>
            {itemContent(i, item)}
          </div>
        ))}
      </div>
    );
  },
}));

import { ChatMessageList } from "./chat-message-list";

const ROW_HEIGHT = 400;
const VIEWPORT = 600;

function message(id: string, role: "user" | "assistant", extra: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id,
    chat_session_id: "session-1",
    role,
    content: `${role} ${id}`,
    task_id: role === "assistant" ? `task-${id}` : null,
    created_at: "2026-11-19T00:00:00Z",
    ...extra,
  } as ChatMessage;
}

// u = sent by the reader, a = reply, w = wakeup turn (a user row nobody typed)
function conversation(prefix: string, shape: string): ChatMessage[] {
  return [...shape].map((kind, i) =>
    kind === "a"
      ? message(`${prefix}${i}`, "assistant")
      : message(`${prefix}${i}`, "user", kind === "w" ? { message_kind: "wakeup", wakeup_id: "w1" } : {}),
  );
}

function rect(top: number, height: number): DOMRect {
  return { top, bottom: top + height, height, left: 0, right: 800, width: 800, x: 0, y: top, toJSON: () => ({}) } as DOMRect;
}

/** Lays rows out top to bottom and scrolls so `topRow` starts `offset` px above the viewport, or to the end. */
function layOut(list: HTMLElement, { topRow, offset = 0, atEnd = false }: { topRow: number; offset?: number; atEnd?: boolean }) {
  const rows = Array.from(list.querySelectorAll<HTMLElement>("[data-item-index]"));
  const contentHeight = rows.length * ROW_HEIGHT;
  const scrollTop = atEnd ? contentHeight - VIEWPORT : topRow * ROW_HEIGHT + offset;
  Object.defineProperties(list, {
    scrollTop: { configurable: true, get: () => scrollTop },
    scrollHeight: { configurable: true, get: () => contentHeight },
    clientHeight: { configurable: true, get: () => VIEWPORT },
    getClientRects: { configurable: true, value: () => [rect(0, VIEWPORT)] },
  });
  list.getBoundingClientRect = () => rect(0, VIEWPORT);
  rows.forEach((row, i) => {
    row.getBoundingClientRect = () => rect(i * ROW_HEIGHT - scrollTop, ROW_HEIGHT);
  });
}

function renderChats(chats: { messages: ChatMessage[]; floating?: boolean; hasOlder?: boolean }[]) {
  const qc = new QueryClient();
  const view = render(
    <I18nProvider locale="en" resources={{ en: { chat: enChat } }}>
      <QueryClientProvider client={qc}>
        {chats.map(({ messages, floating, hasOlder }, i) => {
          const list = (
            <ChatMessageList
              messages={messages}
              pendingTask={null}
              availability="online"
              firstItemIndex={1000}
              hasOlderMessages={hasOlder}
            />
          );
          return floating ? (
            <div key={i} data-mc="chat-window">
              {list}
              <textarea aria-label="composer" />
            </div>
          ) : (
            <div key={i}>{list}</div>
          );
        })}
      </QueryClientProvider>
    </I18nProvider>,
  );
  const lists = Array.from(view.container.querySelectorAll<HTMLElement>("[data-tab-scroll-root]"));
  // The list stays inert until it has landed on the newest message.
  act(() => {
    vi.advanceTimersByTime(1000);
  });
  return { view, lists };
}

function press(target: Element | Document, key: "[" | "]") {
  fireEvent.keyDown(target, {
    key: key === "[" ? "\u201c" : "\u2018",
    code: key === "[" ? "BracketLeft" : "BracketRight",
    metaKey: true,
    altKey: true,
    bubbles: true,
  });
}

// Animation frames run only when a test calls `frames()`.
let frameQueue = new Map<number, FrameRequestCallback>();
let nextFrame = 1;

function frames(count = 1) {
  for (let i = 0; i < count; i++) {
    const due = frameQueue;
    frameQueue = new Map();
    act(() => {
      for (const cb of due.values()) cb(performance.now());
    });
  }
}

/** Index moves the shortcut asked for, without the live-end pins. */
function promptMoves(key: string) {
  return (scrollCalls.get(key) ?? []).filter((call) => (call as { index: unknown }).index !== "LAST");
}

beforeEach(() => {
  scrollCalls.clear();
  frameQueue = new Map();
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
    const id = nextFrame++;
    frameQueue.set(id, cb);
    return id;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => {
    frameQueue.delete(id);
  });
  configureShortcutPlatform("macos");
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  configureShortcutPlatform(null);
});

describe("ChatMessageList previous/next sent message", () => {
  it("brings the previous sent message to the top, skipping replies and wakeup turns", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uawaua") }]);
    layOut(lists[0]!, { topRow: 4 });

    press(document.body, "[");

    expect(scrollCalls.get("p0")).toEqual([{ index: 0, align: "start" }]);
  });

  it("first returns to the start of a sent message cut off at the top", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    layOut(lists[0]!, { topRow: 2, offset: 50 });

    press(document.body, "[");

    expect(scrollCalls.get("p0")).toEqual([{ index: 2, align: "start" }]);
  });

  it("counts every press of a burst, even before the list has moved for the previous one", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauauaua") }]);
    layOut(lists[0]!, { topRow: 6 });

    // The list does not move between the presses: rows render after the keys.
    press(document.body, "[");
    press(document.body, "[");
    press(document.body, "[");

    expect(scrollCalls.get("p0")).toEqual([
      { index: 4, align: "start" },
      { index: 2, align: "start" },
      { index: 0, align: "start" },
    ]);
  });

  it("steps from the list again once the reader scrolls it", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 6 });

    press(document.body, "[");
    // The reader takes over: a wheel turn, and the list ends up at row 2.
    fireEvent.wheel(list, { deltaY: -100 });
    layOut(list, { topRow: 2 });
    press(document.body, "[");

    expect(scrollCalls.get("p0")).toEqual([
      { index: 4, align: "start" },
      { index: 0, align: "start" },
    ]);
  });

  it("puts the message back at the top when a row above it grows after it lands", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    layOut(list, { topRow: 2 });
    frames(3);
    expect(promptMoves("p0")).toHaveLength(1);

    // The reply above finishes rendering and pushes the message 300px down.
    layOut(list, { topRow: 2, offset: -300 });
    frames(2);

    expect(promptMoves("p0")).toEqual([
      { index: 2, align: "start" },
      { index: 2, align: "start" },
    ]);
  });

  it("aims again when the jump stops short of the message", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    // Virtuoso lands on an estimate: the message ends up 300px down, and stays.
    layOut(list, { topRow: 2, offset: -300 });
    frames(3);

    expect(promptMoves("p0")).toEqual([
      { index: 2, align: "start" },
      { index: 2, align: "start" },
    ]);
  });

  it("does not aim again while the list is still moving", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    for (const offset of [-900, -600, -300]) {
      layOut(list, { topRow: 2, offset });
      frames();
    }

    expect(promptMoves("p0")).toHaveLength(1);
  });

  it("leaves the list alone after the reader scrolls it", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    layOut(list, { topRow: 2 });
    frames();

    fireEvent.wheel(list, { deltaY: -100 });
    layOut(list, { topRow: 2, offset: -300 });
    frames(3);

    expect(promptMoves("p0")).toHaveLength(1);
  });

  it("leaves the list alone after the reader scrolls it with the keyboard", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    layOut(list, { topRow: 2 });
    frames();

    fireEvent.keyDown(list, { key: "PageUp", code: "PageUp" });
    layOut(list, { topRow: 1, offset: 100 });
    frames(3);

    expect(promptMoves("p0")).toHaveLength(1);
  });

  it("lets Jump to latest, pressed from the keyboard, take the list", () => {
    const { view, lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    layOut(list, { topRow: 2 });
    frames();

    // The button shows once the list is a screen away from the end.
    fireEvent.scroll(list);
    frames();
    const button = view.getByRole("button", { name: "Jump to latest" });
    fireEvent.keyDown(button, { key: "Enter", code: "Enter" });
    fireEvent.click(button);
    layOut(list, { topRow: 0, atEnd: true });
    frames(3);

    expect(promptMoves("p0")).toHaveLength(1);
  });

  it("keeps the burst going while the modifiers are pressed again between taps", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauauaua") }]);
    layOut(lists[0]!, { topRow: 6 });

    press(document.body, "[");
    fireEvent.keyDown(document.body, { key: "Meta", code: "MetaLeft", metaKey: true });
    fireEvent.keyDown(document.body, { key: "Alt", code: "AltLeft", metaKey: true, altKey: true });
    press(document.body, "[");

    expect(promptMoves("p0")).toEqual([
      { index: 4, align: "start" },
      { index: 2, align: "start" },
    ]);
  });

  it("stops holding the message once it has stayed put for a while", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    const list = lists[0]!;
    layOut(list, { topRow: 4 });
    press(document.body, "[");
    layOut(list, { topRow: 2 });
    frames(120);

    layOut(list, { topRow: 2, offset: -300 });
    frames(3);

    expect(promptMoves("p0")).toHaveLength(1);
  });

  it("goes to the live end after the last sent message, and stops there", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    layOut(lists[0]!, { topRow: 4 });

    press(document.body, "]");
    expect(scrollCalls.get("p0")).toEqual([{ index: "LAST", align: "end" }]);

    scrollCalls.clear();
    layOut(lists[0]!, { topRow: 0, atEnd: true });
    press(document.body, "]");
    expect(scrollCalls.get("p0")).toBeUndefined();
  });

  it("moves the floating chat while its composer has focus, and the page chat otherwise", () => {
    const { view, lists } = renderChats([
      { messages: conversation("page", "uauaua") },
      { messages: conversation("float", "uauaua"), floating: true },
    ]);
    for (const list of lists) layOut(list, { topRow: 4 });

    press(view.getByLabelText("composer"), "[");
    expect(scrollCalls.get("float0")).toEqual([{ index: 2, align: "start" }]);
    expect(scrollCalls.get("page0")).toBeUndefined();

    press(document.body, "[");
    expect(scrollCalls.get("page0")).toEqual([{ index: 2, align: "start" }]);
    expect(scrollCalls.get("float0")).toHaveLength(1);
  });

  it("climbs to the oldest loaded row so the older page loads when no earlier sent message is loaded", () => {
    const { lists } = renderChats([{ messages: conversation("p", "wawaua"), hasOlder: true }]);
    layOut(lists[0]!, { topRow: 4 });

    press(document.body, "[");

    expect(scrollCalls.get("p0")).toEqual([{ index: 0, align: "start" }]);
  });

  it("ignores the chord while an IME composition is in progress", () => {
    const { lists } = renderChats([{ messages: conversation("p", "uauaua") }]);
    layOut(lists[0]!, { topRow: 4 });

    fireEvent.keyDown(document.body, {
      key: "\u201c",
      code: "BracketLeft",
      metaKey: true,
      altKey: true,
      isComposing: true,
    });

    expect(scrollCalls.get("p0")).toBeUndefined();
  });
});

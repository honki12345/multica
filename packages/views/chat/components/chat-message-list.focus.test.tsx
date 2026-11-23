import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { I18nProvider } from "@multica/core/i18n/react";
import type { ChatMessage } from "@multica/core/types";
import { useState, type ReactElement } from "react";
import { Popover, PopoverContent, PopoverTrigger } from "@multica/ui/components/ui/popover";
import enChat from "../../locales/en/chat.json";

// Virtuoso cannot lay out rows in jsdom; every row is rendered as is.
vi.mock("react-virtuoso", () => ({
  Virtuoso: ({
    data,
    itemContent,
    computeItemKey,
  }: {
    data: unknown[];
    itemContent: (i: number, item: unknown) => ReactElement;
    computeItemKey: (i: number, item: unknown) => string;
  }) => (
    <div>
      {data.map((item, i) => (
        <div key={computeItemKey(i, item)}>{itemContent(i, item)}</div>
      ))}
    </div>
  ),
}));

import { ChatMessageList } from "./chat-message-list";

function message(id: string, role: "user" | "assistant"): ChatMessage {
  return {
    id,
    chat_session_id: "session-1",
    role,
    content: `${role} ${id}`,
    task_id: role === "assistant" ? `task-${id}` : null,
    created_at: "2026-11-20T00:00:00Z",
  } as ChatMessage;
}

const MESSAGES = [message("m0", "user"), message("m1", "assistant")];

/** The chat page: a thread row on the left, the conversation and its composer on the right. */
function renderPage({
  focusRequested = false,
  onFocusRequestApplied = vi.fn(),
}: {
  focusRequested?: boolean;
  onFocusRequestApplied?: () => void;
} = {}) {
  const qc = new QueryClient();
  const ui = (requested: boolean, messages = MESSAGES) => (
    <I18nProvider locale="en" resources={{ en: { chat: enChat } }}>
      <QueryClientProvider client={qc}>
        <nav aria-label="threads">
          <div aria-current="true" tabIndex={0}>
            Chat row
          </div>
        </nav>
        <ChatMessageList
          messages={messages}
          pendingTask={null}
          availability="online"
          focusRequested={requested}
          onFocusRequestApplied={onFocusRequestApplied}
        />
        <textarea aria-label="composer" />
      </QueryClientProvider>
    </I18nProvider>
  );
  const view = render(ui(focusRequested));
  const conversation = view.container.querySelector<HTMLElement>("[data-tab-scroll-root]")!;
  const row = view.getByText("Chat row");
  const composer = view.getByRole("textbox", { name: "composer" });
  return {
    view,
    conversation,
    row,
    composer,
    rerender: (requested: boolean, messages?: ChatMessage[]) => view.rerender(ui(requested, messages)),
  };
}

/** The list stays hidden until it has landed on the newest message. */
function reveal() {
  act(() => {
    vi.advanceTimersByTime(1000);
  });
  // The reveal is a state update; its effects run on the next commit.
  act(() => {});
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  vi.stubGlobal("requestAnimationFrame", () => 0);
  vi.stubGlobal("cancelAnimationFrame", () => {});
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("ChatMessageList keyboard focus", () => {
  it("takes the keys when the reader clicks a message's text", async () => {
    vi.useRealTimers();
    const user = userEvent.setup();
    const { view, conversation, row } = renderPage();
    await user.click(row);
    expect(document.activeElement).toBe(row);

    await user.click(view.getByText("user m0"));

    expect(document.activeElement).toBe(conversation);
  });

  it("stays out of the Tab order", async () => {
    vi.useRealTimers();
    const { conversation, row } = renderPage();
    row.focus();

    for (let i = 0; i < 5; i++) {
      await userEvent.tab();
      expect(document.activeElement).not.toBe(conversation);
    }
  });

  it("moves focus from the row that opened the chat once the list has landed, without scrolling", () => {
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    const applied = vi.fn();
    const { conversation, row, rerender } = renderPage({ onFocusRequestApplied: applied });
    row.focus();

    rerender(true);
    // Hidden while it lands: focusing it now would be lost.
    expect(document.activeElement).toBe(row);

    reveal();

    expect(document.activeElement).toBe(conversation);
    expect(focus).toHaveBeenLastCalledWith({ preventScroll: true });
    expect(applied).toHaveBeenCalledTimes(1);
    focus.mockRestore();
  });

  it("takes a request again for the chat already open", () => {
    const { conversation, row, rerender } = renderPage();
    reveal();
    row.focus();

    rerender(true);

    expect(document.activeElement).toBe(conversation);
  });

  it("leaves the caret in the composer", () => {
    const applied = vi.fn();
    const { composer, rerender } = renderPage({ onFocusRequestApplied: applied });
    composer.focus();

    rerender(true);
    reveal();

    expect(document.activeElement).toBe(composer);
    expect(applied).toHaveBeenCalledTimes(1);
  });

  it("does not pull focus back after the reader tabs out to the list", async () => {
    // Like the page: settling the request clears it.
    let requested = true;
    const { conversation, row, rerender } = renderPage({
      onFocusRequestApplied: () => {
        requested = false;
      },
    });
    row.focus();
    rerender(requested);
    reveal();
    expect(document.activeElement).toBe(conversation);
    rerender(requested);

    vi.useRealTimers();
    await userEvent.tab({ shift: true });
    expect(document.activeElement).toBe(row);
    // The list keeps re-rendering as replies stream in.
    rerender(requested, [...MESSAGES, message("m2", "user")]);
    rerender(requested, [...MESSAGES, message("m2", "user"), message("m3", "assistant")]);

    expect(document.activeElement).toBe(row);
  });
});

describe("ChatMessageList keyboard focus after a pick from a closing popover", () => {
  // The floating window's history is a popover. A pick closes it, and while it
  // animates out the clicked row keeps focus; when it is removed, focus goes
  // back to its trigger. A list that lands in that window must still end up
  // with the keys.
  let finishExit: (() => void) | null = null;

  function HistoryPick() {
    const [open, setOpen] = useState(true);
    const [session, setSession] = useState("s1");
    const [requested, setRequested] = useState<string | null>(null);
    return (
      <I18nProvider locale="en" resources={{ en: { chat: enChat } }}>
        <QueryClientProvider client={new QueryClient()}>
          <Popover open={open} onOpenChange={setOpen}>
            <PopoverTrigger>history</PopoverTrigger>
            <PopoverContent>
              <div
                tabIndex={0}
                onClick={() => {
                  setSession("s2");
                  setRequested("s2");
                  setOpen(false);
                }}
              >
                Other chat
              </div>
            </PopoverContent>
          </Popover>
          <ChatMessageList
            key={session}
            messages={MESSAGES}
            pendingTask={null}
            availability="online"
            focusRequested={requested === session}
            onFocusRequestApplied={() => setRequested(null)}
          />
        </QueryClientProvider>
      </I18nProvider>
    );
  }

  // Base UI reads the exit animation a frame after closing.
  let frames: FrameRequestCallback[] = [];
  const runFrames = () => {
    for (let i = 0; i < 5; i++) {
      const due = frames;
      frames = [];
      due.forEach((cb) => cb(performance.now()));
    }
  };

  beforeEach(() => {
    frames = [];
    vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => frames.push(cb));
    let exit: Promise<void> | null = null;
    Object.defineProperty(Element.prototype, "getAnimations", {
      configurable: true,
      value(this: Element) {
        if (!this.closest('[data-slot="popover-content"]') && this.getAttribute("data-slot") !== "popover-content") return [];
        exit ??= new Promise<void>((resolve) => {
          finishExit = resolve;
        });
        return [{ finished: exit }];
      },
    });
  });

  afterEach(() => {
    delete (Element.prototype as unknown as { getAnimations?: unknown }).getAnimations;
    finishExit = null;
  });

  it("takes the keys once the popover has let go, even when the list lands first", async () => {
    const view = render(<HistoryPick />);
    const row = view.getByText("Other chat");
    row.focus();

    act(() => row.click());
    act(() => runFrames());
    reveal();
    // The list has landed; the popover is still on screen with the row focused.
    expect(document.querySelector('[data-slot="popover-content"]')).not.toBeNull();
    expect(document.activeElement).toBe(row);

    await act(async () => {
      finishExit?.();
      await Promise.resolve();
      await Promise.resolve();
    });
    await act(async () => {
      runFrames();
      vi.advanceTimersByTime(200);
    });
    expect(document.querySelector('[data-slot="popover-content"]')).toBeNull();

    expect(document.activeElement).toBe(view.container.querySelector("[data-tab-scroll-root]"));
  });
});

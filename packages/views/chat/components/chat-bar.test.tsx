// Modified by honki12345, 2026: cover the horizontally scrolling chip strip (CALA-72) and dragging chips into order (CALA-300).

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, screen, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { chatSessionsOptions, pendingChatTasksOptions } from "@multica/core/chat/queries";
import type { ChatSession } from "@multica/core/types";
import { NavigationProvider, type NavigationAdapter } from "../../navigation";
import { renderWithI18n } from "../../test/i18n";
import { ChatBar } from "./chat-bar";

const WS = "ws-test";

const h = vi.hoisted(() => ({
  chat: {
    isOpen: false,
    activeSessionId: null as string | null,
    selectedAgentId: "agent-1" as string | null,
    chatBarKept: [] as string[],
    chatBarDismissed: {} as Record<string, string>,
    chatBarOrder: [] as string[],
    setOpen: vi.fn(),
    setActiveSession: vi.fn(),
    setSelectedAgentId: vi.fn(),
    startNewChat: vi.fn(),
    keepChatInBar: vi.fn(),
    dismissChatFromBar: vi.fn(),
    setChatBarOrder: vi.fn(),
  },
}));

vi.mock("@multica/core/chat", () => ({
  useChatStore: Object.assign(
    (selector: (state: typeof h.chat) => unknown) => selector(h.chat),
    { getState: () => h.chat },
  ),
}));
vi.mock("@multica/core/hooks", () => ({ useWorkspaceId: () => "ws-test" }));
vi.mock("@multica/core/paths", () => ({
  useWorkspacePaths: () => ({ chat: () => "/acme/chat" }),
}));
vi.mock("@multica/core/api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@multica/core/api")>()),
  api: { getBaseUrl: () => "http://localhost" },
}));

const adapter: NavigationAdapter = {
  push: vi.fn(),
  replace: vi.fn(),
  back: vi.fn(),
  pathname: "/acme/issues",
  searchParams: new URLSearchParams(),
  hash: "",
  getShareableUrl: (path) => path,
};

function session(id: string, minute: number, overrides: Partial<ChatSession> = {}): ChatSession {
  const at = new Date(Date.UTC(2026, 10, 11, 8, minute)).toISOString();
  return {
    id,
    workspace_id: WS,
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

function renderBar(sessions: ChatSession[], running: string[] = []) {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity } },
  });
  qc.setQueryData(chatSessionsOptions(WS).queryKey, sessions);
  qc.setQueryData(pendingChatTasksOptions(WS).queryKey, {
    tasks: running.map((id) => ({ task_id: `task-${id}`, status: "running", chat_session_id: id })),
  });
  return renderWithI18n(
    <QueryClientProvider client={qc}>
      <NavigationProvider value={adapter}>
        <ChatBar />
      </NavigationProvider>
    </QueryClientProvider>,
  );
}

const chipOrder = () =>
  Array.from(document.querySelectorAll<HTMLElement>("[data-chat-chip]")).map((el) => el.dataset.chatChip);

/**
 * jsdom lays nothing out: give each chip, in the order given, a 100px-wide
 * box side by side, so dnd-kit can tell where a dragged chip lands.
 */
function layOutChips(ids: string[]) {
  const box = (left: number, width: number) =>
    ({ left, right: left + width, width, top: 0, bottom: 20, height: 20, x: left, y: 0, toJSON: () => ({}) }) as DOMRect;
  return vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
    if (this.dataset.slot === "chat-bar-chips") return box(0, 1000);
    const id = this.dataset.chatChip ?? this.dataset.chatAnchor;
    const index = id ? ids.indexOf(id) : -1;
    return index === -1 ? box(0, 0) : box(index * 100, 100);
  });
}

const SESSIONS = [
  session("Read and done", 1),
  session("Billing progress", 2, { agent_id: "agent-2" }),
  session("Weekly report", 3, { has_unread: true }),
];

beforeEach(() => {
  vi.clearAllMocks();
  h.chat.isOpen = false;
  h.chat.activeSessionId = null;
  h.chat.selectedAgentId = "agent-1";
  h.chat.chatBarKept = [];
  h.chat.chatBarDismissed = {};
  h.chat.chatBarOrder = [];
});

describe("ChatBar", () => {
  it("shows a chip for each running or unread chat, and none for the rest", () => {
    renderBar(SESSIONS, [SESSIONS[1]!.id]);

    expect(screen.getByRole("button", { name: "Billing progress, Running" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Weekly report, Unread" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /Read and done/ })).not.toBeInTheDocument();
  });

  it("shows a chip for every chat instead of folding the rest into a +N menu", () => {
    const many = [1, 2, 3, 4, 5, 6].map((n) => session(`Chat ${n}`, n, { has_unread: true }));
    renderBar(many);

    for (const item of many) {
      expect(screen.getByRole("button", { name: `${item.id}, Unread` })).toBeInTheDocument();
    }
    expect(screen.queryByRole("button", { name: /more chat/ })).not.toBeInTheDocument();
    expect(screen.queryByText(/^\+\d+$/)).not.toBeInTheDocument();
  });

  it("scrolls the open chat's chip into view, so the window opens above it", () => {
    const many = [1, 2, 3, 4, 5, 6].map((n) => session(`Chat ${n}`, n, { has_unread: true }));
    // Chips are newest first, so the oldest chat's chip is last, past the strip's end.
    const box = (left: number, right: number) => ({ left, right }) as DOMRect;
    const rect = vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (
      this: HTMLElement,
    ) {
      if (this.dataset.slot === "chat-bar-chips") return box(0, 300);
      if (this.dataset.chatAnchor === "Chat 1") return box(500, 600);
      return box(0, 0);
    });
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Chat 1";
    try {
      const { container } = renderBar(many);
      const strip = container.querySelector<HTMLElement>('[data-slot="chat-bar-chips"]');
      expect(strip?.scrollLeft).toBe(300);
    } finally {
      rect.mockRestore();
    }
  });

  it("opens the chat window on the chip's chat, with that chat's agent", () => {
    renderBar(SESSIONS, [SESSIONS[1]!.id]);

    fireEvent.click(screen.getByRole("button", { name: "Billing progress, Running" }));

    expect(h.chat.setSelectedAgentId).toHaveBeenCalledWith("agent-2");
    expect(h.chat.setActiveSession).toHaveBeenCalledWith("Billing progress");
    expect(h.chat.keepChatInBar).toHaveBeenCalledWith("Billing progress");
    expect(h.chat.setOpen).toHaveBeenCalledWith(true);
  });

  it("switches the open window to another chip's chat without closing it", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Billing progress";
    h.chat.selectedAgentId = "agent-2";
    renderBar(SESSIONS, [SESSIONS[1]!.id]);

    fireEvent.click(screen.getByRole("button", { name: "Weekly report, Unread" }));

    expect(h.chat.setSelectedAgentId).toHaveBeenCalledWith("agent-1");
    expect(h.chat.setActiveSession).toHaveBeenCalledWith("Weekly report");
    expect(h.chat.setOpen).toHaveBeenCalledWith(true);
  });

  it("closes the window from the chip it is open on", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Weekly report";
    renderBar(SESSIONS);

    const chip = screen.getByRole("button", { name: "Weekly report, Unread" });
    expect(chip).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Ask Multica" })).toHaveAttribute("aria-pressed", "false");

    fireEvent.click(chip);

    expect(h.chat.setOpen).toHaveBeenCalledWith(false);
    expect(h.chat.setActiveSession).not.toHaveBeenCalled();
  });

  it("keeps the chip of a chat opened here once it is read and closed", () => {
    h.chat.chatBarKept = ["Read and done"];
    renderBar(SESSIONS);

    expect(screen.getByRole("button", { name: "Read and done" })).toHaveAttribute("aria-pressed", "false");
  });

  it("gives whatever chat the window shows a chip", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Read and done";
    renderBar(SESSIONS);

    expect(screen.getByRole("button", { name: "Read and done" })).toHaveAttribute("aria-pressed", "true");
    expect(h.chat.keepChatInBar).toHaveBeenCalledWith("Read and done");
  });

  it("closes a chip, and the window with it when it is open on that chat", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Weekly report";
    renderBar(SESSIONS);

    fireEvent.click(screen.getByRole("button", { name: "Close Weekly report" }));

    expect(h.chat.setOpen).toHaveBeenCalledWith(false);
    expect(h.chat.dismissChatFromBar).toHaveBeenCalledWith("Weekly report", SESSIONS[2]!.updated_at);
  });

  it("closes another chat's chip without touching the window", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Weekly report";
    renderBar(SESSIONS, [SESSIONS[1]!.id]);

    fireEvent.click(screen.getByRole("button", { name: "Close Billing progress" }));

    expect(h.chat.setOpen).not.toHaveBeenCalled();
    expect(h.chat.dismissChatFromBar).toHaveBeenCalledWith("Billing progress", SESSIONS[1]!.updated_at);
  });

  it("starts a new chat from Ask Multica, leaving the open chat behind", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = "Weekly report";
    renderBar(SESSIONS);

    const ask = screen.getByRole("button", { name: "Ask Multica" });
    expect(ask).toHaveAttribute("aria-pressed", "false");
    fireEvent.click(ask);

    expect(h.chat.startNewChat).toHaveBeenCalledTimes(1);
    expect(h.chat.setOpen).not.toHaveBeenCalled();
  });

  it("closes the window from Ask Multica while it shows the new chat", () => {
    h.chat.isOpen = true;
    h.chat.activeSessionId = null;
    renderBar(SESSIONS);

    const ask = screen.getByRole("button", { name: "Ask Multica" });
    expect(ask).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(ask);

    expect(h.chat.setOpen).toHaveBeenCalledWith(false);
    expect(h.chat.startNewChat).not.toHaveBeenCalled();
  });

  it("lays the chips out in the order they were dragged into", () => {
    h.chat.chatBarKept = ["Read and done"];
    h.chat.chatBarOrder = ["Read and done", "Weekly report"];
    renderBar(SESSIONS, [SESSIONS[1]!.id]);

    // Billing progress was never dragged, so it goes first.
    expect(chipOrder()).toEqual(["Billing progress", "Read and done", "Weekly report"]);
  });

  it("does not open the chat when its chip is dragged, and saves the new order", async () => {
    const many = [1, 2, 3].map((n) => session(`Chat ${n}`, n, { has_unread: true }));
    const rect = layOutChips(["Chat 3", "Chat 2", "Chat 1"]);
    try {
      renderBar(many);
      const chip = screen.getByRole("button", { name: "Chat 3, Unread" });
      const pointer = { isPrimary: true, button: 0, clientX: 40, clientY: 10 };
      fireEvent.pointerDown(chip, pointer);
      fireEvent.pointerMove(document, { ...pointer, clientX: 60 });
      fireEvent.pointerMove(document, { ...pointer, clientX: 230 });
      fireEvent.pointerUp(document, { ...pointer, clientX: 230 });
      fireEvent.click(chip);

      expect(h.chat.setChatBarOrder).toHaveBeenCalledWith(["Chat 2", "Chat 1", "Chat 3"]);
      expect(h.chat.setOpen).not.toHaveBeenCalled();

      // A click after the drag has settled opens the chat again.
      await new Promise((resolve) => setTimeout(resolve, 60));
      fireEvent.click(chip);
      expect(h.chat.setOpen).toHaveBeenCalledWith(true);
    } finally {
      rect.mockRestore();
    }
  });

  it("treats a press that barely moves as a click", () => {
    renderBar(SESSIONS, [SESSIONS[1]!.id]);
    const chip = screen.getByRole("button", { name: "Billing progress, Running" });
    const pointer = { isPrimary: true, button: 0, clientX: 40, clientY: 10 };
    fireEvent.pointerDown(chip, pointer);
    fireEvent.pointerMove(document, { ...pointer, clientX: 43 });
    fireEvent.pointerUp(document, { ...pointer, clientX: 43 });
    fireEvent.click(chip);

    expect(h.chat.setChatBarOrder).not.toHaveBeenCalled();
    expect(h.chat.setOpen).toHaveBeenCalledWith(true);
  });

  it("does not start a drag from a chip's close button", () => {
    renderBar(SESSIONS, [SESSIONS[1]!.id]);
    const close = screen.getByRole("button", { name: "Close Billing progress" });
    const pointer = { isPrimary: true, button: 0, clientX: 40, clientY: 10 };
    fireEvent.pointerDown(close, pointer);
    fireEvent.pointerMove(document, { ...pointer, clientX: 200 });
    fireEvent.pointerUp(document, { ...pointer, clientX: 200 });
    fireEvent.click(close);

    expect(h.chat.setChatBarOrder).not.toHaveBeenCalled();
    expect(h.chat.dismissChatFromBar).toHaveBeenCalledWith("Billing progress", SESSIONS[1]!.updated_at);
  });

  it("moves a chip with Space and the arrow keys, and still opens a chat with Enter", async () => {
    const many = [1, 2, 3].map((n) => session(`Chat ${n}`, n, { has_unread: true }));
    const rect = layOutChips(["Chat 3", "Chat 2", "Chat 1"]);
    try {
      renderBar(many);
      const chip = screen.getByRole("button", { name: "Chat 3, Unread" });
      chip.focus();

      fireEvent.keyDown(chip, { code: "Space", key: " " });
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
      fireEvent.keyDown(document, { code: "ArrowRight", key: "ArrowRight" });
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
      fireEvent.keyDown(document, { code: "Space", key: " " });
      fireEvent.keyUp(chip, { code: "Space", key: " " });
      fireEvent.click(chip);

      expect(h.chat.setChatBarOrder).toHaveBeenCalledWith(["Chat 2", "Chat 3", "Chat 1"]);
      expect(h.chat.setOpen).not.toHaveBeenCalled();

      await new Promise((resolve) => setTimeout(resolve, 60));
      fireEvent.keyDown(chip, { code: "Enter", key: "Enter" });
      fireEvent.click(chip);
      expect(h.chat.setOpen).toHaveBeenCalledWith(true);
    } finally {
      rect.mockRestore();
    }
  });

  it("opens a chat from the history, grouped by when it last moved", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date(2026, 10, 11, 20) });
    try {
      renderBar([
        session("From today", 1, { updated_at: new Date(2026, 10, 11, 9).toISOString() }),
        session("From this week", 2, { updated_at: new Date(2026, 10, 8, 9).toISOString() }),
        session("From long ago", 3, { updated_at: new Date(2026, 6, 1, 9).toISOString() }),
        session("Archived", 4, { status: "archived" }),
      ]);

      fireEvent.click(screen.getByRole("button", { name: "Chat history" }));

      const today = await screen.findByRole("group", { name: "Today" });
      expect(within(today).getByRole("button", { name: /From today/ })).toBeInTheDocument();
      expect(
        within(screen.getByRole("group", { name: "Last 7 days" })).getByRole("button", { name: /From this week/ }),
      ).toBeInTheDocument();
      expect(
        within(screen.getByRole("group", { name: "Older" })).getByRole("button", { name: /From long ago/ }),
      ).toBeInTheDocument();
      expect(screen.queryByRole("button", { name: /Archived/ })).not.toBeInTheDocument();
      expect(screen.getByRole("link", { name: "All chats" })).toHaveAttribute("href", "/acme/chat");

      fireEvent.click(screen.getByRole("button", { name: /From this week/ }));

      expect(h.chat.keepChatInBar).toHaveBeenCalledWith("From this week");
      expect(h.chat.setActiveSession).toHaveBeenCalledWith("From this week");
      expect(h.chat.setOpen).toHaveBeenCalledWith(true);
    } finally {
      vi.useRealTimers();
    }
  });
});

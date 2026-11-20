// Modified by honki12345, 2026: cover renaming the chat title with Mod+R (CALA-327).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { I18nProvider } from "@multica/core/i18n/react";
import { configureShortcutPlatform } from "@multica/core/shortcuts";
import type { Agent, ChatSession } from "@multica/core/types";
import enChat from "../../locales/en/chat.json";
import enCommon from "../../locales/en/common.json";

const updateMutate = vi.hoisted(() => vi.fn());
const pushMock = vi.hoisted(() => vi.fn());

vi.mock("@multica/core/paths", () => ({
  useWorkspacePaths: () => ({ agentDetail: (id: string) => `/agents/${id}` }),
}));

vi.mock("@multica/core/chat/mutations", () => ({
  useUpdateChatSession: () => ({ mutate: updateMutate }),
  useDeleteChatSession: () => ({ mutate: vi.fn() }),
  useSetChatSessionArchived: () => ({ mutate: vi.fn() }),
}));

vi.mock("@multica/core/chat", () => ({
  useChatStore: (selector: (state: { setActiveSession: () => void }) => unknown) =>
    selector({ setActiveSession: vi.fn() }),
}));

vi.mock("../../common/actor-avatar", () => ({
  ActorAvatar: () => null,
}));

vi.mock("./chat-wakeups", () => ({
  ChatWakeupHeaderButton: () => null,
  useChatWakeups: () => [],
}));

vi.mock("../../navigation", () => ({
  AppLink: ({ children, href }: { children: React.ReactNode; href: string }) => (
    <a href={href}>{children}</a>
  ),
  useNavigation: () => ({ push: pushMock }),
}));

import { ChatSessionHeader } from "./chat-session-header";

const TEST_RESOURCES = { en: { chat: enChat, common: enCommon } };
const RENAME_LABEL = enChat.header.rename;
const OUTSIDE_LABEL = "Outside control";

const session: ChatSession = {
  id: "session-1",
  workspace_id: "ws-1",
  agent_id: "agent-1",
  creator_id: "user-1",
  title: "Original title",
  status: "active",
  has_unread: false,
  unread_count: 0,
  last_message: null,
  pinned: false,
  created_at: new Date(0).toISOString(),
  updated_at: new Date(0).toISOString(),
};

describe("ChatSessionHeader breadcrumb", () => {
  it("leads with the agent as a link to its page, then the chat title", () => {
    const agent = { id: "agent-1", name: "Lambda" } as Agent;
    render(
      <I18nProvider locale="en" resources={TEST_RESOURCES}>
        <ChatSessionHeader session={session} agent={agent} />
      </I18nProvider>,
    );

    const header = within(screen.getByRole("banner"));
    const agentLink = header.getByRole("link", { name: "Lambda" });
    expect(agentLink).toHaveAttribute("href", "/agents/agent-1");
    const title = header.getByRole("button", { name: "Original title" });
    expect(agentLink).not.toContainElement(title);
    expect(
      agentLink.compareDocumentPosition(title) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("opens the agent's settings from the ⋯ menu", () => {
    const agent = { id: "agent-1", name: "Lambda" } as Agent;
    render(
      <I18nProvider locale="en" resources={TEST_RESOURCES}>
        <ChatSessionHeader session={session} agent={agent} />
      </I18nProvider>,
    );

    fireEvent.click(screen.getByRole("button", { name: "More actions" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Agent settings" }));
    expect(pushMock).toHaveBeenCalledWith("/agents/agent-1?view=general");
  });

  it("offers no agent settings when the chat's agent is unavailable", () => {
    render(
      <I18nProvider locale="en" resources={TEST_RESOURCES}>
        <ChatSessionHeader session={session} agent={null} />
      </I18nProvider>,
    );

    fireEvent.click(screen.getByRole("button", { name: "More actions" }));
    expect(screen.getByRole("menuitem", { name: "Rename chat" })).toBeInTheDocument();
    expect(
      screen.queryByRole("menuitem", { name: "Agent settings" }),
    ).not.toBeInTheDocument();
  });

  it("shows only the title when the chat's agent is unavailable", () => {
    render(
      <I18nProvider locale="en" resources={TEST_RESOURCES}>
        <ChatSessionHeader session={session} agent={null} />
      </I18nProvider>,
    );

    const header = within(screen.getByRole("banner"));
    expect(header.queryByRole("link")).not.toBeInTheDocument();
    expect(header.getByRole("button", { name: "Original title" })).toBeInTheDocument();
  });
});

function startRename(): HTMLInputElement {
  render(
    <>
      <I18nProvider locale="en" resources={TEST_RESOURCES}>
        <ChatSessionHeader session={session} agent={null} />
      </I18nProvider>
      <button type="button">{OUTSIDE_LABEL}</button>
    </>,
  );
  fireEvent.click(screen.getByRole("button", { name: "Original title" }));
  return screen.getByRole("textbox", { name: RENAME_LABEL });
}

describe("ChatSessionHeader rename keyboard behavior", () => {
  beforeEach(() => {
    updateMutate.mockReset();
  });

  it.each([
    ["standard composition signal", { isComposing: true, keyCode: 13 }],
    ["Safari composition signal", { isComposing: false, keyCode: 229 }],
  ])("keeps editing when Enter carries the %s", (_name, eventInit) => {
    const input = startRename();
    fireEvent.change(input, { target: { value: "yanjiu" } });

    fireEvent.keyDown(input, { key: "Enter", ...eventInit });

    expect(updateMutate).not.toHaveBeenCalled();
    expect(input).toBeInTheDocument();
    expect(input).toHaveValue("yanjiu");
  });

  it("submits once on a normal Enter", () => {
    const input = startRename();
    fireEvent.change(input, { target: { value: "Renamed chat" } });

    fireEvent.keyDown(input, { key: "Enter", isComposing: false, keyCode: 13 });

    expect(updateMutate).toHaveBeenCalledTimes(1);
    expect(updateMutate).toHaveBeenCalledWith({
      sessionId: "session-1",
      title: "Renamed chat",
    });
    expect(screen.queryByRole("textbox", { name: RENAME_LABEL })).not.toBeInTheDocument();
  });

  it("defers blur submission until an active composition ends", () => {
    const input = startRename();
    const outside = screen.getByRole("button", { name: OUTSIDE_LABEL });
    fireEvent.change(input, { target: { value: "yanjiu" } });
    fireEvent.compositionStart(input);

    act(() => {
      outside.focus();
    });

    expect(updateMutate).not.toHaveBeenCalled();
    expect(input).toBeInTheDocument();
    expect(outside).toHaveFocus();

    fireEvent.change(input, { target: { value: "研究" } });
    fireEvent.compositionEnd(input);

    expect(updateMutate).toHaveBeenCalledTimes(1);
    expect(updateMutate).toHaveBeenCalledWith({
      sessionId: "session-1",
      title: "研究",
    });
    expect(screen.queryByRole("textbox", { name: RENAME_LABEL })).not.toBeInTheDocument();
  });

  it("closes without saving a partial value when compositionend does not arrive", async () => {
    const input = startRename();
    const outside = screen.getByRole("button", { name: OUTSIDE_LABEL });
    fireEvent.change(input, { target: { value: "yanjiu" } });
    fireEvent.compositionStart(input);

    act(() => {
      outside.focus();
    });

    await waitFor(() => {
      expect(screen.queryByRole("textbox", { name: RENAME_LABEL })).not.toBeInTheDocument();
    });
    expect(updateMutate).not.toHaveBeenCalled();
    expect(screen.getByText("Original title")).toBeInTheDocument();
  });

  it("still submits the current value when focus moves outside", () => {
    const input = startRename();
    const outside = screen.getByRole("button", { name: OUTSIDE_LABEL });
    fireEvent.change(input, { target: { value: "Blurred title" } });

    act(() => {
      outside.focus();
    });

    expect(updateMutate).toHaveBeenCalledTimes(1);
    expect(updateMutate).toHaveBeenCalledWith({
      sessionId: "session-1",
      title: "Blurred title",
    });
    expect(outside).toHaveFocus();
  });

  it.each([
    ["standard composition signal", { isComposing: true, keyCode: 27 }],
    ["Safari composition signal", { isComposing: false, keyCode: 229 }],
  ])("keeps editing when Escape carries the %s", (_name, eventInit) => {
    const input = startRename();
    fireEvent.change(input, { target: { value: "yanjiu" } });

    fireEvent.keyDown(input, { key: "Escape", ...eventInit });

    expect(updateMutate).not.toHaveBeenCalled();
    expect(input).toBeInTheDocument();
    expect(input).toHaveValue("yanjiu");
  });

  it("still cancels the edit on Escape", () => {
    const input = startRename();
    fireEvent.change(input, { target: { value: "Discard me" } });

    fireEvent.keyDown(input, { key: "Escape" });

    expect(updateMutate).not.toHaveBeenCalled();
    expect(screen.queryByRole("textbox", { name: RENAME_LABEL })).not.toBeInTheDocument();
    expect(screen.getByText("Original title")).toBeInTheDocument();
  });
});

describe("ChatSessionHeader rename shortcut", () => {
  beforeEach(() => {
    updateMutate.mockReset();
    configureShortcutPlatform("macos");
    vi.spyOn(HTMLElement.prototype, "getClientRects").mockReturnValue(
      [new DOMRect(0, 0, 100, 20)] as unknown as DOMRectList,
    );
  });

  afterEach(() => {
    configureShortcutPlatform(null);
    vi.restoreAllMocks();
  });

  function renderWithComposer() {
    render(
      <I18nProvider locale="en" resources={TEST_RESOURCES}>
        <ChatSessionHeader session={session} agent={null} />
        <textarea aria-label="composer" />
      </I18nProvider>,
    );
    return screen.getByRole("textbox", { name: "composer" });
  }

  function pressRename(target: Element) {
    return fireEvent.keyDown(target, { key: "r", code: "KeyR", metaKey: true });
  }

  it("opens the title field with the title selected on Mod+R from the composer", () => {
    const composer = renderWithComposer();
    composer.focus();

    const notCancelled = pressRename(composer);

    const input = screen.getByRole<HTMLInputElement>("textbox", { name: RENAME_LABEL });
    expect(notCancelled).toBe(false);
    expect(input).toHaveFocus();
    expect(input).toHaveValue("Original title");
    expect([input.selectionStart, input.selectionEnd]).toEqual([0, "Original title".length]);
  });

  it("keeps what was typed when pressed again while renaming", () => {
    const composer = renderWithComposer();
    pressRename(composer);
    const input = screen.getByRole("textbox", { name: RENAME_LABEL });
    fireEvent.change(input, { target: { value: "Half typed" } });

    pressRename(input);

    expect(screen.getByRole("textbox", { name: RENAME_LABEL })).toHaveValue("Half typed");
    expect(updateMutate).not.toHaveBeenCalled();
  });

  it("saves with Enter and cancels with Esc as before", () => {
    const composer = renderWithComposer();
    pressRename(composer);
    const input = screen.getByRole("textbox", { name: RENAME_LABEL });
    fireEvent.change(input, { target: { value: "Renamed by keyboard" } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(updateMutate).toHaveBeenCalledWith({ sessionId: "session-1", title: "Renamed by keyboard" });

    pressRename(composer);
    fireEvent.keyDown(screen.getByRole("textbox", { name: RENAME_LABEL }), { key: "Escape" });
    expect(screen.queryByRole("textbox", { name: RENAME_LABEL })).not.toBeInTheDocument();
    expect(updateMutate).toHaveBeenCalledTimes(1);
  });
});

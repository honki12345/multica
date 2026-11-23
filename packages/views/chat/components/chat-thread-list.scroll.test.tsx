import { forwardRef, useImperativeHandle } from "react";
import { render } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "@multica/core/i18n/react";
import type { Agent, ChatSession } from "@multica/core/types";
import enChat from "../../locales/en/chat.json";
import enIssues from "../../locales/en/issues.json";

// jsdom has no layout, so the real Virtuoso cannot show whether a row came
// into view. The mock exposes the handle the list drives; a short list has
// no Virtuoso and scrolls the mounted row itself.
const scrollIntoView = vi.hoisted(() => vi.fn());
const rowScrollIntoView = vi.hoisted(() => vi.fn());
vi.mock("react-virtuoso", () => ({
  Virtuoso: forwardRef(function MockVirtuoso(
    { data, itemContent }: { data: ChatSession[]; itemContent: (index: number, s: ChatSession) => React.ReactNode },
    ref: React.Ref<unknown>,
  ) {
    useImperativeHandle(ref, () => ({ scrollIntoView }));
    return <div>{data.map((s, i) => <div key={s.id}>{itemContent(i, s)}</div>)}</div>;
  }),
}));
vi.mock("../../common/actor-avatar", () => ({ ActorAvatar: () => <span /> }));
vi.mock("@multica/core/hooks", () => ({ useWorkspaceId: () => "ws-1" }));
vi.mock("@multica/core/agents", () => ({ useWorkspacePresenceMap: () => ({ byAgent: new Map() }) }));
vi.mock("@multica/core/api", () => ({ api: { cancelTaskById: vi.fn() } }));
vi.mock("@multica/core/chat", () => ({
  useChatStore: (selector: (s: { setActiveSession: () => void }) => unknown) => selector({ setActiveSession: vi.fn() }),
}));
vi.mock("@multica/core/chat/mutations", () => ({
  useDeleteChatSession: () => ({ mutate: vi.fn() }),
  useSetChatSessionPinned: () => ({ mutate: vi.fn() }),
  useReorderPinnedChatSessions: () => ({ mutateAsync: vi.fn() }),
  useSetChatSessionArchived: () => ({ mutate: vi.fn() }),
  useUpdateChatSession: () => ({ mutate: vi.fn() }),
}));
vi.mock("@tanstack/react-query", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@tanstack/react-query")>()),
  useQuery: ({ queryKey }: { queryKey: readonly unknown[] }) =>
    queryKey.includes("my-wakeups") ? { data: [] } : { data: { tasks: [] } },
  useQueryClient: () => ({ setQueryData: vi.fn(), invalidateQueries: vi.fn() }),
}));

import { ChatThreadList } from "./chat-thread-list";
import { SESSION_LIST_VIRTUALIZE_AFTER } from "./session-history-list";

const agent = { id: "agent-1", name: "Alpha" } as unknown as Agent;
const session = (id: string, i: number): ChatSession => ({
  id,
  workspace_id: "ws-1",
  agent_id: "agent-1",
  creator_id: "user-1",
  title: `Chat ${id}`,
  status: "active",
  has_unread: false,
  unread_count: 0,
  last_message: null,
  pinned: false,
  created_at: new Date(0).toISOString(),
  updated_at: new Date(Date.UTC(2026, 10, 1) - i * 60_000).toISOString(),
});
const shortList = ["a", "b", "c"].map(session);
const longList = Array.from({ length: SESSION_LIST_VIRTUALIZE_AFTER + 1 }, (_, i) => session(`s${i}`, i));

const ui = (active: string | null, sessions = shortList) => (
  <I18nProvider locale="en" resources={{ en: { chat: enChat, issues: enIssues } }}>
    <ChatThreadList sessions={sessions} agents={[agent]} activeSessionId={active} onSelectSession={vi.fn()} onArchive={vi.fn()} />
  </I18nProvider>
);

beforeEach(() => {
  scrollIntoView.mockClear();
  rowScrollIntoView.mockClear();
  Element.prototype.scrollIntoView = rowScrollIntoView;
});

describe("ChatThreadList scroll to the open chat (CALA-328)", () => {
  it("brings a chat opened from elsewhere on the page into view, and leaves the list alone on mount", () => {
    const view = render(ui("s0", longList));
    expect(scrollIntoView).not.toHaveBeenCalled();
    view.rerender(ui("s2", longList));
    expect(scrollIntoView).toHaveBeenCalledWith({ index: 2 });
  });

  it("scrolls the row itself in a short list, which renders without Virtuoso", () => {
    const view = render(ui("a"));
    expect(rowScrollIntoView).not.toHaveBeenCalled();
    view.rerender(ui("c"));
    expect(scrollIntoView).not.toHaveBeenCalled();
    expect(rowScrollIntoView).toHaveBeenCalledTimes(1);
    expect(rowScrollIntoView.mock.contexts[0]).toBe(
      view.getByText("Chat c").closest("[data-chat-thread-row]"),
    );
  });
});

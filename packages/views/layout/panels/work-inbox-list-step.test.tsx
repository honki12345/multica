// Added by honki12345, 2026: the list-step keys on an issue opened from the Work panel's Inbox section (CALA-328).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { agentTaskSnapshotOptions } from "@multica/core/agents";
import { useInboxFilterStore } from "@multica/core/inbox/filter-store";
import { inboxListOptions, snoozedInboxOptions } from "@multica/core/inbox/queries";
import { useInboxSelectionStore } from "@multica/core/inbox/selection-store";
import { configureShortcutPlatform } from "@multica/core/shortcuts";
import type { InboxItem } from "@multica/core/types";
import { renderWithI18n } from "../../test/i18n";
import { NavigationProvider, type NavigationAdapter } from "../../navigation";
import { WorkInboxListStep } from "./work-inbox-list-step";

vi.mock("@multica/core/paths", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@multica/core/paths")>();
  return {
    ...actual,
    useWorkspacePaths: () => actual.paths.workspace("acme"),
    useCurrentWorkspace: () => ({ id: "ws" }),
  };
});

function item(overrides: Partial<InboxItem> & { id: string }): InboxItem {
  return {
    workspace_id: "ws",
    recipient_type: "member",
    recipient_id: "member-1",
    actor_type: "agent",
    actor_id: "agent-1",
    type: "new_comment",
    severity: "info",
    issue_id: null,
    title: "Issue title",
    body: null,
    issue_status: "in_progress",
    issue_priority: "none",
    read: true,
    archived: false,
    created_at: "2026-11-10T08:00:00Z",
    details: null,
    ...overrides,
  };
}

const ROWS = [
  item({ id: "n-1", issue_id: "issue-1", issue_identifier: "MUL-1", created_at: "2026-11-12T08:00:00Z" }),
  item({ id: "n-2", issue_id: "issue-2", issue_identifier: "MUL-2", created_at: "2026-11-11T08:00:00Z", details: { comment_id: "c-9" } }),
  item({ id: "n-3", issue_id: "issue-3", issue_identifier: "MUL-3", created_at: "2026-11-10T08:00:00Z" }),
];

/**
 * The shell with the host mounted and nothing else: no issue page, so no
 * issue header, as while the next issue loads.
 */
function setup(pathname = "/acme/issues/MUL-1") {
  const nav: NavigationAdapter = {
    push: vi.fn(),
    replace: vi.fn(),
    back: vi.fn(),
    pathname,
    searchParams: new URLSearchParams(),
    hash: "",
    getShareableUrl: (path) => path,
  };
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } });
  qc.setQueryData(inboxListOptions("ws").queryKey, ROWS);
  qc.setQueryData(snoozedInboxOptions("ws").queryKey, []);
  qc.setQueryData(agentTaskSnapshotOptions("ws").queryKey, []);
  const shell = () => (
    <QueryClientProvider client={qc}>
      <NavigationProvider value={nav}>
        <WorkInboxListStep />
      </NavigationProvider>
    </QueryClientProvider>
  );
  const { rerender } = renderWithI18n(shell());
  /** The route reaching another address. */
  const go = (next: string) => {
    nav.pathname = next;
    rerender(shell());
  };
  return Object.assign(nav, { go, qc, pushed: () => vi.mocked(nav.push).mock.calls.map(([href]) => href) });
}

function step(target: Element | Document, key: "[" | "]") {
  return fireEvent.keyDown(target, {
    key: key === "[" ? "{" : "}",
    code: key === "[" ? "BracketLeft" : "BracketRight",
    metaKey: true,
    shiftKey: true,
    bubbles: true,
    cancelable: true,
  });
}

beforeEach(() => {
  configureShortcutPlatform("macos");
  useInboxSelectionStore.setState({
    sidebarIssueByWorkspace: { ws: "issue-1" },
    sidebarTabIssuesByWorkspace: {},
    heldRows: {},
    leftRowKeyByWorkspace: {},
    landing: null,
  });
  useInboxFilterStore.getState().clearFilters("ws");
});
afterEach(() => {
  // A press's cursor outlives the page for a second; a click ends it.
  fireEvent.pointerDown(document);
  configureShortcutPlatform(null);
  cleanup();
});

describe("WorkInboxListStep (CALA-328)", () => {
  it("opens the notification below and above, as a row click would, while focus stays in a comment box", () => {
    const nav = setup();
    const comment = document.createElement("textarea");
    document.body.appendChild(comment);
    comment.focus();
    try {
      step(comment, "]");
      expect(nav.pushed()).toEqual(["/acme/issues/MUL-2#comment-c-9"]);
      expect(useInboxSelectionStore.getState().sidebarIssueByWorkspace.ws).toBe("issue-2");
      expect(useInboxSelectionStore.getState().landing).toMatchObject({ issueId: "issue-2", landed: false });
      expect(document.activeElement).toBe(comment);

      nav.go("/acme/issues/MUL-2");
      step(comment, "[");
      expect(nav.pushed()).toEqual(["/acme/issues/MUL-2#comment-c-9", "/acme/issues/MUL-1"]);
    } finally {
      comment.remove();
    }
  });

  it("counts every press of a burst, the route still on the issue before or already on the next one loading", () => {
    const nav = setup();
    step(document.body, "]");
    // The route has not moved yet.
    step(document.body, "]");
    expect(nav.pushed()).toEqual(["/acme/issues/MUL-2#comment-c-9", "/acme/issues/MUL-3"]);
  });

  it("steps on from an issue whose page has not loaded, named by its identifier", () => {
    const nav = setup("/acme/issues/MUL-2");
    useInboxSelectionStore.setState({ sidebarIssueByWorkspace: { ws: "issue-2" } });
    nav.go("/acme/issues/MUL-2");
    step(document.body, "]");
    expect(nav.pushed()).toEqual(["/acme/issues/MUL-3"]);
  });

  it("steps on from a notification archived elsewhere, whose row the section keeps in place", async () => {
    const nav = setup("/acme/issues/MUL-2");
    useInboxSelectionStore.setState({ sidebarIssueByWorkspace: { ws: "issue-2" } });
    nav.go("/acme/issues/MUL-2");
    // The section held the open row while it was listed; then another window archives it.
    await waitFor(() => expect(useInboxSelectionStore.getState().heldRows["ws:section"]?.key).toBe("issue-2"));
    act(() => nav.qc.setQueryData(inboxListOptions("ws").queryKey, [ROWS[0]!, ROWS[2]!]));
    step(document.body, "]");
    step(document.body, "[");
    expect(nav.pushed()).toEqual(["/acme/issues/MUL-3", "/acme/issues/MUL-2#comment-c-9"]);
  });

  it("stops at the last notification and still claims the key", () => {
    useInboxSelectionStore.setState({ sidebarIssueByWorkspace: { ws: "issue-3" } });
    const nav = setup("/acme/issues/issue-3");
    expect(step(document.body, "]")).toBe(false);
    expect(nav.pushed()).toEqual([]);
  });

  it("leaves the keys alone on an issue that was not opened from the Inbox, and off an issue page", () => {
    useInboxSelectionStore.setState({ sidebarIssueByWorkspace: { ws: "issue-2" } });
    const nav = setup("/acme/issues/MUL-1");
    expect(step(document.body, "]")).toBe(true);
    nav.go("/acme/projects");
    expect(step(document.body, "]")).toBe(true);
    expect(nav.pushed()).toEqual([]);
  });

});

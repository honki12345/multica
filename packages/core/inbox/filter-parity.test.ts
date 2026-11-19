// @vitest-environment node
// The CLI's `multica inbox list` reads the same cases
// (server/cmd/multica/inbox_filter_test.go), so a change to the web filter
// semantics that is not mirrored there fails one of the two suites.

import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { InboxItem } from "../types";
import { EMPTY_INBOX_FILTERS, filterInboxItems, inboxTypeGroup, type InboxFilters } from "./filters";

interface ParityIssue {
  status: InboxItem["issue_status"];
  priority: InboxItem["issue_priority"];
  project_id: string | null;
  assignee_type: InboxItem["issue_assignee_type"];
  assignee_id: string | null;
  due_date: string | null;
  label_ids: string[];
}

interface ParityItem {
  id: string;
  type: InboxItem["type"];
  issue_id: string | null;
  actor_type: InboxItem["actor_type"];
  actor_id: string | null;
  read: boolean;
  created_at: string;
  snoozed_until?: string;
  details?: InboxItem["details"];
}

interface ParityFixture {
  now: string;
  type_groups: Record<string, string>;
  issues: Record<string, ParityIssue>;
  items: ParityItem[];
  cases: {
    name: string;
    filters: Partial<InboxFilters>;
    active_issue_ids?: string[];
    expected: string[];
  }[];
}

const fixture = JSON.parse(
  readFileSync(new URL("./testdata/filter-parity.json", import.meta.url), "utf8"),
) as ParityFixture;

// Fixture times carry no offset and mean local wall-clock time, so the
// calendar-day dimensions agree in any time zone the suite runs in.
const iso = (local: string) => new Date(local).toISOString();
const now = new Date(fixture.now);

function toInboxItem(row: ParityItem): InboxItem {
  const issue = row.issue_id ? fixture.issues[row.issue_id] : undefined;
  return {
    id: row.id,
    workspace_id: "ws-1",
    recipient_type: "member",
    recipient_id: "me",
    actor_type: row.actor_type,
    actor_id: row.actor_id,
    type: row.type,
    severity: "info",
    issue_id: row.issue_id,
    title: row.id,
    body: null,
    issue_status: issue?.status ?? null,
    issue_priority: issue?.priority ?? null,
    issue_project_id: issue?.project_id ?? null,
    issue_assignee_type: issue?.assignee_type ?? null,
    issue_assignee_id: issue?.assignee_id ?? null,
    issue_due_date: issue?.due_date ?? null,
    issue_label_ids: issue?.label_ids ?? [],
    read: row.read,
    archived: false,
    created_at: iso(row.created_at),
    snoozed_until: row.snoozed_until ? iso(row.snoozed_until) : undefined,
    details: row.details ?? null,
  };
}

const items = fixture.items.map(toInboxItem);

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(now);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("inbox filter parity fixture", () => {
  it("groups notification types", () => {
    for (const [type, group] of Object.entries(fixture.type_groups)) {
      expect([type, inboxTypeGroup(type)]).toEqual([type, group]);
    }
  });

  it.each(fixture.cases)("$name", ({ filters, active_issue_ids, expected }) => {
    const rows = filterInboxItems(items, { ...EMPTY_INBOX_FILTERS, ...filters }, {
      activeIssueIds: new Set(active_issue_ids ?? []),
      now,
    });
    expect(rows.map((row) => row.id)).toEqual(expected);
  });
});

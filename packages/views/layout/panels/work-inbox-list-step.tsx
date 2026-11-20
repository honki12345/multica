"use client";

// Added by honki12345, 2026: the list-step keys on an issue opened from the Work panel's Inbox section (CALA-328).

import { useMemo } from "react";
import { useCurrentWorkspace, useWorkspacePaths } from "@multica/core/paths";
import { inboxRowKey } from "@multica/core/inbox/open-row";
import { useInboxSelectionStore } from "@multica/core/inbox/selection-store";
import type { InboxItem } from "@multica/core/types";
import { useListStepShortcut } from "../../common/use-list-step-shortcut";
import { inboxRowHref } from "../../inbox/components/inbox-display";
import { useFilteredInboxRows } from "../../inbox/components/use-filtered-inbox-rows";
import { useSidebarInboxIssue } from "../../inbox/components/use-sidebar-inbox-issue";
import { useNavigation } from "../../navigation";

/** The `{id}` of an `/issues/{id}` route: a UUID or an identifier like `MUL-123`. */
function issueSegment(pathname: string, base: string): string | null {
  if (!pathname.startsWith(base + "/")) return null;
  const segment = pathname.slice(base.length + 1).split("/")[0];
  return segment ? decodeURIComponent(segment) : null;
}

const isRowOf = (segment: string) => (row: InboxItem) =>
  row.issue_id === segment || (!!row.issue_identifier && row.issue_identifier === segment);

/**
 * `listPreviousItem` / `listNextItem` on an issue opened from the Work
 * panel's Inbox section: open the row above / below in the section, as a
 * click on it would, without taking this one out of the list.
 *
 * Mounted with the shell, not the issue page: the page shows a skeleton, and
 * no header, while the next issue loads, and a press made then must still
 * step on. The open row is read from the route against the rows themselves,
 * so an identifier route names its row before its issue has loaded.
 */
export function WorkInboxListStep() {
  const p = useWorkspacePaths();
  const { pathname, push } = useNavigation();
  const wsId = useCurrentWorkspace()?.id ?? "";
  const segment = issueSegment(pathname, p.issues());
  // Every live notification, so a filter that hides the open row still finds it.
  const { notifications } = useFilteredInboxRows(wsId, null, !!wsId && !!segment);
  const openIssueId = segment ? (notifications.find(isRowOf(segment))?.issue_id ?? null) : null;
  const { fromInbox } = useSidebarInboxIssue(wsId, openIssueId);
  // The rows exactly as the section and the issue header list them.
  const { rows } = useFilteredInboxRows(wsId, fromInbox ? openIssueId : null, !!wsId && fromInbox);
  const rowKeys = useMemo(() => rows.map(inboxRowKey), [rows]);
  const rememberSidebarIssue = useInboxSelectionStore((s) => s.rememberSidebarIssue);
  const requestLanding = useInboxSelectionStore((s) => s.requestLanding);
  useListStepShortcut({
    scope: "work-inbox",
    enabled: fromInbox && !!openIssueId && rowKeys.includes(openIssueId),
    keys: rowKeys,
    openKey: openIssueId,
    onStep: (at) => {
      const target = rows[at];
      if (!target) return;
      rememberSidebarIssue(wsId, target.issue_id ?? null);
      if (target.issue_id) requestLanding(target.issue_id);
      push(inboxRowHref(p, target));
    },
  });
  return null;
}

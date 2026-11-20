"use client";

// Modified by honki12345, 2026: expose the Virtuoso handle so the list can scroll a row into view (CALA-328).

import type { ReactNode, Ref } from "react";
import { Virtuoso, type Components, type VirtuosoHandle } from "react-virtuoso";
import type { ChatSession } from "@multica/core/types";

type ListContext = { footer?: ReactNode };

// Keep component identities stable, including when there is no archive entry.
// Passing an explicit undefined components prop breaks Virtuoso 4.18 builds.
const COMPONENTS: Components<ChatSession, ListContext> = {
  Footer: ({ context }) => <>{context?.footer}</>,
};

export function SessionHistoryList({
  sessions,
  renderRow,
  footer,
  maxHeight,
  estimatedRowHeight = 56,
  listRef,
}: {
  sessions: ChatSession[];
  renderRow: (session: ChatSession) => ReactNode;
  footer?: ReactNode;
  maxHeight?: number;
  estimatedRowHeight?: number;
  listRef?: Ref<VirtuosoHandle>;
}) {
  return (
    <Virtuoso
      ref={listRef}
      style={{
        height: maxHeight == null
          ? "100%"
          : Math.min(maxHeight, sessions.length * estimatedRowHeight),
      }}
      data={sessions}
      defaultItemHeight={estimatedRowHeight}
      increaseViewportBy={200}
      computeItemKey={(_, session) => session.id}
      itemContent={(_, session) => renderRow(session)}
      components={COMPONENTS}
      context={{ footer }}
    />
  );
}

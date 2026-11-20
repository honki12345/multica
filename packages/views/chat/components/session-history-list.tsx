"use client";

// Modified by honki12345, 2026: open scrolled to a given chat (CALA-327).

import type { ReactNode } from "react";
import { Virtuoso, type Components } from "react-virtuoso";
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
  initialSessionId,
}: {
  sessions: ChatSession[];
  renderRow: (session: ChatSession) => ReactNode;
  footer?: ReactNode;
  maxHeight?: number;
  estimatedRowHeight?: number;
  /** Read at mount: open scrolled so this chat's row is rendered. */
  initialSessionId?: string | null;
}) {
  const initialIndex = initialSessionId
    ? sessions.findIndex((session) => session.id === initialSessionId)
    : -1;
  return (
    <Virtuoso
      {...(initialIndex > 0 ? { initialTopMostItemIndex: initialIndex } : {})}
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

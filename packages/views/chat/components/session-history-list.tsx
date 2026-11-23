"use client";

// Modified by honki12345, 2026: expose the Virtuoso handle so the list can scroll a row into view (CALA-328).
// Modified by honki12345, 2026: open scrolled to a given chat (CALA-327).

import { useState, type ReactNode, type Ref } from "react";
import { AnimatePresence, motion, useIsPresent } from "motion/react";
import { Virtuoso, type Components, type VirtuosoHandle } from "react-virtuoso";
import { useReducedMotion } from "@multica/core/appearance";
import { UI_EASE_OUT, UI_MOTION_DURATION } from "@multica/ui/lib/motion";
import { cn } from "@multica/ui/lib/utils";
import type { ChatSession } from "@multica/core/types";

type ListContext = { footer?: ReactNode };

/**
 * Up to this many rows, `animateExit` renders rows directly inside
 * `AnimatePresence` so archiving/deleting a row collapses its height smoothly
 * instead of snapping the rows below upward. Longer lists switch to
 * `<Virtuoso>` over the same outer scroll container (via `customScrollParent`,
 * like `InboxSection` does past its 50-row boundary) so crossing the threshold
 * never swaps the scroller element or resets scroll position.
 */
export const SESSION_LIST_VIRTUALIZE_AFTER = 60;

// Keep component identities stable, including when there is no archive entry.
// Passing an explicit undefined components prop breaks Virtuoso 4.18 builds.
const COMPONENTS: Components<ChatSession, ListContext> = {
  Footer: ({ context }) => <>{context?.footer}</>,
};

function SessionExitRow({ children }: { children: ReactNode }) {
  const isPresent = useIsPresent();
  const reduceMotion = useReducedMotion();

  return (
    <motion.div
      data-chat-row-exiting={!isPresent ? "" : undefined}
      aria-hidden={!isPresent || undefined}
      initial={false}
      exit={{
        opacity: 0,
        height: 0,
        overflow: "hidden",
        transition: {
          duration: reduceMotion ? 0 : UI_MOTION_DURATION.fast,
          ease: UI_EASE_OUT,
        },
      }}
      className={cn(!isPresent && "pointer-events-none")}
    >
      {children}
    </motion.div>
  );
}

export function SessionHistoryList({
  sessions,
  renderRow,
  footer,
  maxHeight,
  estimatedRowHeight = 56,
  animateExit = false,
  listRef,
  initialSessionId,
}: {
  sessions: ChatSession[];
  renderRow: (session: ChatSession) => ReactNode;
  footer?: ReactNode;
  maxHeight?: number;
  estimatedRowHeight?: number;
  /** Smoothly collapse rows as they leave the list (for small/medium lists). */
  animateExit?: boolean;
  /** The Virtuoso handle; null while `animateExit` renders every row directly. */
  listRef?: Ref<VirtuosoHandle>;
  /** Read at mount: open scrolled so this chat's row is rendered. */
  initialSessionId?: string | null;
}) {
  const initialIndex = initialSessionId
    ? sessions.findIndex((session) => session.id === initialSessionId)
    : -1;
  const initialScroll = initialIndex > 0 ? { initialTopMostItemIndex: initialIndex } : {};
  const [scrollEl, setScrollEl] = useState<HTMLDivElement | null>(null);
  const height =
    maxHeight == null
      ? "100%"
      : Math.min(maxHeight, sessions.length * estimatedRowHeight);

  if (animateExit) {
    const virtualize = sessions.length > SESSION_LIST_VIRTUALIZE_AFTER;
    return (
      <div
        ref={setScrollEl}
        data-chat-session-scroller=""
        className="overflow-y-auto"
        style={{ height }}
      >
        {virtualize ? (
          scrollEl ? (
            <Virtuoso
              ref={listRef}
              {...initialScroll}
              customScrollParent={scrollEl}
              data={sessions}
              defaultItemHeight={estimatedRowHeight}
              increaseViewportBy={200}
              computeItemKey={(_, session) => session.id}
              itemContent={(_, session) => renderRow(session)}
              components={COMPONENTS}
              context={{ footer }}
            />
          ) : null
        ) : (
          <>
            <AnimatePresence initial={false}>
              {sessions.map((session) => (
                <SessionExitRow key={session.id}>
                  {renderRow(session)}
                </SessionExitRow>
              ))}
            </AnimatePresence>
            {footer}
          </>
        )}
      </div>
    );
  }

  return (
    <Virtuoso
      ref={listRef}
      {...initialScroll}
      style={{ height }}
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

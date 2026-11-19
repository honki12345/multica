"use client";

import { useEffect, useRef } from "react";
import {
  getShortcut,
  isPortalLayerShortcutTarget,
  shortcutMatchesEvent,
} from "@multica/core/shortcuts";
import { isImeComposing } from "@multica/core/utils";
import { findPromptTarget, type PromptAnchor, type PromptDirection } from "./prompt-navigation";
import { isAtLiveEnd } from "./stick-to-bottom";

/** Marks a chat list's scroll container as a prompt-navigation target. */
export const PROMPT_NAV_ATTR = "data-chat-prompt-nav";

/** Rows Virtuoso has mounted carry their absolute index here. */
const ROW_INDEX_ATTR = "data-item-index";

/** Tolerance, in px, for "this row's top edge is at or below the viewport top". */
const START_VISIBLE_SLACK = 2;

/**
 * The top-most row on screen. Rows are read from Virtuoso's mounted items, so
 * the overscan above the viewport is skipped by geometry, not by index.
 */
function measureAnchor(scrollEl: HTMLElement, firstIndex: number): PromptAnchor | null {
  const viewportTop = scrollEl.getBoundingClientRect().top;
  let best: { index: number; top: number } | null = null;
  for (const row of scrollEl.querySelectorAll<HTMLElement>(`[${ROW_INDEX_ATTR}]`)) {
    const rect = row.getBoundingClientRect();
    if (rect.bottom <= viewportTop + START_VISIBLE_SLACK) continue;
    const index = Number(row.getAttribute(ROW_INDEX_ATTR)) - firstIndex;
    if (!Number.isInteger(index) || index < 0) continue;
    if (!best || rect.top < best.top) best = { index, top: rect.top };
  }
  if (!best) return null;
  return { index: best.index, startVisible: best.top >= viewportTop - START_VISIBLE_SLACK };
}

const FLOATING_WINDOW = '[data-mc="chat-window"]';

function isShown(el: Element): boolean {
  return el.getClientRects().length > 0;
}

/**
 * Which chat a keypress belongs to: the floating window's while focus is in
 * it, otherwise the page's own chat (the Chat tab, the agent builder), and the
 * floating window's when it is the only chat on screen.
 */
function ownsKeypress(scrollEl: HTMLElement, target: EventTarget | null): boolean {
  if (!isShown(scrollEl)) return false;
  const lists = Array.from(document.querySelectorAll(`[${PROMPT_NAV_ATTR}]`)).filter(isShown);
  const windowList = lists.find((el) => el.closest(FLOATING_WINDOW));
  const pageList = lists.find((el) => !el.closest(FLOATING_WINDOW));
  const focusInWindow = target instanceof Element && target.closest(FLOATING_WINDOW) !== null;
  return (focusInWindow ? windowList : pageList ?? windowList) === scrollEl;
}

/**
 * Previous / next sent message (CALA-281): `chatPreviousPrompt` and
 * `chatNextPrompt` move the reader's own messages to the top of the list,
 * skipping replies; past the last one, "next" goes to the live end.
 */
export function usePromptNavigation({
  scrollEl,
  enabled,
  prompts,
  firstIndex,
  scrollToRow,
  scrollToLiveEnd,
}: {
  scrollEl: HTMLElement | null;
  enabled: boolean;
  /** One entry per row, `true` for a message the reader sent. */
  prompts: readonly boolean[];
  /** Virtuoso's `firstItemIndex`, the offset of row 0's absolute index. */
  firstIndex: number;
  scrollToRow: (index: number) => void;
  scrollToLiveEnd: () => void;
}): void {
  const latest = useRef({ prompts, firstIndex, scrollToRow, scrollToLiveEnd });
  latest.current = { prompts, firstIndex, scrollToRow, scrollToLiveEnd };

  useEffect(() => {
    if (!enabled || !scrollEl) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return;
      let direction: PromptDirection;
      if (shortcutMatchesEvent(getShortcut("chatPreviousPrompt"), event)) direction = "previous";
      else if (shortcutMatchesEvent(getShortcut("chatNextPrompt"), event)) direction = "next";
      else return;
      if (isPortalLayerShortcutTarget(event.target)) return;
      if (!ownsKeypress(scrollEl, event.target)) return;
      event.preventDefault();
      // Held keys repeat the step; the chord stays claimed either way.
      const current = latest.current;
      const target = findPromptTarget({
        prompts: current.prompts,
        anchor: measureAnchor(scrollEl, current.firstIndex),
        atEnd: isAtLiveEnd(scrollEl),
        direction,
      });
      if (!target) return;
      if (target.kind === "end") current.scrollToLiveEnd();
      else current.scrollToRow(target.index);
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [enabled, scrollEl]);
}

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

/**
 * How long, in ms, the last target stays the starting point for the next press
 * (CALA-294). Long enough to cover Virtuoso landing a jump (it gives up at
 * 1.2s), short enough that a later press measures where the reader really is.
 */
const CURSOR_FRESH_MS = 1000;

/**
 * Input that hands the list back to the reader. Any other key counts too (see
 * `onKeyDown`): scroll keys from a focused row, Enter on Jump to latest.
 */
const READER_INPUTS = ["wheel", "touchstart", "pointerdown"] as const;

/** Keys that only build up the chord between repeated presses. */
const MODIFIER_KEYS = new Set(["Meta", "Alt", "Control", "Shift", "OS"]);

/**
 * Frames a landed message is held at the top, about a second. Rows above it
 * that finish rendering late (tables, code, previews) grow and push it down,
 * and Virtuoso only compensates for growth while scrolling up.
 */
const HOLD_FRAMES = 60;

/** How far, in px, the message may drift before it is put back. */
const HOLD_SLACK = 2;

/** Top edge of the row with absolute index `row`, from the list's top, if rendered. */
function rowTop(scrollEl: HTMLElement, row: number): number | null {
  const el = scrollEl.querySelector<HTMLElement>(`[${ROW_INDEX_ATTR}="${row}"]`);
  return el ? el.getBoundingClientRect().top - scrollEl.getBoundingClientRect().top : null;
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
 * `chatNextPrompt` move the reader's own messages and wakeup dividers
 * (CALA-318) to the top of the list, skipping replies; past the last one,
 * "next" goes to the live end.
 *
 * A press right after another steps from the previous press's target rather
 * than from what is on screen (opencode's fresh cursor): Virtuoso paints a jump
 * a frame or more later, so a quick second press would otherwise measure the
 * old position and be lost (CALA-294).
 */
export function usePromptNavigation({
  scrollEl,
  enabled,
  prompts,
  hasOlder,
  firstIndex,
  scrollToRow,
  scrollToLiveEnd,
}: {
  scrollEl: HTMLElement | null;
  enabled: boolean;
  /** One entry per row, `true` for a message the reader sent or a wakeup turn. */
  prompts: readonly boolean[];
  hasOlder: boolean;
  /** Virtuoso's `firstItemIndex`, the offset of row 0's absolute index. */
  firstIndex: number;
  scrollToRow: (index: number) => void;
  scrollToLiveEnd: () => void;
}): void {
  const latest = useRef({ prompts, hasOlder, firstIndex, scrollToRow, scrollToLiveEnd });
  latest.current = { prompts, hasOlder, firstIndex, scrollToRow, scrollToLiveEnd };

  useEffect(() => {
    if (!enabled || !scrollEl) return;
    // Absolute index, so it survives older pages being prepended.
    let cursor: { row: number; at: number } | null = null;
    let holdFrame = 0;
    const stopHold = () => {
      cancelAnimationFrame(holdFrame);
      holdFrame = 0;
    };
    const dropCursor = () => {
      cursor = null;
      stopHold();
    };
    // For a second after the jump, re-aims whenever the list has come to rest
    // without the message at the top: Virtuoso stopped on an estimate, a row
    // above grew, or an older page landed and the message is no longer
    // rendered. Re-aiming while the list still moves would fight Virtuoso's
    // own correction.
    const hold = (row: number) => {
      stopHold();
      let frames = 0;
      let last: { top: number | null; scroll: number } | null = null;
      const tick = () => {
        holdFrame = 0;
        if (!scrollEl.isConnected || ++frames > HOLD_FRAMES) return;
        const now = { top: rowTop(scrollEl, row), scroll: scrollEl.scrollTop };
        const resting =
          last !== null &&
          Math.abs(now.scroll - last.scroll) <= HOLD_SLACK &&
          (now.top === null) === (last.top === null) &&
          (now.top === null || Math.abs(now.top - last.top!) <= HOLD_SLACK);
        if (resting && (now.top === null || Math.abs(now.top) > HOLD_SLACK)) {
          latest.current.scrollToRow(row - latest.current.firstIndex);
          last = null;
        } else {
          last = now;
        }
        holdFrame = requestAnimationFrame(tick);
      };
      holdFrame = requestAnimationFrame(tick);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return;
      let direction: PromptDirection;
      if (shortcutMatchesEvent(getShortcut("chatPreviousPrompt"), event)) direction = "previous";
      else if (shortcutMatchesEvent(getShortcut("chatNextPrompt"), event)) direction = "next";
      else {
        if (!MODIFIER_KEYS.has(event.key)) dropCursor();
        return;
      }
      if (isPortalLayerShortcutTarget(event.target)) return;
      if (!ownsKeypress(scrollEl, event.target)) return;
      event.preventDefault();
      // Held keys repeat the step; the chord stays claimed either way.
      const current = latest.current;
      const now = performance.now();
      const fresh = cursor !== null && now - cursor.at < CURSOR_FRESH_MS ? cursor : null;
      const target = findPromptTarget({
        prompts: current.prompts,
        anchor: fresh
          ? { index: fresh.row - current.firstIndex, startVisible: true }
          : measureAnchor(scrollEl, current.firstIndex),
        atEnd: !fresh && isAtLiveEnd(scrollEl),
        hasOlder: current.hasOlder,
        direction,
      });
      if (!target) return;
      if (target.kind === "end") {
        dropCursor();
        current.scrollToLiveEnd();
        return;
      }
      cursor = { row: current.firstIndex + target.index, at: now };
      current.scrollToRow(target.index);
      hold(cursor.row);
    };
    document.addEventListener("keydown", onKeyDown);
    for (const type of READER_INPUTS) document.addEventListener(type, dropCursor, { capture: true, passive: true });
    return () => {
      stopHold();
      document.removeEventListener("keydown", onKeyDown);
      for (const type of READER_INPUTS) document.removeEventListener(type, dropCursor, { capture: true });
    };
  }, [enabled, scrollEl]);
}

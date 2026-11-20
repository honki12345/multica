"use client";

import { useEffect, useRef } from "react";
import {
  getShortcut,
  isPortalLayerShortcutTarget,
  shortcutMatchesEvent,
} from "@multica/core/shortcuts";
import { useModalStore } from "@multica/core/modals";
import { isImeComposing } from "@multica/core/utils";
import { stepListIndex, type ListStepDirection } from "./list-step";

/**
 * How long, in ms, the last row a press opened stays the starting point for
 * the next press. A press opens its row through a selection or a route
 * change, which can land a frame or a page load later; a quick second press
 * must step on from there, not from the row still on screen (CALA-294).
 */
const CURSOR_FRESH_MS = 1000;

/**
 * The row the last press opened, per list. Module scope, because an issue
 * page remounts its header for every issue, and a press that arrives while
 * the next issue is mounting must still count.
 */
const cursors = new Map<string, { key: string; at: number }>();

const FLOATING_CHAT_WINDOW = '[data-mc="chat-window"]';

/** A click picks a row, or a place for the caret, by hand. */
const dropCursors = () => {
  cursors.clear();
  carriedFocus = null;
};

/**
 * How long, in ms, the next row's composer may take to mount and still take
 * the caret a press carried over from the last row's composer. Opening an
 * issue loads it first, so this covers a slow load.
 */
const FOCUS_CARRY_MS = 5000;

/**
 * Composers, by their `data-mc` name, that remount for the next row and take
 * back a caret a press carried over from the row before.
 */
export const LIST_STEP_FOCUS_COMPOSERS = ["comment-composer"] as const;
export type ListStepFocusComposer = (typeof LIST_STEP_FOCUS_COMPOSERS)[number];

const FOCUS_COMPOSER_SELECTOR = LIST_STEP_FOCUS_COMPOSERS.map((name) => `[data-mc="${name}"]`).join(", ");

/**
 * The composer a burst of presses started from, and the row the last press
 * of the burst opened. A press made while the next row is still loading
 * has nothing focused, so it keeps the burst's composer and moves it on.
 */
let carriedFocus: { composer: ListStepFocusComposer; key: string; at: number } | null = null;

/**
 * Whether `composer`, mounting for the row `key`, takes the caret: the
 * presses that opened that row started from the same composer. Only the row
 * the burst ended on takes it, once.
 */
export function takeListStepFocus(composer: ListStepFocusComposer, key: string): boolean {
  const carried = carriedFocus;
  if (!carried || carried.key !== key) return false;
  carriedFocus = null;
  return carried.composer === composer && performance.now() - carried.at < FOCUS_CARRY_MS;
}

/**
 * `listPreviousItem` / `listNextItem` (CALA-328): open the row above or below
 * the open one in a list, from anywhere on the page, composer and comment
 * boxes included. The caret stays where it was; a comment box the next row
 * mounts anew takes it back through `takeListStepFocus`. Stepping stops at
 * either end. The floating chat window keeps the keys to itself.
 *
 * `keys` are the rows in the order the list shows them, `openKey` the open
 * row's key, and `onStep` opens the row at an index of `keys`. `scope` names
 * the list, so a press on one list never steps on from another list's row.
 */
export function useListStepShortcut({
  scope,
  enabled,
  keys,
  openKey,
  onStep,
}: {
  scope: string;
  enabled: boolean;
  keys: readonly string[];
  openKey: string | null;
  onStep: (index: number) => void;
}): void {
  const latest = useRef({ keys, openKey, onStep });
  latest.current = { keys, openKey, onStep };

  // The open row caught up with the presses: step from it again.
  useEffect(() => {
    if (cursors.get(scope)?.key === openKey) cursors.delete(scope);
  }, [scope, openKey]);

  useEffect(() => {
    if (!enabled) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return;
      let direction: ListStepDirection;
      if (shortcutMatchesEvent(getShortcut("listPreviousItem"), event)) direction = "previous";
      else if (shortcutMatchesEvent(getShortcut("listNextItem"), event)) direction = "next";
      else return;
      if (isPortalLayerShortcutTarget(event.target)) return;
      if (useModalStore.getState().modal) return;
      if (event.target instanceof Element && event.target.closest(FLOATING_CHAT_WINDOW)) return;
      // Claimed at the ends of the list too, so the browser never acts on it.
      event.preventDefault();
      const { keys: rows, openKey: open, onStep: step } = latest.current;
      const now = performance.now();
      const cursor = cursors.get(scope);
      const fresh = cursor && now - cursor.at < CURSOR_FRESH_MS && rows.includes(cursor.key);
      const index = stepListIndex(rows, fresh ? cursor.key : open, direction);
      if (index === null) return;
      const key = rows[index]!;
      cursors.set(scope, { key, at: now });
      const composer =
        event.target instanceof Element
          ? (event.target.closest(FOCUS_COMPOSER_SELECTOR)?.getAttribute("data-mc") as ListStepFocusComposer | null | undefined)
          : null;
      const focusLeft = !(event.target instanceof Element) || event.target === document.body;
      if (composer) carriedFocus = { composer, key, at: now };
      else if (focusLeft && carriedFocus && now - carriedFocus.at < FOCUS_CARRY_MS) carriedFocus = { ...carriedFocus, key, at: now };
      else carriedFocus = null;
      step(index);
    };
    document.addEventListener("keydown", onKeyDown);
    // A click picks a row by hand; the next press steps from that row.
    document.addEventListener("pointerdown", dropCursors, { capture: true, passive: true });
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", dropCursors, { capture: true });
    };
  }, [enabled, scope]);
}

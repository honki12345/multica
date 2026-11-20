"use client";

import { useEffect, useRef } from "react";
import { isEditableShortcutTarget, isPortalLayerShortcutTarget } from "@multica/core/shortcuts";

/** A request still waiting after this long is stale: the reader has moved on. */
const GIVE_UP_MS = 2000;
const RETRY_MS = 50;

/**
 * Hands keyboard focus to a reading pane (a conversation, an issue body) the
 * reader just opened from a list, so ↑/↓/PageUp/PageDown scroll what they are
 * reading instead of the list row that kept focus after the click (CALA-330).
 *
 * `pending` is the request and `onSettled` must end it (set `pending` false),
 * which is what makes a request act once. A caret in a text field keeps focus.
 * A menu or dialog holding focus, such as the history popover the pick came
 * from while it animates closed, is waited out: once focus leaves it, or it is
 * removed, the pane takes focus. After `GIVE_UP_MS` the request is dropped.
 */
export function useTakeKeyboardFocus(
  target: HTMLElement | null,
  pending: boolean,
  onSettled: () => void,
) {
  const onSettledRef = useRef(onSettled);
  onSettledRef.current = onSettled;

  useEffect(() => {
    if (!pending || !target) return;
    const doc = target.ownerDocument;
    let done = false;
    let retry: ReturnType<typeof setTimeout> | undefined;
    const stop = () => {
      doc.removeEventListener("focusin", attempt);
      clearTimeout(retry);
      clearTimeout(giveUp);
    };
    const settle = () => {
      if (done) return;
      done = true;
      stop();
      onSettledRef.current();
    };
    function attempt() {
      if (done) return;
      const current = doc.activeElement;
      if (isPortalLayerShortcutTarget(current)) {
        // A layer removed while focused drops focus to <body> with no focusin.
        clearTimeout(retry);
        retry = setTimeout(attempt, RETRY_MS);
        return;
      }
      // Focusing scrolls every scrollable ancestor to reveal the box (#3929).
      if (!isEditableShortcutTarget(current)) target!.focus({ preventScroll: true });
      settle();
    }
    const giveUp = setTimeout(settle, GIVE_UP_MS);
    doc.addEventListener("focusin", attempt);
    attempt();
    return stop;
  }, [pending, target]);
}

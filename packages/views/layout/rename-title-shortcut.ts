"use client";

import { useEffect, useRef } from "react";
import {
  createShortcutChord,
  getShortcut,
  isPortalLayerShortcutTarget,
  shortcutChordEquals,
  shortcutMatchesEvent,
} from "@multica/core/shortcuts";
import { isImeComposing } from "@multica/core/utils";

/**
 * A title that can be renamed from the keyboard: the element that shows it,
 * and what to do to start renaming it.
 */
interface RenameTarget {
  element: () => HTMLElement | null;
  rename: () => void;
}

const FLOATING_WINDOW = '[data-mc="chat-window"]';

/** The chord the desktop shell relays when it holds reload back. */
const RELAYED_CHORD = createShortcutChord("R", { primary: true });

const targets = new Set<RenameTarget>();

function isShown(el: HTMLElement | null): el is HTMLElement {
  return !!el && el.isConnected && el.getClientRects().length > 0;
}

/**
 * Which title a keypress renames: the floating chat window's while focus is
 * inside it, otherwise one on the page (the chat or issue on screen). With
 * two on screen (an issue peek over an issue page), the one in the nearest
 * container around the focus wins; failing that, the newest mounted, which
 * is the one on top. Hidden panes have no layout, so they drop out.
 */
function pickTarget(focus: EventTarget | null): RenameTarget | null {
  const floating = focus instanceof Element ? focus.closest(FLOATING_WINDOW) : null;
  const shown: { target: RenameTarget; el: HTMLElement }[] = [];
  for (const target of targets) {
    const el = target.element();
    if (!isShown(el)) continue;
    if (floating ? !floating.contains(el) : el.closest(FLOATING_WINDOW)) continue;
    shown.push({ target, el });
  }
  if (shown.length === 0) return null;
  // Walk up from the focus; the first ancestor holding exactly one title
  // decides. <body> holds them all, so a focus outside both falls through.
  for (let up = focus instanceof Node ? focus : null; up && up !== document.body; up = up.parentNode) {
    const inside = shown.filter(({ el }) => up!.contains(el));
    if (inside.length === 1) return inside[0]!.target;
    if (inside.length > 1) break;
  }
  return shown[shown.length - 1]!.target;
}

function onKeyDown(event: KeyboardEvent) {
  if (event.defaultPrevented || isImeComposing(event)) return;
  if (!shortcutMatchesEvent(getShortcut("renameTitle"), event)) return;
  if (isPortalLayerShortcutTarget(event.target)) return;
  const target = pickTarget(event.target);
  // Nothing to rename here: Mod+R keeps its browser meaning (reload).
  if (!target) return;
  event.preventDefault();
  if (event.repeat) return;
  target.rename();
}

/**
 * Rename for a Mod+R the desktop main process held back from the page, so it
 * never reaches the keydown listener. Returns whether a title took it.
 */
export function runRenameTitleShortcut(
  focus: EventTarget | null = typeof document === "undefined" ? null : document.activeElement,
): boolean {
  if (!shortcutChordEquals(getShortcut("renameTitle"), RELAYED_CHORD)) return false;
  if (isPortalLayerShortcutTarget(focus)) return false;
  const target = pickTarget(focus);
  if (!target) return false;
  target.rename();
  return true;
}

/**
 * Makes a title renamable with the `renameTitle` shortcut (CALA-327). `rename`
 * starts renaming and puts the caret in the field with the title selected; it
 * should do nothing when the field is already being edited, so a second press
 * keeps what was typed.
 */
export function useRenameTitleShortcut(
  element: () => HTMLElement | null,
  rename: () => void,
): void {
  const latest = useRef({ element, rename });
  latest.current = { element, rename };

  useEffect(() => {
    const target: RenameTarget = {
      element: () => latest.current.element(),
      rename: () => latest.current.rename(),
    };
    if (targets.size === 0) document.addEventListener("keydown", onKeyDown);
    targets.add(target);
    return () => {
      targets.delete(target);
      if (targets.size === 0) document.removeEventListener("keydown", onKeyDown);
    };
  }, []);
}

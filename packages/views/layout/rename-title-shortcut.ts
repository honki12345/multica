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

/** How many ancestors up from `el` the first one containing `node` is. */
function distanceToCommonAncestor(el: HTMLElement, node: Node): number {
  let depth = 0;
  for (let up: Node | null = el; up; up = up.parentNode, depth++) {
    if (up.contains(node)) return depth;
  }
  return Infinity;
}

/**
 * Which title a keypress renames: the floating chat window's while focus is
 * inside it, otherwise one on the page (the chat or issue on screen). With
 * two on screen (an issue peek over an issue page), the one sharing the
 * nearest container with the focus wins; failing that, the newest mounted,
 * which is the one on top. Hidden panes have no layout, so they drop out.
 */
function pickTarget(focus: EventTarget | null): RenameTarget | null {
  const focusNode = focus instanceof Node ? focus : null;
  const floating = focus instanceof Element ? focus.closest(FLOATING_WINDOW) : null;
  let best: { target: RenameTarget; distance: number } | null = null;
  for (const target of targets) {
    const el = target.element();
    if (!isShown(el)) continue;
    if (floating ? !floating.contains(el) : el.closest(FLOATING_WINDOW)) continue;
    const distance = focusNode ? distanceToCommonAncestor(el, focusNode) : Infinity;
    if (!best || distance <= best.distance) best = { target, distance };
  }
  return best?.target ?? null;
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

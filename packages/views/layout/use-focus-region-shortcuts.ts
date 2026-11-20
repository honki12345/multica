"use client";

import { useEffect } from "react";
import {
  createShortcutChord,
  getShortcut,
  isEditableShortcutTarget,
  isPortalLayerShortcutTarget,
  shortcutMatchesEvent,
  useShortcutStore,
  type ShortcutActionId,
} from "@multica/core/shortcuts";
import { isImeComposing } from "@multica/core/utils";
import {
  FOCUS_ACTIVATE_ATTR,
  FOCUS_FLASH_ATTR,
  findFocusRegions,
  focusRegionTarget,
  focusRowTarget,
  focusRowsOf,
  focusScopeOf,
  nextFocusRegion,
  pickRegionOfKind,
  regionOfElement,
  stepFocusRow,
  type FocusRegion,
  type FocusRegionKind,
  type RowKey,
} from "./focus-regions";

const JUMPS: Partial<Record<ShortcutActionId, FocusRegionKind>> = {
  focusList: "list",
  focusBody: "body",
  focusComposer: "composer",
};
const CYCLES: Partial<Record<ShortcutActionId, 1 | -1>> = {
  focusNextRegion: 1,
  focusPreviousRegion: -1,
};
const REGION_ACTIONS = [...Object.keys(JUMPS), ...Object.keys(CYCLES)] as ShortcutActionId[];
const ROW_KEYS = new Set<string>(["ArrowUp", "ArrowDown", "Home", "End"]);
// Chords the editor binds itself: Tiptap highlights on Mod+Shift+H.
const EDITOR_BOUND = [createShortcutChord("H", { primary: true, shift: true })];
// The Settings recorder takes the next chord as the new binding.
const RECORDER_SELECTOR = '[data-shortcut-recorder][aria-pressed="true"]';
// A list that steps its own selection (the inbox archive list, MUL-5622).
const SELF_STEPPING_SELECTOR = '[data-focus-rows="self"]';
// A keyboard drag in progress (chat list reorder) owns the arrow keys.
const DRAGGING_SELECTOR = "[data-dragging]";
// An open issue peek closes on Esc from its own document listener.
const PEEK_SELECTOR = "[data-issue-peek]";

// Long enough to find the region after a jump, short enough not to linger.
const FLASH_MS = 900;

let flashed: { element: HTMLElement; timer: ReturnType<typeof setTimeout> } | null = null;

function clearFlash() {
  if (!flashed) return;
  clearTimeout(flashed.timer);
  flashed.element.removeAttribute(FOCUS_FLASH_ATTR);
  flashed = null;
}

function flash(element: HTMLElement) {
  clearFlash();
  element.setAttribute(FOCUS_FLASH_ATTR, "");
  flashed = { element, timer: setTimeout(clearFlash, FLASH_MS) };
}

/** Move keyboard focus into `region`. Returns whether anything took focus. */
function enterRegion(region: FocusRegion): boolean {
  const target = focusRegionTarget(region.element);
  if (!target) return false;
  if (target.hasAttribute(FOCUS_ACTIVATE_ATTR)) {
    // A lazy editor shell mounts the real editor on click and focuses it.
    target.click();
  } else {
    // preventScroll: focusing a box scrolls every scrollable ancestor to
    // reveal it, which shoves the shell around on desktop (#3929).
    target.focus({ preventScroll: true });
  }
  flash(region.element);
  return true;
}

function regionsAround(active: Element | null): FocusRegion[] {
  return findFocusRegions(focusScopeOf(active) ?? document);
}

function hasTextSelection(): boolean {
  const selection = document.getSelection();
  return !!selection && !selection.isCollapsed;
}

function moveRow(region: HTMLElement, active: Element | null, key: RowKey): boolean {
  const rows = focusRowsOf(region);
  if (rows.length === 0) return false;
  const current = rows.find((row) => row === active || row.contains(active)) ?? null;
  const next = stepFocusRow(rows, current, key);
  // Claim the key even at the ends: falling through to the native scroll
  // there would move the viewport away from the focused row.
  if (!next) return true;
  const target = focusRowTarget(next);
  target?.focus({ preventScroll: true });
  next.scrollIntoView?.({ block: "nearest" });
  return true;
}

/**
 * Region keys for the dashboard shell: jump to the list, body or composer,
 * cycle through them, Esc back to the composer, and arrow keys that step list
 * rows only while the list has focus. Mounted once next to GlobalShortcuts.
 */
export function useFocusRegionShortcuts() {
  // Subscribe so a binding changed in Settings takes effect at once.
  const overrides = useShortcutStore((state) => state.overrides);

  useEffect(() => {
    // Region chords are read in the capture phase: an editor's own keymap
    // runs on the editor element and would claim a chord it also binds (Tiptap
    // highlights on Mod+Shift+H) before a bubbling listener sees it. Esc and
    // the arrow keys stay in the bubble phase, after every control, menu and
    // editor had its say.
    const onRegionChord = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return;
      if (isPortalLayerShortcutTarget(event.target)) return;
      if (event.target instanceof Element && event.target.closest(RECORDER_SELECTOR)) return;
      const actionId = REGION_ACTIONS.find((id) => shortcutMatchesEvent(getShortcut(id), event));
      if (!actionId) return;
      // An editor's own formatting chord keeps working on selected text; with
      // nothing selected it would only toggle a stored mark, so the region key
      // wins there.
      const editorBound = EDITOR_BOUND.some((chord) => shortcutMatchesEvent(chord, event));
      if (editorBound && isEditableShortcutTarget(event.target) && hasTextSelection()) return;
      const active = document.activeElement;
      const regions = regionsAround(active);
      const current = regionOfElement(active);
      const jump = JUMPS[actionId];
      const step = CYCLES[actionId];
      const target = jump
        ? pickRegionOfKind(regions, jump, current?.kind === jump ? current.element : null)
        : nextFocusRegion(regions, current?.element ?? null, step!);
      // Without a region to go to, leave the key alone instead of swallowing
      // it for nothing.
      if (!target) return;
      event.preventDefault();
      event.stopPropagation();
      if (event.repeat) return;
      enterRegion(target);
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isImeComposing(event)) return;
      if (isPortalLayerShortcutTarget(event.target)) return;
      const hasModifier = event.metaKey || event.ctrlKey || event.altKey || event.shiftKey;
      if (hasModifier || isEditableShortcutTarget(event.target)) return;
      const active = document.activeElement;
      const current = regionOfElement(active);
      if (!current) return;

      if (event.key === "Escape") {
        if (current.kind === "composer") return;
        if (document.querySelector(PEEK_SELECTOR)) return;
        const composer = pickRegionOfKind(regionsAround(active), "composer", null);
        if (!composer) return;
        event.preventDefault();
        enterRegion(composer);
        return;
      }

      if (current.kind === "list" && ROW_KEYS.has(event.key)) {
        if (active?.closest(DRAGGING_SELECTOR)) return;
        const selfStepping = active?.closest(SELF_STEPPING_SELECTOR);
        if (selfStepping && current.element.contains(selfStepping)) return;
        if (moveRow(current.element, active, event.key as RowKey)) event.preventDefault();
      }
    };
    // A click moves focus the user's way; the ring is only for keyboard moves.
    const onPointerDown = () => clearFlash();

    document.addEventListener("keydown", onRegionChord, true);
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown, true);
    return () => {
      document.removeEventListener("keydown", onRegionChord, true);
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown, true);
      clearFlash();
    };
  }, [overrides]);
}

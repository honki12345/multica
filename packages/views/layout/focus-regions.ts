/**
 * Keyboard focus regions: the list, the body being read, and the composer of
 * a list-and-detail page. Components mark their region with
 * `data-focus-region`; the region shortcuts (focus list / body / composer,
 * next / previous region) and Esc move keyboard focus between them, and the
 * arrow keys act only inside the region that has focus.
 *
 * Everything here reads the DOM and decides; nothing listens or focuses. The
 * listener lives in `use-focus-region-shortcuts.ts`.
 */

export type FocusRegionKind = "list" | "body" | "composer";

export interface FocusRegion {
  kind: FocusRegionKind;
  element: HTMLElement;
}

export const FOCUS_REGION_ATTR = "data-focus-region";
/** Where focus lands inside a region: the selected row, the editor area. */
export const REGION_TARGET_ATTR = "data-focus-region-target";
/** A self-contained surface over the page (the floating chat window). */
export const FOCUS_SCOPE_ATTR = "data-focus-scope";
/** A row the arrow keys step through inside a list region. */
export const FOCUS_ROW_ATTR = "data-focus-row";
/** A lazy shell that mounts its editor on click; it is clicked, not focused. */
export const FOCUS_ACTIVATE_ATTR = "data-focus-activate";
/** Present for a moment on a region keyboard focus just moved into. */
export const FOCUS_FLASH_ATTR = "data-focus-flash";

const KINDS = new Set<string>(["list", "body", "composer"]);

const FOCUSABLE_SELECTOR = [
  "a[href]",
  "button:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  "[contenteditable='true']",
  "[tabindex]:not([tabindex='-1'])",
].join(", ");

const HIDDEN_ANCESTOR_SELECTOR = "[inert], [aria-hidden='true'], [hidden]";

export type RenderedProbe = (element: Element) => boolean;

/**
 * Whether a region is on screen and reachable: it has a box and its middle is
 * not covered by another surface.
 */
export function isRegionRendered(element: Element): boolean {
  if (element.getClientRects().length === 0) return false;
  const doc = element.ownerDocument;
  if (typeof doc.elementFromPoint !== "function") return true;
  const box = element.getBoundingClientRect();
  const hit = doc.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
  return hit === null || element.contains(hit) || hit.contains(element);
}

function isElementShown(element: Element): boolean {
  return !element.closest(HIDDEN_ANCESTOR_SELECTOR) && element.getClientRects().length > 0;
}

function scopeElementOf(root: ParentNode): Element | null {
  return root instanceof Element && root.hasAttribute(FOCUS_SCOPE_ATTR) ? root : null;
}

/**
 * The regions under `root`, in document order: not inside an inert or hidden
 * subtree, rendered per `isRendered`, and not inside a nested scope.
 */
export function findFocusRegions(
  root: ParentNode,
  isRendered: RenderedProbe = isRegionRendered,
): FocusRegion[] {
  const scope = scopeElementOf(root);
  const regions: FocusRegion[] = [];
  for (const element of root.querySelectorAll<HTMLElement>(`[${FOCUS_REGION_ATTR}]`)) {
    const kind = element.getAttribute(FOCUS_REGION_ATTR) ?? "";
    if (!KINDS.has(kind)) continue;
    if (element.closest(`[${FOCUS_SCOPE_ATTR}]`) !== scope) continue;
    if (element.closest(HIDDEN_ANCESTOR_SELECTOR)) continue;
    if (!isRendered(element)) continue;
    regions.push({ kind: kind as FocusRegionKind, element });
  }
  return regions;
}

/** The innermost region around `element`, or null outside every region. */
export function regionOfElement(element: Element | null): FocusRegion | null {
  const host = element?.closest<HTMLElement>(`[${FOCUS_REGION_ATTR}]`);
  if (!host) return null;
  const kind = host.getAttribute(FOCUS_REGION_ATTR) ?? "";
  return KINDS.has(kind) ? { kind: kind as FocusRegionKind, element: host } : null;
}

/** The scope (floating chat window) around `element`, or null for the page. */
export function focusScopeOf(element: Element | null): HTMLElement | null {
  return element?.closest<HTMLElement>(`[${FOCUS_SCOPE_ATTR}]`) ?? null;
}

/**
 * The region after (`step` 1) or before (`step` -1) the one holding
 * `current`, wrapping at the ends. From outside every region, going forward
 * enters the first one and going back enters the last.
 */
export function nextFocusRegion(
  regions: readonly FocusRegion[],
  current: HTMLElement | null,
  step: 1 | -1,
): FocusRegion | null {
  const count = regions.length;
  if (count === 0) return null;
  const index = current ? regions.findIndex((region) => region.element === current) : -1;
  if (index < 0) return regions[step === 1 ? 0 : count - 1]!;
  return regions[(index + step + count) % count]!;
}

/**
 * The region of `kind` to jump to. The last one in document order sits
 * closest to the content (a page's own list column after the side panel);
 * pressing the key again from inside one steps to the one before it.
 */
export function pickRegionOfKind(
  regions: readonly FocusRegion[],
  kind: FocusRegionKind,
  current: HTMLElement | null,
): FocusRegion | null {
  const candidates = regions.filter((region) => region.kind === kind);
  const count = candidates.length;
  if (count === 0) return null;
  const index = current ? candidates.findIndex((region) => region.element === current) : -1;
  if (index < 0) return candidates[count - 1]!;
  return candidates[(index - 1 + count) % count]!;
}

function isFocusable(element: Element): element is HTMLElement {
  if (!(element instanceof HTMLElement)) return false;
  if (element.closest("[inert]")) return false;
  if (element.hasAttribute("disabled")) return false;
  return element.matches(FOCUSABLE_SELECTOR) || element.hasAttribute("tabindex");
}

function firstFocusableIn(element: Element): HTMLElement | null {
  if (isFocusable(element)) return element;
  for (const candidate of element.querySelectorAll(FOCUSABLE_SELECTOR)) {
    if (isFocusable(candidate)) return candidate;
  }
  return null;
}

/**
 * Where focus goes in `region`: its marked target (or the first focusable
 * inside it), the region itself when it takes focus (a scroller with
 * tabindex), else its first focusable element.
 */
export function focusRegionTarget(region: HTMLElement): HTMLElement | null {
  const marked = region.querySelector<HTMLElement>(`[${REGION_TARGET_ATTR}]`);
  const fromMark = marked ? firstFocusableIn(marked) : null;
  if (fromMark) return fromMark;
  if (region.hasAttribute("tabindex") && isFocusable(region)) return region;
  return firstFocusableIn(region);
}

/** The element to focus for a list row: the row, or its first control. */
export function focusRowTarget(row: HTMLElement): HTMLElement | null {
  return firstFocusableIn(row);
}

export type RowKey = "ArrowUp" | "ArrowDown" | "Home" | "End";

/**
 * The row the key moves to from `current`. Stops at the ends (returns null
 * when there is no row to move to); from outside a row, Down enters at the
 * top and Up at the bottom.
 */
export function stepFocusRow(
  rows: readonly HTMLElement[],
  current: HTMLElement | null,
  key: RowKey,
): HTMLElement | null {
  const count = rows.length;
  if (count === 0) return null;
  const index = current ? rows.indexOf(current) : -1;
  let next: number;
  if (key === "Home") next = 0;
  else if (key === "End") next = count - 1;
  else if (index < 0) next = key === "ArrowDown" ? 0 : count - 1;
  else next = Math.min(Math.max(index + (key === "ArrowDown" ? 1 : -1), 0), count - 1);
  return next === index ? null : rows[next]!;
}

/** The rows of a list region the arrow keys step through, top to bottom. */
export function focusRowsOf(region: HTMLElement): HTMLElement[] {
  return [...region.querySelectorAll<HTMLElement>(`[${FOCUS_ROW_ATTR}]`)].filter(isElementShown);
}

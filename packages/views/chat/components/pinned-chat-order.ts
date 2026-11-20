/**
 * The pinned chats' order after one is dropped onto another, or null when the
 * drop changes nothing (same slot, dropped outside the pinned group, or either
 * end is not a pinned chat).
 */
export function pinnedOrderAfterDrop(
  pinnedIds: readonly string[],
  activeId: string,
  overId: string | null,
): string[] | null {
  if (overId === null || activeId === overId) return null;
  const from = pinnedIds.indexOf(activeId);
  const to = pinnedIds.indexOf(overId);
  if (from === -1 || to === -1) return null;
  const next = [...pinnedIds];
  next.splice(from, 1);
  next.splice(to, 0, activeId);
  return next;
}

type Box = { top: number; left: number; width: number; height: number };

/**
 * Whether a pointer at `pointer` is over the pinned rows the list shows:
 * inside the box around the mounted pinned rows, clipped to the list's
 * visible area. Rows just scrolled out of view stay mounted, so the clip is
 * what keeps a release above or below the list from landing on them. With no
 * rows or no known visible area the answer is no, so the row goes back.
 */
export function pointerOverPinnedRows(
  pointer: { x: number; y: number },
  rows: readonly Box[],
  viewport: Box | null,
): boolean {
  if (rows.length === 0 || !viewport) return false;
  const top = Math.max(viewport.top, Math.min(...rows.map((r) => r.top)));
  const bottom = Math.min(
    viewport.top + viewport.height,
    Math.max(...rows.map((r) => r.top + r.height)),
  );
  const left = Math.max(viewport.left, Math.min(...rows.map((r) => r.left)));
  const right = Math.min(
    viewport.left + viewport.width,
    Math.max(...rows.map((r) => r.left + r.width)),
  );
  return pointer.y >= top && pointer.y <= bottom && pointer.x >= left && pointer.x <= right;
}

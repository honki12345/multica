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

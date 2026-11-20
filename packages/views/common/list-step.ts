export type ListStepDirection = "previous" | "next";

/**
 * The row one step above or below the open one in a list of row keys, or
 * `null` at either end: stepping stops there rather than wrapping. With no
 * open row in the list, going down enters it at the top and going up at the
 * bottom, as the Inbox arrow keys do.
 */
export function stepListIndex(
  keys: readonly string[],
  openKey: string | null,
  direction: ListStepDirection,
): number | null {
  if (keys.length === 0) return null;
  const current = openKey === null ? -1 : keys.indexOf(openKey);
  if (current === -1) return direction === "next" ? 0 : keys.length - 1;
  const next = current + (direction === "next" ? 1 : -1);
  return next >= 0 && next < keys.length ? next : null;
}

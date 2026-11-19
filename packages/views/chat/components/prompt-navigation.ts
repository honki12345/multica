// Step between the reader's own messages in a chat (CALA-281). Modelled on
// opencode's `findMessageBoundary`, which also skips assistant replies, but
// indexed over the message array: the list is virtualized, so rows outside the
// viewport have no DOM to measure.

/** The top-most row on screen, and whether its top edge is on screen too. */
export interface PromptAnchor {
  index: number;
  startVisible: boolean;
}

export type PromptDirection = "previous" | "next";

export type PromptTarget = { kind: "row"; index: number } | { kind: "end" };

export function findPromptTarget({
  prompts,
  anchor,
  atEnd,
  direction,
}: {
  /** One entry per list row; `true` for a message the reader sent. */
  prompts: readonly boolean[];
  anchor: PromptAnchor | null;
  /** The list already shows its live end and cannot scroll further down. */
  atEnd: boolean;
  direction: PromptDirection;
}): PromptTarget | null {
  if (direction === "previous") {
    // A sent message cut off at the top counts as "not reached yet": the first
    // press brings back its start, the next press moves past it.
    const from = anchor ? (anchor.startVisible ? anchor.index - 1 : anchor.index) : prompts.length - 1;
    for (let i = Math.min(from, prompts.length - 1); i >= 0; i--) {
      if (prompts[i]) return { kind: "row", index: i };
    }
    return null;
  }
  if (atEnd) return null;
  for (let i = (anchor?.index ?? prompts.length - 1) + 1; i < prompts.length; i++) {
    if (prompts[i]) return { kind: "row", index: i };
  }
  return { kind: "end" };
}

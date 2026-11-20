import type { ChatSession } from "../types/chat";
import { sortChatSessions } from "./queries";

/**
 * The sessions with `orderedIds` restamped the way the server stores a pinned
 * order: the first id at `now`, each next one a millisecond earlier, so the
 * pinned_at-descending sort lists them in that order. Returns the re-sorted
 * list; other rows keep their identity.
 */
export function applyPinnedOrder(
  sessions: readonly ChatSession[],
  orderedIds: readonly string[],
  now: number,
): ChatSession[] {
  const stamp = new Map(orderedIds.map((id, i) => [id, new Date(now - i).toISOString()]));
  return sortChatSessions(
    sessions.map((s) => {
      const pinnedAt = stamp.get(s.id);
      return pinnedAt ? { ...s, pinned_at: pinnedAt } : s;
    }),
  );
}

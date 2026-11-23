// Modified by honki12345, 2026: no cap on chat chips (CALA-72); follow the dragged chip order (CALA-300); fit chips by their measured width (CALA-350).

import type { ChatSession } from "@multica/core/types";

export interface ChatBarSession {
  session: ChatSession;
  running: boolean;
  unread: boolean;
  /** The chat window is open on this session. */
  open: boolean;
}

export interface ChatBarSessions {
  visible: ChatBarSession[];
  overflow: ChatBarSession[];
}

/** When a chat last moved; what a closed chip is compared against. */
export function chatActivity(session: ChatSession): string {
  return session.last_message?.created_at ?? session.updated_at;
}

/**
 * Which chats the bottom bar shows. A chat gets a chip when it needs watching
 * (a task is running, or a reply is unread) or was opened in the quick-chat
 * window, and keeps it until the chip is closed. A closed chip comes back
 * when its chat moves again, or is opened again.
 *
 * Chips follow `order`, the order they were dragged into. A chip missing
 * from it (a new chat, or one closed and back) goes first, newest first.
 * Creation time rather than activity breaks that tie, so a chip keeps its
 * place for the chat's whole life: ordering by activity would swap two
 * running chats on every message. The open chat is always among the visible
 * chips, because the window opens above its chip.
 *
 * With no `maxVisible`, every chip is visible; the bar measures how many fit
 * (`chipsThatFit`) and folds the rest with `foldChatBarSessions`.
 */
export function selectChatBarSessions({
  sessions,
  runningSessionIds,
  openSessionId,
  kept,
  dismissed,
  order,
  maxVisible,
}: {
  sessions: ChatSession[];
  runningSessionIds: ReadonlySet<string>;
  /** The session the open window shows; null while the window is closed. */
  openSessionId: string | null;
  /** Chats opened in the quick-chat window. */
  kept: readonly string[];
  /** Closed chips: sessionId to the chat's activity when it was closed. */
  dismissed: Readonly<Record<string, string>>;
  /** Chip order the user dragged into, left to right. */
  order: readonly string[];
  maxVisible?: number;
}): ChatBarSessions {
  const position = new Map(order.map((id, index) => [id, index]));
  const items = sessions
    .filter((session) => session.status !== "archived")
    .map((session) => ({
      session,
      running: runningSessionIds.has(session.id),
      unread: session.has_unread,
      open: session.id === openSessionId,
    }))
    .filter(
      (item) =>
        item.open ||
        ((item.running || item.unread || kept.includes(item.session.id)) &&
          dismissed[item.session.id] !== chatActivity(item.session)),
    )
    .sort((a, b) => {
      const pa = position.get(a.session.id) ?? -1;
      const pb = position.get(b.session.id) ?? -1;
      if (pa !== pb) return pa - pb;
      return new Date(b.session.created_at).getTime() - new Date(a.session.created_at).getTime();
    });

  return foldChatBarSessions(items, maxVisible ?? items.length);
}

/**
 * Splits ordered chips into the `limit` shown and the rest, which go into the
 * "+N" menu. There is always room for one, and the open chat's chip is brought
 * to the front when it would be folded away.
 */
export function foldChatBarSessions(items: readonly ChatBarSession[], limit: number): ChatBarSessions {
  const shown = Math.max(1, limit);
  const openIndex = items.findIndex((item) => item.open);
  const ordered =
    openIndex >= shown ? [items[openIndex]!, ...items.filter((_, index) => index !== openIndex)] : [...items];
  return { visible: ordered.slice(0, shown), overflow: ordered.slice(shown) };
}

/**
 * How many of the ordered chips fit in `room` px, from their measured widths.
 * When some do not fit, the "+N" button (`more` px) has to fit beside the
 * rest. Counts the chips `foldChatBarSessions` would show, so an open chat's
 * chip brought forward takes its own width. Never less than one.
 */
export function chipsThatFit({
  items,
  widthOf,
  room,
  gap,
  more,
}: {
  items: readonly ChatBarSession[];
  widthOf: (sessionId: string) => number;
  room: number;
  /** Space between two chips, and between the last chip and "+N". */
  gap: number;
  more: number;
}): number {
  for (let count = items.length; count > 1; count--) {
    const { visible, overflow } = foldChatBarSessions(items, count);
    const chips = visible.reduce((sum, item) => sum + widthOf(item.session.id), 0);
    const width = chips + gap * (count - 1) + (overflow.length > 0 ? gap + more : 0);
    if (width <= room) return count;
  }
  return 1;
}

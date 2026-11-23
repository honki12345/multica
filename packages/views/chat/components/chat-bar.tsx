"use client";

// Modified by honki12345, 2026: no cap on chat chips, as many as fit by their measured width before +N (CALA-72, CALA-350); drag chips to reorder them (CALA-300).

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import {
  DndContext,
  KeyboardCode,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
  type DragEndEvent,
  type KeyboardSensorOptions,
} from "@dnd-kit/core";
import { restrictToHorizontalAxis, restrictToParentElement } from "@dnd-kit/modifiers";
import {
  SortableContext,
  arrayMove,
  horizontalListSortingStrategy,
  sortableKeyboardCoordinates,
  useSortable,
} from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { useQuery } from "@tanstack/react-query";
import { Loader2, X } from "@multica/ui/icons";
import { useChatStore } from "@multica/core/chat";
import { chatSessionsOptions, pendingChatTasksOptions } from "@multica/core/chat/queries";
import { useWorkspaceId } from "@multica/core/hooks";
import type { ChatSession } from "@multica/core/types";
import { TooltipHint } from "@multica/ui/components/common/tooltip-hint";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@multica/ui/components/ui/dropdown-menu";
import { STAR_STROKE, starPath } from "@multica/ui/lib/multica-brand";
import { cn } from "@multica/ui/lib/utils";
import { ActionShortcutKeycaps } from "../../common/shortcut-keycaps";
import { useT } from "../../i18n";
import { BOTTOM_BAR_ITEM_CLASS } from "../../layout/bottom-bar-styles";
import { useDragClickGuard } from "../../layout/use-drag-click-guard";
import { ChatBarHistory } from "./chat-bar-history";
import {
  chatActivity,
  chipsThatFit,
  foldChatBarSessions,
  selectChatBarSessions,
  type ChatBarSession,
} from "./chat-bar-sessions";

const EMPTY_SESSIONS: ChatSession[] = [];
const STAR = starPath(STAR_STROKE);
const DRAG_MODIFIERS = [restrictToHorizontalAxis, restrictToParentElement];
/** `gap-0.5`, between two chips and between the last chip and "+N". */
const CHIP_GAP = 2;
const CHIP_CLASS = cn(BOTTOM_BAR_ITEM_CLASS, "gap-1 pl-1.5");
const MORE_CLASS = cn(BOTTOM_BAR_ITEM_CLASS, "px-1.5 tabular-nums");
/** Stop waiting for the key that ended a drag to come up, e.g. after a blur. */
const KEY_RELEASE_TIMEOUT_MS = 1000;
// Space picks a chip up and puts it down. Enter is left to the button, so it
// still opens the chat.
const DRAG_KEYS = {
  start: [KeyboardCode.Space],
  cancel: [KeyboardCode.Esc],
  end: [KeyboardCode.Space, KeyboardCode.Enter, KeyboardCode.Tab],
};
const KEYBOARD_DRAG: KeyboardSensorOptions = {
  coordinateGetter: sortableKeyboardCoordinates,
  keyboardCodes: DRAG_KEYS,
};
const DRAG_SETTLE_KEYS: string[] = [...DRAG_KEYS.end, ...DRAG_KEYS.cancel];

/** The star from the Multica mark, in the text colour. */
function MulticaStar() {
  return (
    <svg aria-hidden viewBox="0 0 100 100" fill="currentColor">
      <path d={STAR} />
    </svg>
  );
}

/**
 * A chat's state, in a slot of one size whatever the state: a chip must not
 * change width when its chat finishes or is read, or it would move the chips
 * beside it and the window above it.
 */
function SessionMark({ item }: { item: ChatBarSession }) {
  return (
    <span aria-hidden className="flex size-3.5 shrink-0 items-center justify-center">
      {item.running ? (
        <Loader2 className="animate-spin" />
      ) : (
        <span
          className={cn("size-1.5 rounded-full", item.unread ? "bg-brand" : "bg-faint-foreground")}
        />
      )}
    </span>
  );
}

/** What a chip shows: its chat's state and title. */
function ChipFace({ item, title }: { item: ChatBarSession; title: string }) {
  return (
    <>
      <SessionMark item={item} />
      {/* The close button sits over the end of the title rather than
          beside it, so showing it never changes the chip's width. */}
      <span className="max-w-32 truncate group-focus-within/chip:[mask-image:linear-gradient(to_right,black_calc(100%-26px),transparent_calc(100%-14px))] group-hover/chip:[mask-image:linear-gradient(to_right,black_calc(100%-26px),transparent_calc(100%-14px))]">
        {title}
      </span>
    </>
  );
}

/**
 * A chat's chip. It is dragged by the chip itself, once the pointer has moved
 * a few pixels, so a plain click still opens the chat; the close button does
 * not start a drag.
 */
function SortableChip({
  item,
  title,
  state,
  closeLabel,
  onToggle,
  onClose,
}: {
  item: ChatBarSession;
  title: string;
  state: string | null;
  closeLabel: string;
  onToggle: () => void;
  onClose: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: item.session.id,
  });
  return (
    <span
      ref={setNodeRef}
      data-chat-chip={item.session.id}
      style={{ transform: CSS.Translate.toString(transform), transition }}
      className={cn("group/chip relative flex shrink-0 rounded-md", isDragging && "z-10 bg-app-shell")}
    >
      <TooltipHint label={state ? `${title} · ${state}` : title}>
        <button
          type="button"
          {...attributes}
          {...listeners}
          data-chat-anchor={item.session.id}
          aria-pressed={item.open}
          aria-label={state ? `${title}, ${state}` : title}
          // useDragClickGuard cancels the click that ends a drag, but a key's
          // click still reaches React, so honour the cancel here.
          onClick={(event) => {
            if (!event.defaultPrevented) onToggle();
          }}
          className={cn(CHIP_CLASS, isDragging && "cursor-grabbing")}
        >
          <ChipFace item={item} title={title} />
        </button>
      </TooltipHint>
      <button
        type="button"
        aria-label={closeLabel}
        onClick={onClose}
        className="absolute top-1 right-1 flex size-4 cursor-pointer items-center justify-center rounded-sm text-muted-foreground opacity-0 outline-none transition-opacity hover:bg-surface-hover hover:text-foreground focus-visible:opacity-100 focus-visible:outline-2 focus-visible:outline-ring group-hover/chip:opacity-100 [&_svg]:size-3"
      >
        <X aria-hidden />
      </button>
    </span>
  );
}

/**
 * Quick chat in the bottom bar: a chip per chat that needs watching or was
 * opened here, then Ask Multica, which starts a new chat, and the history.
 * As many chips as fit are shown, measured by their own width; the rest fold
 * into a "+N" menu. Chips can be dragged into any order, which is remembered
 * per workspace.
 * The chat window opens above whichever control is pressed:
 * `useChatWindowAnchor` finds it by `data-chat-anchor`, and re-places the
 * window on a click that carries that attribute or `data-chat-anchor-trigger`.
 */
export function ChatBar() {
  const { t } = useT("chat");
  const wsId = useWorkspaceId();
  const isOpen = useChatStore((s) => s.isOpen);
  const activeSessionId = useChatStore((s) => s.activeSessionId);
  const selectedAgentId = useChatStore((s) => s.selectedAgentId);
  const kept = useChatStore((s) => s.chatBarKept);
  const dismissed = useChatStore((s) => s.chatBarDismissed);
  const order = useChatStore((s) => s.chatBarOrder);
  const setOpen = useChatStore((s) => s.setOpen);
  const setActiveSession = useChatStore((s) => s.setActiveSession);
  const setSelectedAgentId = useChatStore((s) => s.setSelectedAgentId);
  const startNewChat = useChatStore((s) => s.startNewChat);
  const keepChatInBar = useChatStore((s) => s.keepChatInBar);
  const dismissChatFromBar = useChatStore((s) => s.dismissChatFromBar);
  const setChatBarOrder = useChatStore((s) => s.setChatBarOrder);
  const roomRef = useRef<HTMLDivElement>(null);
  const measureRef = useRef<HTMLDivElement>(null);
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
    useSensor(KeyboardSensor, KEYBOARD_DRAG),
  );
  const { arm: armClickGuard, release: releaseClickGuard } = useDragClickGuard();

  const { data: sessions = EMPTY_SESSIONS } = useQuery(chatSessionsOptions(wsId));
  // Per-chat running state needs the task list, not the boolean the launcher
  // reads. It is refetched on task lifecycle events only, never per message.
  const { data: pending } = useQuery(pendingChatTasksOptions(wsId));
  const runningSessionIds = useMemo(
    () => new Set((pending?.tasks ?? []).map((task) => task.chat_session_id)),
    [pending],
  );

  // Whatever the window shows gets a chip: a chat opened from the shortcut or
  // the window's own history, or one that just got its first message.
  const openSessionId = isOpen ? activeSessionId : null;
  useEffect(() => {
    if (openSessionId) keepChatInBar(openSessionId);
  }, [openSessionId, keepChatInBar]);

  // Every chip, in order: with no limit, all of them come back as visible.
  const chips = useMemo(
    () => selectChatBarSessions({ sessions, runningSessionIds, openSessionId, kept, dismissed, order }).visible,
    [sessions, runningSessionIds, openSessionId, kept, dismissed, order],
  );
  // How many chips fit; null until the bar is laid out, when all are shown.
  const [fit, setFit] = useState<number | null>(null);
  const { visible, overflow } = useMemo(
    () => foldChatBarSessions(chips, fit ?? chips.length),
    [chips, fit],
  );
  const chipIdList = useMemo(() => visible.map((item) => item.session.id), [visible]);

  // Each chip is measured in a hidden row that holds all of them, so a folded
  // chip's width is known before it is given room.
  const chipsRef = useRef(chips);
  chipsRef.current = chips;
  const measureFit = useCallback(() => {
    const room = roomRef.current?.getBoundingClientRect().width ?? 0;
    const row = measureRef.current;
    if (!row || room <= 0) return setFit(null);
    const widths = new Map<string, number>();
    let more = 0;
    for (const el of Array.from(row.children) as HTMLElement[]) {
      const { width } = el.getBoundingClientRect();
      if (el.dataset.measureChip) widths.set(el.dataset.measureChip, width);
      else more = width;
    }
    setFit(chipsThatFit({ items: chipsRef.current, widthOf: (id) => widths.get(id) ?? 0, room, gap: CHIP_GAP, more }));
  }, []);
  useLayoutEffect(measureFit, [chips, measureFit]);
  useEffect(() => {
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measureFit);
    if (roomRef.current) observer.observe(roomRef.current);
    // A title's font can load after the first measure.
    if (measureRef.current) observer.observe(measureRef.current);
    return () => observer.disconnect();
  }, [measureFit]);

  // Space clicks the chip when it comes up, which can be well after the
  // keydown that ended a keyboard drag; hold the guard until then.
  const pendingRelease = useRef<(() => void) | null>(null);
  const settleDrag = useCallback(
    (event: { activatorEvent: Event | null }) => {
      if (!(event.activatorEvent instanceof KeyboardEvent)) {
        releaseClickGuard();
        return;
      }
      const release = () => {
        clearTimeout(fallback);
        window.removeEventListener("keyup", onKeyUp, true);
        pendingRelease.current = null;
        releaseClickGuard();
      };
      // Only the keys that end or cancel a drag; an arrow still held when the
      // chip is dropped must not let Space's click through.
      const onKeyUp = (keyEvent: KeyboardEvent) => {
        if (DRAG_SETTLE_KEYS.includes(keyEvent.code)) release();
      };
      const fallback = setTimeout(release, KEY_RELEASE_TIMEOUT_MS);
      window.addEventListener("keyup", onKeyUp, true);
      pendingRelease.current = release;
    },
    [releaseClickGuard],
  );
  // A drag picked up again before the last one settled must not have the
  // guard dropped under it by that one's timer.
  const startDrag = useCallback(() => {
    pendingRelease.current?.();
    armClickGuard();
  }, [armClickGuard]);
  const onDragEnd = useCallback(
    (event: DragEndEvent) => {
      settleDrag(event);
      const { active, over } = event;
      if (!over || active.id === over.id) return;
      const from = chipIdList.indexOf(String(active.id));
      const to = chipIdList.indexOf(String(over.id));
      if (from === -1 || to === -1) return;
      // Only shown chips are dragged; the folded ones keep their order after them.
      setChatBarOrder([...arrayMove(chipIdList, from, to), ...overflow.map((item) => item.session.id)]);
    },
    [chipIdList, overflow, setChatBarOrder, settleDrag],
  );
  const openOnChip = visible.some((item) => item.open);
  const askPressed = isOpen && !openOnChip;

  const openSession = (session: ChatSession) => {
    // A chat is bound to its agent, so opening it selects that agent too.
    if (session.agent_id !== selectedAgentId) setSelectedAgentId(session.agent_id);
    // Kept here, not left to the effect, so the chip is there to anchor the
    // window by the time the click is measured.
    keepChatInBar(session.id);
    setActiveSession(session.id);
    setOpen(true);
  };

  const toggleSession = (session: ChatSession) => {
    if (isOpen && activeSessionId === session.id) setOpen(false);
    else openSession(session);
  };

  const closeChip = (item: ChatBarSession) => {
    if (item.open) setOpen(false);
    dismissChatFromBar(item.session.id, chatActivity(item.session));
  };

  const askMultica = () => {
    if (askPressed) setOpen(false);
    else startNewChat();
  };

  const titleOf = (session: ChatSession) => session.title || t(($) => $.window.untitled);
  const stateOf = (item: ChatBarSession) =>
    item.running ? t(($) => $.window.running) : item.unread ? t(($) => $.window.unread) : null;

  const askLabel = t(($) => $.fab.default);

  return (
    <div data-slot="chat-bar" className="relative flex min-w-0 flex-1 items-center justify-end gap-0.5">
      {/* The room the chips get: whatever the bar's other content leaves. */}
      <div ref={roomRef} data-slot="chat-bar-room" className="flex min-w-0 flex-1 items-center justify-end gap-0.5">
        {visible.length > 0 && (
          <div data-slot="chat-bar-chips" className="flex shrink-0 items-center gap-0.5">
            <DndContext
              sensors={sensors}
              collisionDetection={closestCenter}
              modifiers={DRAG_MODIFIERS}
              autoScroll={false}
              onDragStart={startDrag}
              onDragEnd={onDragEnd}
              onDragCancel={settleDrag}
            >
              <SortableContext items={chipIdList} strategy={horizontalListSortingStrategy}>
                {visible.map((item) => {
                  const title = titleOf(item.session);
                  return (
                    <SortableChip
                      key={item.session.id}
                      item={item}
                      title={title}
                      state={stateOf(item)}
                      closeLabel={t(($) => $.bar.close_chip, { title })}
                      onToggle={() => toggleSession(item.session)}
                      onClose={() => closeChip(item)}
                    />
                  );
                })}
              </SortableContext>
            </DndContext>
          </div>
        )}
        {overflow.length > 0 && (
          <DropdownMenu>
            <DropdownMenuTrigger aria-label={t(($) => $.bar.more, { count: overflow.length })} className={MORE_CLASS}>
              +{overflow.length}
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" side="top" sideOffset={8} className="max-w-72 min-w-48">
              {overflow.map((item) => (
                <DropdownMenuItem
                  key={item.session.id}
                  data-chat-anchor-trigger
                  onClick={() => openSession(item.session)}
                >
                  <span className="flex shrink-0 [&_svg]:size-3.5">
                    <SessionMark item={item} />
                  </span>
                  <span className="min-w-0 truncate">{titleOf(item.session)}</span>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>
      {/* Every chip at its own width, and the widest "+N", out of sight. */}
      <div aria-hidden inert className="pointer-events-none invisible absolute top-0 left-0 size-0 overflow-hidden">
        <div ref={measureRef} data-slot="chat-bar-measure" className="flex w-max">
          {chips.map((item) => (
            <span key={item.session.id} data-measure-chip={item.session.id} className={CHIP_CLASS}>
              <ChipFace item={item} title={titleOf(item.session)} />
            </span>
          ))}
          <span className={MORE_CLASS}>+{chips.length}</span>
        </div>
      </div>
      {chips.length > 0 && (
        <span aria-hidden className="mx-1.5 h-3.5 w-px shrink-0 bg-surface-border" />
      )}
      <TooltipHint
        label={t(($) => $.window.new_chat_tooltip)}
        shortcut={<ActionShortcutKeycaps action="newChat" />}
      >
        <button
          type="button"
          data-chat-anchor="new"
          aria-pressed={askPressed}
          onClick={askMultica}
          className={BOTTOM_BAR_ITEM_CLASS}
        >
          <MulticaStar />
          {askLabel}
        </button>
      </TooltipHint>
      <ChatBarHistory sessions={sessions} runningSessionIds={runningSessionIds} onSelect={openSession} />
    </div>
  );
}

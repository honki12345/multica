import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { useRef } from "react";
import {
  configureShortcutPlatform,
  createShortcutChord,
  useShortcutStore,
} from "@multica/core/shortcuts";
import { runRenameTitleShortcut, useRenameTitleShortcut } from "./rename-title-shortcut";

function Target({ name, onRename }: { name: string; onRename: () => void }) {
  const ref = useRef<HTMLButtonElement>(null);
  useRenameTitleShortcut(() => ref.current, onRename);
  return <button ref={ref}>{name}</button>;
}

function pressRename(target: Element | Document, extra: Partial<KeyboardEventInit> = {}) {
  return fireEvent.keyDown(target, { key: "r", code: "KeyR", metaKey: true, ...extra });
}

beforeEach(() => {
  configureShortcutPlatform("macos");
  // jsdom lays nothing out; treat every element as on screen unless hidden.
  vi.spyOn(HTMLElement.prototype, "getClientRects").mockImplementation(function (this: HTMLElement) {
    return (this.closest("[hidden]") ? [] : [new DOMRect(0, 0, 100, 20)]) as unknown as DOMRectList;
  });
});

afterEach(() => {
  configureShortcutPlatform(null);
  act(() => useShortcutStore.getState().resetAll());
  vi.restoreAllMocks();
});

describe("rename title shortcut", () => {
  it("renames the page title on Mod+R, even from a text field, and keeps the browser from reloading", () => {
    const onRename = vi.fn();
    render(
      <>
        <Target name="chat title" onRename={onRename} />
        <textarea aria-label="composer" />
      </>,
    );

    const composer = screen.getByLabelText("composer");
    composer.focus();
    const notCancelled = pressRename(composer);

    expect(onRename).toHaveBeenCalledTimes(1);
    expect(notCancelled).toBe(false);
  });

  it("leaves Mod+R to the browser where nothing can be renamed", () => {
    render(<textarea aria-label="composer" />);

    expect(pressRename(screen.getByLabelText("composer"))).toBe(true);
  });

  it("skips a title that is not on screen", () => {
    const onRename = vi.fn();
    render(
      <div hidden>
        <Target name="hidden tab title" onRename={onRename} />
      </div>,
    );

    expect(pressRename(document.body)).toBe(true);
    expect(onRename).not.toHaveBeenCalled();
  });

  it("renames the floating chat while focus is in it, and the page title otherwise", () => {
    const page = vi.fn();
    const floating = vi.fn();
    render(
      <>
        <Target name="issue title" onRename={page} />
        <div data-mc="chat-window">
          <Target name="floating chat" onRename={floating} />
          <textarea aria-label="floating composer" />
        </div>
      </>,
    );

    pressRename(screen.getByLabelText("floating composer"));
    expect(floating).toHaveBeenCalledTimes(1);
    expect(page).not.toHaveBeenCalled();

    pressRename(document.body);
    expect(page).toHaveBeenCalledTimes(1);
    expect(floating).toHaveBeenCalledTimes(1);
  });

  it("renames the title next to the focus when two are on screen, the newest otherwise", () => {
    const page = vi.fn();
    const peek = vi.fn();
    render(
      <>
        <section>
          <Target name="page issue" onRename={page} />
          <textarea aria-label="page comment" />
        </section>
        <section>
          <Target name="peek issue" onRename={peek} />
          <textarea aria-label="peek comment" />
        </section>
      </>,
    );

    pressRename(screen.getByLabelText("peek comment"));
    expect(peek).toHaveBeenCalledTimes(1);
    expect(page).not.toHaveBeenCalled();

    pressRename(screen.getByLabelText("page comment"));
    expect(page).toHaveBeenCalledTimes(1);

    pressRename(document.body);
    expect(peek).toHaveBeenCalledTimes(2);
  });

  it("prefers the newest title over a deeper-nested page title when focus is outside both", () => {
    const page = vi.fn();
    const peek = vi.fn();
    render(
      <>
        <section>
          <div>
            <div>
              <Target name="page issue" onRename={page} />
            </div>
          </div>
          <aside>
            <button>page sidebar</button>
          </aside>
        </section>
        <section>
          <Target name="peek issue" onRename={peek} />
        </section>
      </>,
    );

    pressRename(document.body);
    expect(peek).toHaveBeenCalledTimes(1);
    expect(page).not.toHaveBeenCalled();

    pressRename(screen.getByText("page sidebar"));
    expect(page).toHaveBeenCalledTimes(1);
  });

  it("does not hand an unfocused floating chat the keypress on a page without a title", () => {
    const floating = vi.fn();
    render(
      <div data-mc="chat-window">
        <Target name="floating chat" onRename={floating} />
      </div>,
    );

    expect(pressRename(document.body)).toBe(true);
    expect(floating).not.toHaveBeenCalled();
  });

  it("holds a repeated keypress without renaming again", () => {
    const onRename = vi.fn();
    render(<Target name="chat title" onRename={onRename} />);

    pressRename(document.body);
    const notCancelled = pressRename(document.body, { repeat: true });

    expect(onRename).toHaveBeenCalledTimes(1);
    expect(notCancelled).toBe(false);
  });

  it("ignores Korean IME composition and open menus", () => {
    const onRename = vi.fn();
    render(
      <>
        <Target name="chat title" onRename={onRename} />
        <div role="menu">
          <button>menu item</button>
        </div>
      </>,
    );

    pressRename(document.body, { isComposing: true });
    pressRename(screen.getByText("menu item"));

    expect(onRename).not.toHaveBeenCalled();
  });

  it("follows the binding from Settings", () => {
    const onRename = vi.fn();
    render(<Target name="chat title" onRename={onRename} />);
    act(() =>
      useShortcutStore.getState().setShortcut("renameTitle", createShortcutChord("E", { primary: true, shift: true })),
    );

    expect(pressRename(document.body)).toBe(true);
    fireEvent.keyDown(document.body, { key: "E", code: "KeyE", metaKey: true, shiftKey: true });

    expect(onRename).toHaveBeenCalledTimes(1);
  });

  it("does nothing once the binding is cleared", () => {
    const onRename = vi.fn();
    render(<Target name="chat title" onRename={onRename} />);
    act(() => useShortcutStore.getState().setShortcut("renameTitle", null));

    expect(pressRename(document.body)).toBe(true);
    expect(onRename).not.toHaveBeenCalled();
  });

  it("runs for a chord the desktop shell relays, from where focus is", () => {
    const page = vi.fn();
    const floating = vi.fn();
    render(
      <>
        <Target name="chat title" onRename={page} />
        <div data-mc="chat-window">
          <Target name="floating chat" onRename={floating} />
          <textarea aria-label="floating composer" />
        </div>
      </>,
    );

    expect(runRenameTitleShortcut(document.body)).toBe(true);
    expect(page).toHaveBeenCalledTimes(1);
    expect(runRenameTitleShortcut(screen.getByLabelText("floating composer"))).toBe(true);
    expect(floating).toHaveBeenCalledTimes(1);
  });

  it("ignores a relayed chord once Settings moved rename to another key", () => {
    const onRename = vi.fn();
    render(<Target name="chat title" onRename={onRename} />);
    act(() =>
      useShortcutStore.getState().setShortcut("renameTitle", createShortcutChord("E", { primary: true, shift: true })),
    );

    expect(runRenameTitleShortcut(document.body)).toBe(false);
    expect(onRename).not.toHaveBeenCalled();
  });

  it("stops listening once the title unmounts", () => {
    const onRename = vi.fn();
    const view = render(<Target name="chat title" onRename={onRename} />);
    view.unmount();

    expect(pressRename(document.body)).toBe(true);
    expect(runRenameTitleShortcut(document.body)).toBe(false);
    expect(onRename).not.toHaveBeenCalled();
  });
});

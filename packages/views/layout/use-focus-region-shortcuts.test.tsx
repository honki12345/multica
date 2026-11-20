import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { fireEvent, render } from "@testing-library/react";
import {
  configureShortcutPlatform,
  configureShortcutRuntime,
  createShortcutChord,
  useShortcutStore,
} from "@multica/core/shortcuts";
import {
  FOCUS_ACTIVATE_ATTR,
  FOCUS_FLASH_ATTR,
  FOCUS_REGION_ATTR,
  FOCUS_ROW_ATTR,
  FOCUS_SCOPE_ATTR,
  REGION_TARGET_ATTR,
} from "./focus-regions";
import { useFocusRegionShortcuts } from "./use-focus-region-shortcuts";

// jsdom has no layout. The hook decides visibility with the real probe, so
// every region gets a box and the hit test returns the region itself.
function giveBoxes() {
  for (const el of document.querySelectorAll<HTMLElement>(`[${FOCUS_REGION_ATTR}], [${FOCUS_ROW_ATTR}]`)) {
    el.getClientRects = () => [{}] as unknown as DOMRectList;
    el.getBoundingClientRect = () => ({ left: 0, top: 0, width: 10, height: 10 }) as DOMRect;
  }
  document.elementFromPoint = () => null;
}

function Shortcuts() {
  useFocusRegionShortcuts();
  return null;
}

function Page({ composer = true, onActivate }: { composer?: boolean; onActivate?: () => void }) {
  return (
    <>
      <Shortcuts />
      <aside data-focus-region="list" id="list" data-testid="list">
        <div data-focus-row="" tabIndex={0} id="row-0">first</div>
        <div data-focus-row="" tabIndex={0} id="row-1" {...{ [REGION_TARGET_ATTR]: "" }}>selected</div>
        <div data-focus-row="" tabIndex={0} id="row-2">third</div>
      </aside>
      <main data-focus-region="body" tabIndex={-1} id="body" data-testid="body">
        <p>reading</p>
        <input aria-label="search" id="search" />
      </main>
      {composer && (
        <div data-focus-region="composer" data-testid="composer">
          <button type="button" id="attach">attach</button>
          <div {...{ [REGION_TARGET_ATTR]: "" }}>
            {onActivate ? (
              <div role="button" tabIndex={0} id="shell" {...{ [FOCUS_ACTIVATE_ATTR]: "" }} onClick={onActivate}>
                shell
              </div>
            ) : (
              <div contentEditable suppressContentEditableWarning id="editor">draft</div>
            )}
          </div>
        </div>
      )}
    </>
  );
}

const press = (key: string, init: KeyboardEventInit = {}, target: Element = document.activeElement ?? document.body) =>
  fireEvent.keyDown(target, { key, code: key.length === 1 ? `Key${key.toUpperCase()}` : key, ...init });
const active = () => document.activeElement?.id || document.activeElement?.getAttribute("data-testid");

beforeEach(() => {
  configureShortcutPlatform("macos");
  configureShortcutRuntime("desktop");
});

afterEach(() => {
  configureShortcutPlatform(null);
  configureShortcutRuntime(null);
  useShortcutStore.getState().resetAll();
  document.body.innerHTML = "";
});

describe("useFocusRegionShortcuts", () => {
  it("jumps to the list, the body and the composer, each on its own key, even from inside an editor", () => {
    render(<Page />);
    giveBoxes();
    document.getElementById("editor")!.focus();

    press("H", { metaKey: true, shiftKey: true });
    expect(active()).toBe("row-1");
    press("L", { metaKey: true, shiftKey: true });
    expect(active()).toBe("body");
    press("L", { metaKey: true });
    expect(active()).toBe("editor");
  });

  it("cycles regions with F8 and Shift+F8, wrapping at either end", () => {
    render(<Page />);
    giveBoxes();
    document.getElementById("row-1")!.focus();

    press("F8");
    expect(active()).toBe("body");
    press("F8");
    expect(active()).toBe("editor");
    press("F8");
    expect(active()).toBe("row-1");
    press("F8", { shiftKey: true });
    expect(active()).toBe("editor");
  });

  it("cycles between list and body on a screen without a composer, where the composer key does nothing", () => {
    render(<Page composer={false} />);
    giveBoxes();
    document.getElementById("row-1")!.focus();

    press("F8");
    expect(active()).toBe("body");
    press("F8");
    expect(active()).toBe("row-1");
    const event = press("L", { metaKey: true });
    expect(event).toBe(true);
    expect(active()).toBe("row-1");
  });

  it("activates a lazy composer shell instead of focusing it", () => {
    let activated = 0;
    render(<Page onActivate={() => activated++} />);
    giveBoxes();
    document.getElementById("row-1")!.focus();
    press("L", { metaKey: true });
    expect(activated).toBe(1);
  });

  it("flashes the region keyboard focus moved into, and not on a mouse click", () => {
    const { getByTestId } = render(<Page />);
    giveBoxes();
    document.getElementById("row-1")!.focus();
    press("F8");
    expect(getByTestId("body").hasAttribute(FOCUS_FLASH_ATTR)).toBe(true);
    expect(getByTestId("list").hasAttribute(FOCUS_FLASH_ATTR)).toBe(false);
    fireEvent.pointerDown(getByTestId("list"));
    expect(getByTestId("body").hasAttribute(FOCUS_FLASH_ATTR)).toBe(false);
  });

  it("sends Esc from the body or the list back to the composer, and leaves it alone elsewhere", () => {
    render(<Page />);
    giveBoxes();
    document.getElementById("body")!.focus();
    press("Escape");
    expect(active()).toBe("editor");

    document.getElementById("row-2")!.focus();
    press("Escape");
    expect(active()).toBe("editor");

    // Esc inside the composer keeps its own meaning (closing a picker).
    document.getElementById("editor")!.focus();
    expect(press("Escape")).toBe(true);
    expect(active()).toBe("editor");

    // A text field in the body owns Esc too.
    document.getElementById("search")!.focus();
    expect(press("Escape")).toBe(true);
    expect(active()).toBe("search");
  });

  it("does nothing on Esc on a screen without a composer", () => {
    render(<Page composer={false} />);
    giveBoxes();
    document.getElementById("body")!.focus();
    expect(press("Escape")).toBe(true);
    expect(active()).toBe("body");
  });

  it("leaves an Esc another handler already claimed alone (a menu closing)", () => {
    render(<Page />);
    giveBoxes();
    const body = document.getElementById("body")!;
    body.focus();
    body.addEventListener("keydown", (event) => event.preventDefault(), { once: true });
    press("Escape");
    expect(active()).toBe("body");
  });

  it("steps through list rows with the arrow keys only while the list has focus", () => {
    render(<Page />);
    giveBoxes();
    document.getElementById("row-1")!.focus();
    expect(press("ArrowDown")).toBe(false);
    expect(active()).toBe("row-2");
    press("ArrowDown");
    expect(active()).toBe("row-2");
    press("Home");
    expect(active()).toBe("row-0");
    press("End");
    expect(active()).toBe("row-2");

    // In the body the arrows keep their native meaning (scroll).
    document.getElementById("body")!.focus();
    expect(press("ArrowDown")).toBe(true);
    expect(active()).toBe("body");
  });

  it("leaves arrow keys to a list that handles them itself", () => {
    render(<Page />);
    giveBoxes();
    const row = document.getElementById("row-1")!;
    row.focus();
    row.addEventListener("keydown", (event) => event.preventDefault(), { once: true });
    press("ArrowDown");
    expect(active()).toBe("row-1");
  });

  it("keeps the floating chat window's regions to itself", () => {
    render(
      <>
        <Page />
        <div {...{ [FOCUS_SCOPE_ATTR]: "" }}>
          <div data-focus-region="body" tabIndex={-1} id="window-body" />
          <div data-focus-region="composer">
            <textarea id="window-input" {...{ [REGION_TARGET_ATTR]: "" }} />
          </div>
        </div>
      </>,
    );
    giveBoxes();
    document.getElementById("window-input")!.focus();
    press("F8");
    expect(active()).toBe("window-body");
    press("F8");
    expect(active()).toBe("window-input");
  });

  it("leaves Esc to an open issue peek, which closes on it", () => {
    render(
      <>
        <Page />
        <aside data-issue-peek="">
          <div data-focus-region="body" tabIndex={-1} id="peek-body" />
        </aside>
      </>,
    );
    giveBoxes();
    document.getElementById("body")!.focus();
    expect(press("Escape")).toBe(true);
    expect(active()).toBe("body");
  });

  it("still sends Esc to the chat window's composer while a peek is open", () => {
    render(
      <>
        <Page />
        <aside data-issue-peek="" />
        <div {...{ [FOCUS_SCOPE_ATTR]: "" }}>
          <div data-focus-region="body" tabIndex={-1} id="window-body" />
          <div data-focus-region="composer">
            <textarea id="window-input" {...{ [REGION_TARGET_ATTR]: "" }} />
          </div>
        </div>
      </>,
    );
    giveBoxes();
    document.getElementById("window-body")!.focus();
    press("Escape");
    expect(active()).toBe("window-input");
  });

  it("lets Settings record a region key instead of moving focus", () => {
    render(
      <>
        <Page />
        <button type="button" aria-pressed="true" data-shortcut-recorder="" id="recorder">
          recording
        </button>
      </>,
    );
    giveBoxes();
    document.getElementById("recorder")!.focus();
    expect(press("F8")).toBe(true);
    expect(active()).toBe("recorder");
  });

  it("leaves the arrow keys to a keyboard drag in progress", () => {
    render(<Page />);
    giveBoxes();
    const row = document.getElementById("row-1")!;
    row.setAttribute("data-dragging", "");
    row.focus();
    expect(press("ArrowDown")).toBe(true);
    expect(active()).toBe("row-1");
  });

  it("does not step rows in a list that steps its own selection", () => {
    render(<Page />);
    giveBoxes();
    document.getElementById("list")!.setAttribute("data-focus-rows", "self");
    document.getElementById("row-1")!.focus();
    expect(press("End")).toBe(true);
    expect(active()).toBe("row-1");
  });

  it("leaves Mod+Shift+H to the editor's highlight when text is selected, and moves otherwise", () => {
    render(<Page />);
    giveBoxes();
    const editor = document.getElementById("editor")!;
    editor.focus();
    const range = document.createRange();
    range.selectNodeContents(editor);
    document.getSelection()!.removeAllRanges();
    document.getSelection()!.addRange(range);
    expect(press("H", { metaKey: true, shiftKey: true })).toBe(true);
    expect(active()).toBe("editor");

    document.getSelection()!.collapseToEnd();
    press("H", { metaKey: true, shiftKey: true });
    expect(active()).toBe("row-1");

    // Only the chord the editor binds yields; Mod+Shift+L moves even with a selection.
    editor.focus();
    document.getSelection()!.removeAllRanges();
    document.getSelection()!.addRange(range);
    press("L", { metaKey: true, shiftKey: true });
    expect(active()).toBe("body");
  });

  it("wins over an editor keymap that binds the same chord", () => {
    render(<Page />);
    giveBoxes();
    const editor = document.getElementById("editor")!;
    editor.focus();
    let editorSaw = 0;
    editor.addEventListener("keydown", () => editorSaw++);
    press("L", { metaKey: true, shiftKey: true });
    expect(editorSaw).toBe(0);
    expect(active()).toBe("body");
  });

  it("follows a binding changed in Settings", () => {
    render(<Page />);
    giveBoxes();
    document.getElementById("row-1")!.focus();
    useShortcutStore.getState().setShortcut("focusNextRegion", createShortcutChord("F6"));
    press("F8");
    expect(active()).toBe("row-1");
    press("F6");
    expect(active()).toBe("body");
  });
});

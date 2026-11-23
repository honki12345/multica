// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render } from "@testing-library/react";
import { useState } from "react";
import { useTakeKeyboardFocus } from "./take-keyboard-focus";

/** Like the real callers: the request is page state that settling clears. */
function Harness({ request, onTaken }: { request: number; onTaken: () => void }) {
  const [target, setTarget] = useState<HTMLDivElement | null>(null);
  const [pendingFor, setPendingFor] = useState(0);
  const [seen, setSeen] = useState(0);
  if (request !== seen) {
    setSeen(request);
    setPendingFor(request);
  }
  useTakeKeyboardFocus(target, pendingFor !== 0, () => {
    setPendingFor(0);
    onTaken();
  });
  return (
    <>
      <button type="button">row</button>
      <div ref={setTarget} tabIndex={-1} data-testid="target">
        reading pane
      </div>
      <textarea aria-label="composer" />
    </>
  );
}

function openMenu() {
  const menu = document.createElement("div");
  menu.setAttribute("role", "menu");
  const item = document.createElement("button");
  item.textContent = "menu item";
  menu.appendChild(item);
  document.body.appendChild(menu);
  item.focus();
  return menu;
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
});

afterEach(() => {
  vi.useRealTimers();
  document.querySelectorAll('[role="menu"]').forEach((el) => el.remove());
});

describe("useTakeKeyboardFocus", () => {
  it("moves focus to the target without scrolling, once", () => {
    const focus = vi.spyOn(HTMLElement.prototype, "focus");
    const onTaken = vi.fn();
    const view = render(<Harness request={0} onTaken={onTaken} />);
    view.getByRole("button", { name: "row" }).focus();

    view.rerender(<Harness request={1} onTaken={onTaken} />);

    expect(document.activeElement).toBe(view.getByTestId("target"));
    expect(focus).toHaveBeenLastCalledWith({ preventScroll: true });
    expect(onTaken).toHaveBeenCalledTimes(1);
    focus.mockRestore();
  });

  it("leaves the caret in a text field and still settles the request", () => {
    const onTaken = vi.fn();
    const view = render(<Harness request={0} onTaken={onTaken} />);
    const composer = view.getByRole("textbox", { name: "composer" });
    composer.focus();

    view.rerender(<Harness request={1} onTaken={onTaken} />);

    expect(document.activeElement).toBe(composer);
    expect(onTaken).toHaveBeenCalledTimes(1);
  });

  it("waits while a menu holds focus, then takes it once the menu lets go", () => {
    const onTaken = vi.fn();
    const view = render(<Harness request={0} onTaken={onTaken} />);
    const menu = openMenu();

    view.rerender(<Harness request={1} onTaken={onTaken} />);
    expect(document.activeElement).toBe(menu.querySelector("button"));
    expect(onTaken).not.toHaveBeenCalled();

    // The closing menu hands focus back to the control that opened it.
    act(() => {
      menu.remove();
      view.getByRole("button", { name: "row" }).focus();
    });

    expect(document.activeElement).toBe(view.getByTestId("target"));
    expect(onTaken).toHaveBeenCalledTimes(1);
  });

  it("takes focus once a removed menu has dropped it to the page", () => {
    const onTaken = vi.fn();
    const view = render(<Harness request={0} onTaken={onTaken} />);
    const menu = openMenu();
    view.rerender(<Harness request={1} onTaken={onTaken} />);

    act(() => {
      menu.remove();
      vi.advanceTimersByTime(100);
    });

    expect(document.activeElement).toBe(view.getByTestId("target"));
    expect(onTaken).toHaveBeenCalledTimes(1);
  });

  it("gives up after a while instead of taking focus much later", () => {
    const onTaken = vi.fn();
    const view = render(<Harness request={0} onTaken={onTaken} />);
    const menu = openMenu();
    view.rerender(<Harness request={1} onTaken={onTaken} />);

    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(onTaken).toHaveBeenCalledTimes(1);
    act(() => {
      menu.remove();
      view.getByRole("button", { name: "row" }).focus();
      vi.advanceTimersByTime(100);
    });

    expect(document.activeElement).toBe(view.getByRole("button", { name: "row" }));
  });
});

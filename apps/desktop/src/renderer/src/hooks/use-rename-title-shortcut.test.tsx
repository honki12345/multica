// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { render } from "@testing-library/react";

const runRenameTitleShortcut = vi.hoisted(() => vi.fn(() => true));
vi.mock("@multica/views/layout", () => ({ runRenameTitleShortcut }));

import { useRenameTitleShortcutRelay } from "./use-rename-title-shortcut";

function Probe() {
  useRenameTitleShortcutRelay();
  return null;
}

function stubDesktopAPI(withListener = true) {
  let handler: (() => void) | null = null;
  const onRenameTitleShortcut = vi.fn((callback: () => void) => {
    handler = callback;
    return () => {
      handler = null;
    };
  });
  (window as unknown as { desktopAPI: Record<string, unknown> }).desktopAPI = withListener
    ? { onRenameTitleShortcut }
    : {};
  return { onRenameTitleShortcut, deliver: () => handler?.() };
}

afterEach(() => {
  runRenameTitleShortcut.mockClear();
});

describe("useRenameTitleShortcutRelay", () => {
  it("renames from where focus is when main relays Cmd/Ctrl+R", () => {
    const { deliver } = stubDesktopAPI();
    const input = document.createElement("textarea");
    document.body.append(input);
    input.focus();
    render(<Probe />);

    deliver();

    expect(runRenameTitleShortcut).toHaveBeenCalledWith(input);
    input.remove();
  });

  it("stops listening on unmount", () => {
    const { deliver } = stubDesktopAPI();
    const view = render(<Probe />);
    view.unmount();

    deliver();

    expect(runRenameTitleShortcut).not.toHaveBeenCalled();
  });

  it("tolerates an older preload without the listener", () => {
    stubDesktopAPI(false);

    expect(() => render(<Probe />)).not.toThrow();
  });
});

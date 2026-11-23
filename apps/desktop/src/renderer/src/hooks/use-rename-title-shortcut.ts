import { useEffect } from "react";
import { runRenameTitleShortcut } from "@multica/views/layout";

/**
 * Receive Cmd/Ctrl+R from Electron's main process, which holds the chord back
 * from reloading the window (and so from the page's own keydown), and rename
 * the chat or issue title on screen (CALA-327). Every window subscribes: main
 * sends the chord to the window it was pressed in.
 */
export function useRenameTitleShortcutRelay(): void {
  useEffect(
    () =>
      // Optional call keeps renderer HMR safe while an old preload is still
      // attached, same as the other main-process shortcut listeners.
      window.desktopAPI.onRenameTitleShortcut?.(() => {
        runRenameTitleShortcut(document.activeElement);
      }),
    [],
  );
}

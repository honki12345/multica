import { afterEach, describe, expect, it, vi } from "vitest";
import {
  FOCUS_ACTIVATE_ATTR,
  FOCUS_REGION_ATTR,
  FOCUS_ROW_ATTR,
  FOCUS_SCOPE_ATTR,
  REGION_TARGET_ATTR,
  findFocusRegions,
  focusRegionTarget,
  focusRowTarget,
  isRegionRendered,
  nextFocusRegion,
  pickRegionOfKind,
  regionOfElement,
  stepFocusRow,
  type FocusRegion,
  type FocusRegionKind,
} from "./focus-regions";

// jsdom has no layout: every element reports no client rects. The tests pass
// their own visibility probe; `data-test-hidden` stands for "not rendered".
const isRendered = (el: Element) => !(el as HTMLElement).dataset.testHidden;

function region(kind: FocusRegionKind, html = "", attrs: Record<string, string> = {}, parent: Element = document.body) {
  const el = document.createElement("div");
  el.setAttribute(FOCUS_REGION_ATTR, kind);
  for (const [name, value] of Object.entries(attrs)) el.setAttribute(name, value);
  el.innerHTML = html;
  parent.append(el);
  return el;
}

const kinds = (regions: FocusRegion[]) => regions.map((r) => r.kind);

afterEach(() => {
  document.body.innerHTML = "";
  vi.restoreAllMocks();
});

describe("findFocusRegions", () => {
  it("lists the page's regions in document order", () => {
    region("list");
    region("body");
    region("composer");
    expect(kinds(findFocusRegions(document, isRendered))).toEqual(["list", "body", "composer"]);
  });

  it("skips regions that are not rendered, inert, or aria-hidden (a collapsed list, the closed chat window)", () => {
    region("list", "", { "data-test-hidden": "1" });
    region("body");
    const inertHost = document.createElement("div");
    inertHost.setAttribute("inert", "");
    document.body.append(inertHost);
    region("composer", "", {}, inertHost);
    const closedWindow = document.createElement("div");
    closedWindow.setAttribute("aria-hidden", "true");
    document.body.append(closedWindow);
    region("composer", "", {}, closedWindow);
    expect(kinds(findFocusRegions(document, isRendered))).toEqual(["body"]);
  });

  it("keeps a focus scope's regions (the floating chat window) out of the page and finds them from inside", () => {
    region("list");
    region("body");
    const chatWindow = document.createElement("div");
    chatWindow.setAttribute(FOCUS_SCOPE_ATTR, "");
    document.body.append(chatWindow);
    region("body", "", {}, chatWindow);
    region("composer", "", {}, chatWindow);
    expect(kinds(findFocusRegions(document, isRendered))).toEqual(["list", "body"]);
    expect(kinds(findFocusRegions(chatWindow, isRendered))).toEqual(["body", "composer"]);
  });
});

describe("isRegionRendered", () => {
  it("treats a region whose middle is covered by something outside it as hidden", () => {
    const body = region("body");
    const overlay = document.createElement("div");
    document.body.append(overlay);
    vi.spyOn(body, "getClientRects").mockReturnValue([{}] as unknown as DOMRectList);
    vi.spyOn(body, "getBoundingClientRect").mockReturnValue({ left: 0, top: 0, width: 100, height: 100 } as DOMRect);
    document.elementFromPoint = () => overlay;
    expect(isRegionRendered(body)).toBe(false);
    document.elementFromPoint = () => body;
    expect(isRegionRendered(body)).toBe(true);
  });
});

describe("nextFocusRegion", () => {
  const regions = (...list: FocusRegionKind[]): FocusRegion[] =>
    list.map((kind) => ({ kind, element: document.createElement("div") }));

  it("moves forward and backward, wrapping at either end", () => {
    const all = regions("list", "body", "composer");
    expect(nextFocusRegion(all, all[0]!.element, 1)).toBe(all[1]);
    expect(nextFocusRegion(all, all[2]!.element, 1)).toBe(all[0]);
    expect(nextFocusRegion(all, all[0]!.element, -1)).toBe(all[2]);
  });

  it("cycles between list and body on a screen with no composer", () => {
    const all = regions("list", "body");
    expect(nextFocusRegion(all, all[1]!.element, 1)).toBe(all[0]);
    expect(nextFocusRegion(all, all[0]!.element, -1)).toBe(all[1]);
  });

  it("enters at the first region going forward and at the last going back from outside every region", () => {
    const all = regions("list", "body", "composer");
    expect(nextFocusRegion(all, null, 1)).toBe(all[0]);
    expect(nextFocusRegion(all, null, -1)).toBe(all[2]);
  });

  it("has nowhere to go without regions", () => {
    expect(nextFocusRegion([], null, 1)).toBeNull();
  });
});

describe("pickRegionOfKind", () => {
  const regions = (...list: FocusRegionKind[]): FocusRegion[] =>
    list.map((kind) => ({ kind, element: document.createElement("div") }));

  it("picks the region of that kind closest to the content (the page's own list over the side panel)", () => {
    const all = regions("list", "list", "body");
    expect(pickRegionOfKind(all, "list", null)).toBe(all[1]);
  });

  it("steps to the other region of the kind when pressed again from inside one", () => {
    const all = regions("list", "list", "body");
    expect(pickRegionOfKind(all, "list", all[1]!.element)).toBe(all[0]);
    expect(pickRegionOfKind(all, "list", all[0]!.element)).toBe(all[1]);
  });

  it("is null when the page has no region of that kind (no composer)", () => {
    expect(pickRegionOfKind(regions("list", "body"), "composer", null)).toBeNull();
  });
});

describe("focusRegionTarget", () => {
  it("prefers the element marked as the region's target (the selected row)", () => {
    const list = region(
      "list",
      `<div tabindex="0" id="row-1"></div><div tabindex="0" id="row-2" ${REGION_TARGET_ATTR}></div>`,
    );
    expect(focusRegionTarget(list)?.id).toBe("row-2");
  });

  it("focuses into a marked target that cannot take focus itself (the editor area)", () => {
    const composer = region("composer", `<button id="attach"></button><div ${REGION_TARGET_ATTR}><div contenteditable="true" id="ed"></div></div>`);
    expect(focusRegionTarget(composer)?.id).toBe("ed");
  });

  it("keeps a lazy shell as the target so the caller can activate it", () => {
    const composer = region("composer", `<div role="button" tabindex="0" id="shell" ${FOCUS_ACTIVATE_ATTR} ${REGION_TARGET_ATTR}></div>`);
    expect(focusRegionTarget(composer)?.id).toBe("shell");
  });

  it("lands on a region's own target, not on a nested region's (the comment box inside the issue body)", () => {
    const body = region(
      "body",
      `<p>issue</p><div ${FOCUS_REGION_ATTR}="composer"><div role="button" tabindex="0" id="shell" ${REGION_TARGET_ATTR}></div></div>`,
      { tabindex: "-1" },
    );
    expect(focusRegionTarget(body)).toBe(body);
  });

  it("skips a marked target that is not shown (the comment editor before it mounts)", () => {
    const composer = region(
      "composer",
      `<div hidden ${REGION_TARGET_ATTR}><div contenteditable="true" id="ed"></div></div><div role="button" tabindex="0" id="shell" ${REGION_TARGET_ATTR}></div>`,
    );
    expect(focusRegionTarget(composer)?.id).toBe("shell");
  });

  it("falls back to the region itself when it can take focus (the body scroller)", () => {
    const body = region("body", "<p>text</p><button>reply</button>", { tabindex: "-1" });
    expect(focusRegionTarget(body)).toBe(body);
  });

  it("falls back to the first focusable element, skipping disabled and inert ones", () => {
    const list = region("list", `<button disabled id="a"></button><div inert><button id="b"></button></div><a href="#" id="c"></a>`);
    expect(focusRegionTarget(list)?.id).toBe("c");
  });

  it("has no target in a region with nothing to focus", () => {
    expect(focusRegionTarget(region("body", "<p>text</p>"))).toBeNull();
  });
});

describe("regionOfElement", () => {
  it("names the innermost region around the element (the composer inside the issue body)", () => {
    const body = region("body", `<div ${FOCUS_REGION_ATTR}="composer"><textarea id="t"></textarea></div><p id="p"></p>`);
    expect(regionOfElement(body.querySelector("#t"))?.kind).toBe("composer");
    expect(regionOfElement(body.querySelector("#p"))).toEqual({ kind: "body", element: body });
  });

  it("is null outside every region and for nothing focused", () => {
    const loose = document.createElement("button");
    document.body.append(loose);
    expect(regionOfElement(loose)).toBeNull();
    expect(regionOfElement(null)).toBeNull();
  });
});

describe("focusRowTarget", () => {
  it("prefers the row's link over a toggle in front of it (a project row in the sidebar tree)", () => {
    const row = document.createElement("div");
    row.innerHTML = `<button id="toggle"></button><a href="/p" id="link"></a>`;
    expect(focusRowTarget(row)?.id).toBe("link");
  });

  it("takes the row itself when it is focusable (a chat row)", () => {
    const row = document.createElement("div");
    row.tabIndex = 0;
    row.innerHTML = `<button id="pin"></button>`;
    expect(focusRowTarget(row)).toBe(row);
  });
});

describe("stepFocusRow", () => {
  function rows(count: number) {
    return Array.from({ length: count }, (_, i) => {
      const row = document.createElement("div");
      row.setAttribute(FOCUS_ROW_ATTR, "");
      row.id = `r${i}`;
      return row;
    });
  }

  it("moves one row down or up and stops at either end", () => {
    const all = rows(3);
    expect(stepFocusRow(all, all[0]!, "ArrowDown")?.id).toBe("r1");
    expect(stepFocusRow(all, all[1]!, "ArrowUp")?.id).toBe("r0");
    expect(stepFocusRow(all, all[2]!, "ArrowDown")).toBeNull();
    expect(stepFocusRow(all, all[0]!, "ArrowUp")).toBeNull();
  });

  it("jumps to the first and last rows with Home and End", () => {
    const all = rows(3);
    expect(stepFocusRow(all, all[1]!, "Home")?.id).toBe("r0");
    expect(stepFocusRow(all, all[1]!, "End")?.id).toBe("r2");
    expect(stepFocusRow(all, all[2]!, "End")).toBeNull();
  });

  it("enters at the top going down and at the bottom going up from outside a row", () => {
    const all = rows(3);
    expect(stepFocusRow(all, null, "ArrowDown")?.id).toBe("r0");
    expect(stepFocusRow(all, null, "ArrowUp")?.id).toBe("r2");
    expect(stepFocusRow([], null, "ArrowDown")).toBeNull();
  });
});

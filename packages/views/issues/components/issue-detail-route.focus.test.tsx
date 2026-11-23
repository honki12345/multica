import { describe, expect, it, vi } from "vitest";
import { render } from "@testing-library/react";
import type { ReactNode } from "react";
import { NavigationProvider } from "../../navigation";

const detailProps = vi.hoisted(() => ({ last: null as { focusOnOpen?: boolean } | null }));

vi.mock("@multica/core/hooks", () => ({ useWorkspaceId: () => "ws-1" }));
vi.mock("@multica/core/paths", async () => {
  const actual = await vi.importActual<typeof import("@multica/core/paths")>("@multica/core/paths");
  return { ...actual, useWorkspacePaths: () => actual.paths.workspace("acme") };
});
vi.mock("@multica/core/issues/canonical-id", () => ({
  useCanonicalIssue: () => ({
    canonicalId: "issue-1",
    issue: { id: "issue-1", identifier: "TES-1" },
    isResolving: false,
    notFound: false,
    loadFailed: false,
    isRetrying: false,
    retry: vi.fn(),
    hasLoaded: true,
  }),
}));
vi.mock("./issue-detail", () => ({
  IssueDetail: (props: { focusOnOpen?: boolean }) => {
    detailProps.last = props;
    return null;
  },
  IssueDetailSkeleton: () => null,
  IssueNotFound: () => null,
  IssueLoadError: () => null,
}));
vi.mock("./issue-peek", () => ({
  IssuePeekHost: ({ children }: { children: ReactNode }) => <>{children}</>,
}));

import { IssueDetailRoute } from "./issue-detail-route";

describe("IssueDetailRoute keyboard focus (CALA-330)", () => {
  it("asks the issue page to take the scroll keys when it opens", () => {
    render(
      <NavigationProvider
        value={{
          push: vi.fn(),
          replace: vi.fn(),
          back: vi.fn(),
          pathname: "/acme/issues/TES-1",
          searchParams: new URLSearchParams(),
          hash: "",
          getShareableUrl: (p: string) => p,
        }}
      >
        <IssueDetailRoute routeId="TES-1" />
      </NavigationProvider>,
    );

    expect(detailProps.last?.focusOnOpen).toBe(true);
  });
});

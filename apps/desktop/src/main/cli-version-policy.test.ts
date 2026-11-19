// @vitest-environment node
import { describe, expect, it } from "vitest";
import { acceptsCliVersion, isForkCliVersion } from "./cli-version-policy";

describe("fork CLI version policy", () => {
  it("recognizes fork versions, including dev describe suffixes", () => {
    expect(isForkCliVersion("0.11.0-hoon.1")).toBe(true);
    expect(isForkCliVersion("v0.11.0-hoon.12")).toBe(true);
    expect(isForkCliVersion("0.11.0-hoon.1-3-g5394959-dirty")).toBe(true);
  });

  it("rejects official releases and upstream dev builds", () => {
    expect(isForkCliVersion("0.10.0")).toBe(false);
    expect(isForkCliVersion("v0.11.0")).toBe(false);
    expect(isForkCliVersion("0.11.0-14-gabcdef0")).toBe(false);
    expect(isForkCliVersion("0.9.0-resident.6")).toBe(false);
    expect(isForkCliVersion("dev")).toBe(false);
  });

  it("refuses an official CLI only in packaged builds", () => {
    expect(acceptsCliVersion("0.10.0", true)).toBe(false);
    expect(acceptsCliVersion("0.11.0-hoon.1", true)).toBe(true);
    expect(acceptsCliVersion("0.10.0", false)).toBe(true);
  });
});

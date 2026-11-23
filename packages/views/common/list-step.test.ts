// @vitest-environment node
import { describe, expect, it } from "vitest";
import { stepListIndex } from "./list-step";

const keys = ["a", "b", "c"];

describe("stepListIndex", () => {
  it("moves one row down or up from the open row", () => {
    expect(stepListIndex(keys, "a", "next")).toBe(1);
    expect(stepListIndex(keys, "c", "previous")).toBe(1);
  });

  it("stops at either end instead of wrapping around", () => {
    expect(stepListIndex(keys, "c", "next")).toBeNull();
    expect(stepListIndex(keys, "a", "previous")).toBeNull();
  });

  it("enters the list at the top going down and at the bottom going up when the open row is not listed", () => {
    expect(stepListIndex(keys, null, "next")).toBe(0);
    expect(stepListIndex(keys, null, "previous")).toBe(2);
    expect(stepListIndex(keys, "gone", "next")).toBe(0);
    expect(stepListIndex(keys, "gone", "previous")).toBe(2);
  });

  it("has nowhere to go in an empty list", () => {
    expect(stepListIndex([], null, "next")).toBeNull();
    expect(stepListIndex([], "a", "previous")).toBeNull();
  });
});

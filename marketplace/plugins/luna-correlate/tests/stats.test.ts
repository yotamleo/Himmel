import { expect, test } from "bun:test";
import { betai, pearsonPValue } from "../src/stats";

test("betai symmetry midpoint", () => {
  expect(betai(0.5, 0.5, 0.5)).toBeCloseTo(0.5, 6);
});

test("betai monotone increasing in x", () => {
  expect(betai(2, 3, 0.2)).toBeLessThan(betai(2, 3, 0.8));
});

test("pearson two-tailed p — n=12, r=0.5 ≈ 0.0978", () => {
  // df=10, t=0.5*sqrt(10/0.75)=1.8257 → two-tailed p ≈ 0.0978
  expect(pearsonPValue(0.5, 12)).toBeCloseTo(0.0978, 3);
});

test("pearson p edge cases", () => {
  expect(pearsonPValue(0.5, 2)).toBe(1); // n<3 → not interpretable
  expect(pearsonPValue(1, 50)).toBe(0);  // perfect corr
  expect(pearsonPValue(0, 50)).toBeCloseTo(1, 6); // zero corr → p≈1
});

test("pearson negative-perfect correlation yields p=0", () => {
  expect(pearsonPValue(-1, 50)).toBe(0);
});

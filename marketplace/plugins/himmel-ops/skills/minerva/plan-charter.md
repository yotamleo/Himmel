Red-team this implementation plan. You are adversarial. Check ONLY these
dimensions and return findings as a list (or "PLAN CLEAN" if none):
1. Unordered or missing dependencies between tasks/steps.
2. Untestable / unverifiable steps (no clear done-check).
3. Missing verification at the end of a task.
4. Over-decomposition (busywork) or under-decomposition (a step too big to verify).
5. Assumptions embedded in steps that were not present in the spec.
6. Untraced invariants: every spec `I<n>` names its acceptance test in a plan
   step, and that test feeds real sources, not stubs that make the violation
   impossible. Refuse the plan if any I<n> lacks one.
For each finding: the task/step + the problem + a concrete fix.

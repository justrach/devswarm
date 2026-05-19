# AGENTS.md

## Issue Discovery Standard

When looking for new issues, do not rely only on casual code inspection. Prefer evidence-backed discovery methods and only file issues that are narrow, reproducible, and worth tracking.

### Core rule

A new issue should only be created if it is:
- verified on the current codebase state
- narrow in scope
- reproducible with a concrete command, test, request flow, or minimal example
- supported by actual observed behavior
- easy for another engineer to validate and pick up

### Preferred issue-finding strategies

Use these methods before proposing new issues:

1. Run code paths, not just static scans
- Prefer executing small targeted checks over only reading code.
- Use focused commands, test nodes, or minimal scripts to validate behavior.

2. Re-run stale or suspicious test suites
- Look for:
  - `XPASS`
  - `xfail`
  - skipped tests that may now be stale
  - stale or obsolete tests that may no longer match reality
- Unexpected passes and stale expected failures are strong sources of real issues.

3. Compare public API surfaces
- Check package-level exports vs submodule exports.
- Look for duplicated helper names with different behavior.
- Validate that documented imports and actual imports behave consistently.

4. Compare claims vs runnable behavior
- Check README/docs statements such as:
  - "supported"
  - "in progress"
  - "planned"
  - "coming soon"
- Verify whether the smallest runnable path actually matches the claim.

5. Compare neighboring execution paths
- Look for behavior that differs across:
  - runtime vs test client
  - native backend vs fallback backend
  - sync vs async
  - middleware vs no middleware
  - top-level import vs direct submodule import

6. Use differential testing mindset
- When relevant, compare behavior to a reference implementation or expected contract.
- For framework-style repos, compare against the documented compatibility target.

7. Use property-based or fuzz-style thinking
- Especially for:
  - routers
  - parsers
  - protocol handlers
  - validation layers
  - path/header/query normalization
- Prefer generated edge cases where practical.

8. Look for issue-worthy drift
- Documentation says one thing
- tests assume another
- runtime does a third
- public exports expose a fourth
- These mismatches often produce strong, narrow issues.

### What counts as a strong issue

A strong issue has:
- one concrete problem
- one reproducible path
- actual observed failure or mismatch
- clear expected behavior
- nearby passing controls or guards
- narrow, testable acceptance criteria
- explicit non-goals if scope could sprawl

### What does not count as a strong issue

Do not file issues that are:
- speculative
- based only on code inspection when runtime proof is possible
- broad umbrella complaints
- duplicate broad trackers without narrowing them
- warning-only cleanup unless there is a compelling reason
- multiple unrelated findings bundled together

### Required issue evidence

Before creating an issue, gather:

1. Exact repro
- One concrete command, test node, API call, UI flow, or script.

2. Observed result
- The actual failure output, incorrect result, mismatch, or unexpected behavior.

3. Expected result
- What should happen instead.

4. Nearby passing checks
- One or two closely related tests/commands/behaviors that still pass.

5. Narrow acceptance criteria
- The repro passes.
- The expected behavior is present.
- Nearby guards remain green.

6. Non-goals
- Clarify what the issue is not asking for.

### Filing rule

If the issue cannot be reduced to:
- one concrete problem
- one reproducible path
- one observed failure
- one expected behavior
- one or two nearby passing checks
- one narrow fix target

do not file it yet.

Gather better evidence first.

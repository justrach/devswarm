# Parallel Agent Orchestration: Critical Analysis

> Concrete walkthrough of a 4-layer hybrid orchestration plan using "Add OAuth2 to a TypeScript API" as the test case.
> Generated via 3-agent chain (architect → fixer → reviewer) on 2026-03-08.

---

## The Plan Under Review

```
Layer 1 — Planner LLM call:    emits JSONL task manifest, disjoint write_root per agent
Layer 2 — Harness allowlists:  sandboxes each agent's writes to their write_root
Layer 3 — flock fallback:      serializes shared file access (package.json, tsconfig, etc.)
Layer 4 — Integration branch:  all agents target integration/*, not main
```

---

## Layer 1 — Planner LLM Call

### What it emits

```jsonl
{"agent":"auth-core","write_root":"src/auth/","context_files":["src/app.ts","src/types.ts","package.json"],"task":"Create OAuth2 provider, token service, callback handler"}
{"agent":"db-migration","write_root":"src/db/migrations/","context_files":["src/db/schema.ts","src/db/connection.ts"],"task":"Add oauth_tokens table, user.oauth_provider column"}
{"agent":"routes","write_root":"src/routes/","context_files":["src/app.ts","src/auth/","src/middleware/"],"task":"Add /auth/google, /auth/callback, /auth/refresh routes"}
{"agent":"config","write_root":"src/config/","context_files":["src/config/index.ts",".env.example"],"task":"Add OAuth client ID/secret config, validation"}
{"agent":"tests","write_root":"test/auth/","context_files":["src/auth/","src/routes/","test/helpers/"],"task":"Unit + integration tests for OAuth flow"}
```

### What actually breaks

**1. Cross-cutting type dependencies.**
`auth-core` creates `src/auth/types.ts` with `OAuthToken`, `OAuthProvider`. `db-migration` and `routes` need those types but run concurrently — they import types that don't exist yet. The planner partitions *files* but cannot partition *symbols*. Agents read stale snapshots of each other's write_roots.

**2. Implicit shared files the planner misses.**
Common misses:
- `src/app.ts` — needs `app.use(authRoutes)` (who writes this line?)
- barrel `src/index.ts` — re-exports
- `.env.example` — multiple agents need to add env vars
- `src/middleware/auth.ts` — may already exist, needs modification, but falls outside all write_roots

**3. Dependency ordering is implicit.**
The manifest has no `deps` field. `tests` depends on `auth-core` + `routes` finishing. `routes` depends on `auth-core` types existing. The planner either emits deps and serializes the DAG (losing parallelism) or omits them and hopes agents work against stubs (compilation fails mid-agent).

**4. Agent context files list files that don't exist yet.**
The `tests` agent's `context_files` includes `src/auth/oauth.ts` and `src/routes/auth.ts` — post-task state, not current state. If tests agent starts concurrently, it loads those paths, gets 404 or stale snapshots, and writes tests against an interface it hallucinated.

**5. Planner context is T₀.**
If the repo has uncommitted changes or a concurrent CI run modifies a file between plan emission and agent start, `context_files` content is already stale. This is irreducible.

### Where it holds

For genuinely additive, tree-structured work (new files in new directories), the partition is clean. `src/auth/` genuinely doesn't exist yet — agent A owns it completely. Layer 1 is strongest here.

---

## Layer 2 — Harness Write_Root Enforcement

### What it produces

A gating mechanism between agent tool calls and the filesystem. Every write is checked: `realpath(target).startsWith(write_root)`. Violations are rejected.

```
agent=auth-core tries to write src/auth/oauth.ts    → ALLOWED (in write_root)
agent=auth-core tries to write src/app.ts            → BLOCKED (not in write_root)
agent=auth-core tries to read  src/types.ts          → ALLOWED (reads are unrestricted)
```

### The enforcement mechanism question is load-bearing

| Mechanism | Pros | Cons |
|---|---|---|
| **Worktree-per-agent** | Fully isolated, cleanest | ~200ms setup per agent |
| **API-mediated writes through harness** | Works for compliant tools | Any agent using shell (`echo > file`) bypasses it entirely |
| **LD_PRELOAD syscall interception** | Catches native code | Fails for subprocesses that fork (`npm install`, `tsc`, `git`) |
| **Post-write validation** | Simple | Too late — agent already reasoned on assumed success |

### What happens when an agent hits a file outside its write_root

```
WRITE BLOCKED: src/app.ts not in write_root src/auth/
```

Agent A finished `src/auth/oauth.ts` and now needs to register the middleware in `src/app.ts`. It gets blocked. LLM-based agents will:

1. Retry the write (same result)
2. Find an alternative path (write partial `auth/index.ts`, hope someone else wires it up)
3. Silently mark task complete with a TODO comment
4. Crash the subtask

**None of these are acceptable without an explicit dependency-request protocol** — a structured way for an agent to say "I need write access to `src/app.ts` for exactly these lines" and have the orchestrator queue it.

### What actually breaks

**Read staleness.** Reads are unrestricted, but an agent reads `src/types.ts` at T=0 and another modifies it at T=5. The first agent's entire plan is based on stale types. No file-level lock catches this — it's a semantic conflict.

**P(collision) = 0 is aspirational.** Only true if:
- The planner perfectly identifies all files each agent will touch (it won't — agents discover needs dynamically)
- No file is transitively depended on by multiple agents (barrel files, config, app registration)
- Agents never need to create files outside their write_root (they will)

### Where it holds

For purely additive work in new directories (`src/auth/`), sandboxing is airtight. Two agents cannot stomp each other's new files. This is the strongest guarantee in the whole plan.

---

## Layer 3 — flock Fallback for Shared Files

### What it produces

Serialized access to `package.json`, `tsconfig.json`, `package-lock.json` via POSIX advisory file locks.

**The happy path:** Agent A acquires flock on `package.json`, appends `"passport": "^0.6.0"`, releases. Agent C acquires flock, appends its deps. Works.

### Where it creaks

**1. flock is advisory.**
On Linux, `flock(2)` only protects against other processes that also call `flock`. Any agent that opens `package.json` directly (via `fs.writeFileSync` in a Node subprocess, or a raw shell `echo >`) bypasses the lock with no error.

**2. Read-before-lock race (critical).**
Agent A reads `package.json` at T₀. Agent B also reads at T₀. Agent A acquires flock, writes `{...T₀, "passport": "^0.6.0"}`. Agent B acquires flock, writes `{...T₀, "@types/passport": "^1.0.7"}` — **clobbering Agent A's change** because B's write was based on the T₀ snapshot.

Fix: agents must **re-read the file after acquiring the lock**, not use their cached T₀ copy. This cannot be enforced externally — it must be in the agent's prompt or harness tooling.

**3. The lockfile is the hard problem.**
`package-lock.json` / `yarn.lock` are generated by `npm install` — not human-editable. If two agents run `npm install` in parallel:
- Agent A: runs `npm install passport` → writes `package-lock.json` v1
- Agent B: runs `npm install knex` → writes `package-lock.json` v2 (ignoring v1 entirely)

flock on `package-lock.json` helps only if agents serialize their entire `npm install` invocations — which means waiting 30–60s per agent. Parallelism benefit collapses for anything touching dependencies.

**The real fix:** centralize all dependency mutations to a single "deps agent" that runs *after* all others have declared their requirements, then runs `npm install` exactly once.

**4. Deadlock.**
Agent A holds flock on `package.json`, needs `tsconfig.json`. Agent B holds flock on `tsconfig.json`, needs `package.json`. Classic deadlock. Advisory flocks have no deadlock detection.

Mitigation: require global lock ordering (always acquire `package.json` before `tsconfig.json`). Without specifying this, it's a latent deadlock.

**5. `src/app.ts` as a shared file — the worst case.**
Every agent that adds a feature needs to register it in `app.ts`. Sequential flock acquisitions serialize middleware registration, but each agent patches a different part of the file. Patches must be additive (insert lines), not replacement-based — otherwise the last writer clobbers all previous registrations. Requires a structured "insert after line N" protocol, not a raw write.

### Where it holds

Simple key additions to JSON (adding a top-level flag to `tsconfig.json`, adding a single dep to `package.json`) work fine under flock *if* agents re-read after acquiring the lock. The happy path is real.

---

## Layer 4 — Integration Branch

### What it produces

All agents target `integration/oauth2-feature`, not `main`. Each agent works on a sub-branch (`agent-A/oauth2`) and opens a PR into the integration branch.

### The ABA claim

> "avoids stale-snapshot ABA failures when one agent merges first"

Partially true, overstated. ABA still happens on the integration branch:

```
T₀: integration/oauth2-feature HEAD = commit X
Agent A: starts, reads HEAD = X
Agent B: starts, reads HEAD = X
Agent A: commits, merges → HEAD = Y
Agent B: tries to push  → rejected (HEAD ≠ X)
Agent B: must rebase onto Y
```

What's different: the blast radius is contained. A conflict on `integration/oauth2-feature` doesn't block production. That's real value — but it's not eliminating ABA, it's scoping it.

### Where it creaks

**Merge ordering creates a serialization point.**
If all agents touch `package.json`, their merge PRs will conflict. Merges must be serialized. With N agents all touching shared files, merge complexity is O(N²) in the worst case.

**Dependency-ordered merges aren't specified.**
Agent D (tests) imports code from Agent A's `src/auth/oauth.ts`. If D's branch merges before A's, CI fails. The integration branch requires a dependency-ordered merge sequence that the plan doesn't specify.

**Concurrent push collisions.**
If agents commit directly to `integration/oauth2-feature`, they'll hit push rejections constantly as others commit ahead of them. Sub-branches add PR-per-agent overhead. Either way needs coordination.

### Where it holds

Integration branch as a staging area is correct and valuable. Blast radius containment is real. The review gate before final merge is real protection. This layer has no fundamental flaws — only implementation gaps.

---

## Verdict: Where the Plan Holds vs Creaks

| Layer | Strongest guarantee | Biggest failure mode |
|---|---|---|
| L1 — Planner | Disjoint primary file assignment for new dirs | Partition never complete; cross-agent contracts undefined |
| L2 — Allowlists | Prevents stomping new files in new dirs | No escalation protocol when agent is blocked |
| L3 — flock | Serializes simple JSON key additions | Lockfile regeneration collapses parallelism; deadlock without global lock ordering |
| L4 — Integration branch | Contains blast radius; review gate | ABA just moves to integration branch; dependency-ordered merges unspecified |

---

## The Missing Pieces

### 1. Dependency-request protocol (L2 gap)
When Agent A needs to write outside its `write_root`, there's no structured escalation. Needs a **deferred-write queue** — agent emits `{file, patch, intent}` to a sidecar queue, a sequential "glue pass" agent applies them after all parallel work finishes.

### 2. Interface contract specification (L1 gap)
Agent B needs to know what `src/auth/oauth.ts` will export before it exists. The manifest should include **type stub files** (`.d.ts` / interface-only `.ts`) per write_root, not just file paths.

### 3. Task dependency edges (L1 gap)
The manifest needs a **DAG**, not just a flat partition. `tests` agent must wait for `auth-core` and `routes` to commit. Without explicit deps, you're hoping agents finish in the right order.

### 4. `npm install` coordination (L3 gap)
The lockfile problem has no solution within this architecture unless you centralize all dependency mutations to a single "deps agent" that runs after all others declare their requirements, then runs `npm install` exactly once.

### 5. Re-read-after-lock discipline (L3 gap)
Layer 3 only works if agents explicitly re-read shared files after acquiring the flock. Must be enforced by agent prompt instructions or harness tooling — cannot be assumed.

---

## The Proposed Architecture: L0 → L1–L4 → L5

The plan needs bookending with two sequential phases:

```
L0 (contracts, sequential)
  → planner emits type stubs (.d.ts / interface-only files) into each write_root
  → pre-writes shared touchpoints: app.use() lines, barrel re-exports, config schema keys
  → single sequential commit before any parallel agent starts

L1–L4 (parallel execution)
  → agents fill in implementations against pre-committed contracts
  → P(semantic conflict) drops dramatically because interfaces are fixed

L5 (verification, sequential)
  → single verifier agent with full write access
  → runs tsc --noEmit, fixes import mismatches
  → runs npm install exactly once to generate lockfile
  → runs full test suite
  → fixes failures with full write access
```

### Why L0 changes everything

Without L0, agents guess at each other's interfaces. Agent B imports `OAuthService` when Agent A exported `OAuthClient`. The semantic integration failure only surfaces at L5 — after all parallel work is done. With L0, agents implement against a fixed contract; the gap narrows from "guessed interface" to "conformance with spec."

### The honest speedup estimate

```
Without L0/L5:  parallel phase ~60% of wall time, but L5 fixup consumes 60-70% of "saved" time
With L0/L5:     L0 adds ~1-2s planning, L5 adds ~30-60s verification
                Net parallelism benefit: ~40-60% wall time reduction for typical feature work
                Best case (clean partitions, no shared files): ~70% reduction
                Worst case (everything shares app.ts + package.json): ~10% reduction
```

The plan is a real speedup for additive, modular features. It's largely illusory for cross-cutting concerns.

---

## When to Use Each Strategy

```
Partitioned orchestration wins when:
  - Tasks are genuinely independent (new page + new API endpoint that don't interact)
  - Codebase has strong module boundaries with stable interfaces
  - N > sqrt(F) — birthday collision risk is non-trivial without partitioning

flock-only wins when:
  - Tasks discovered dynamically (agents can't pre-commit to write_roots)
  - File set is large relative to agent count
  - Shared files are append-only (JSONL logs, env vars)

Sequential wins when:
  - Tasks are deeply interdependent (every agent needs the previous agent's output)
  - Codebase has heavy cross-cutting concerns (monolithic app.ts, shared types everywhere)
  - N is small (2-3 agents) — coordination overhead exceeds parallelism benefit
```

# Evolutionary Prompt Optimization for DevSwarm

## Design Document — Weighted-Archive QD Prompt Evolution

**Status:** Design  
**Author:** Architecture Agent  
**Date:** 2026-03-27

---

## 1. Architecture Overview

DevSwarm currently assembles system prompts from four static layers (`prompts.zig:assemble()`): agency preamble, role instructions, mode guidance, and tool preamble. This design replaces the static role-instruction layer with a **weighted archive of prompt variants per role**, evolved via telemetry-derived fitness and quality-diversity (QD) behavioral descriptors.

### Core Principle: No Single Best Prompt

Following Dym, Lawrence, & Siegel (2024), we reject canonical selection — picking a single "best" prompt per role — because it creates discontinuities: a prompt that performs well on one task distribution may fail catastrophically when the distribution shifts slightly. Instead, we maintain a **weighted frame** over prompt variants, where selection is distributional and continuity-preserving.

### System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    META-LOOP                            │
│                                                         │
│   ┌──────────┐    ┌───────────┐    ┌──────────────┐    │
│   │  SWARM   │───>│ TELEMETRY │───>│   EVOLVE     │    │
│   │ (run N   │    │ (collect   │    │ (mutate,     │──┐ │
│   │  agents) │    │  fitness)  │    │  reweight)   │  │ │
│   └──────────┘    └───────────┘    └──────────────┘  │ │
│        ^                                              │ │
│        │          ┌───────────────┐                   │ │
│        └──────────│   ARCHIVE     │<──────────────────┘ │
│                   │ (weighted     │                      │
│                   │  variants/role)│                      │
│                   └───────────────┘                      │
└─────────────────────────────────────────────────────────┘
```

**Integration points in the existing codebase:**

| Component | File | Change |
|-----------|------|--------|
| Prompt assembly | `runtime/prompts.zig:assemble()` | Sample variant from archive instead of static lookup |
| Telemetry | `telemetry.zig:WorkerMetrics` | Add behavioral descriptor fields |
| Swarm loop | `swarm.zig:workerFn` | Tag each worker with the variant ID it used |
| Config | `config.zig` | Add `[evolution]` section |
| **New** | `runtime/archive.zig` | Weighted variant archive |
| **New** | `runtime/evolve.zig` | Mutation operators + reweighting |

---

## 2. Variant Representation

A **prompt variant** is a concrete instantiation of the role-instruction layer for a specific role, paired with metadata that tracks its lineage, behavioral profile, and weight.

### PromptVariant struct

```zig
pub const PromptVariant = struct {
    // Identity
    id: u64,                        // unique variant ID (monotonic counter)
    role: []const u8,               // e.g. "finder", "fixer", "reviewer"
    generation: u32,                // evolutionary generation number

    // Content — the actual prompt text
    body: []const u8,               // role-instruction text injected into assemble()

    // Lineage
    parent_ids: [2]?u64,            // null = seed variant; [parent, null] = mutation; [a, b] = crossover
    mutation_op: ?MutationOp,       // which operator produced this variant

    // Behavioral profile (updated from telemetry)
    descriptor: BehavioralDescriptor,

    // Weight (selection probability)
    weight: f64,                    // ∈ (0, 1]; sum of weights per role = 1.0
    cumulative_evals: u32,          // how many times this variant has been deployed
    ema_fitness: f64,               // exponential moving average of fitness score
};
```

### Why this shape

- **`body` is the only mutable content** — everything else (agency preamble, mode, tools) remains static. This isolates the search space to role-specific instructions only.
- **`parent_ids`** enables full lineage tracking: single parent = mutation, two parents = crossover, null = seed (the current hardcoded prompts from `roles.zig`).
- **`weight`** replaces "pick the best" with distributional selection. Weights are renormalized after every evolution step.
- **`ema_fitness`** uses exponential smoothing (α = 0.3) to track variant quality over time without over-indexing on recent results.

---

## 3. Archive Format

The archive is a **per-role behavioral grid** — a MAP-Elites-style structure where each cell is indexed by a discretized behavioral descriptor tuple and holds not one elite, but a **weighted set of variants** (the weighted-frame extension).

### VariantArchive struct

```zig
pub const VariantArchive = struct {
    // Per-role archives
    role_archives: std.StringHashMap(RoleArchive),

    // Global state
    next_variant_id: u64,
    generation: u32,
    rng: std.Random.DefaultPrng,

    pub fn sample(self: *VariantArchive, role: []const u8) ?*const PromptVariant {
        // Weighted random selection from the role's active variants
        // Returns null if no variants exist (falls back to static prompt)
    }

    pub fn ingest(self: *VariantArchive, role: []const u8, metrics: WorkerMetrics, variant_id: u64) void {
        // Update the variant's behavioral descriptor and fitness from telemetry
        // Recompute cell placement if descriptor changed
    }

    pub fn evolve(self: *VariantArchive) void {
        // One generation: mutate, evaluate cell occupancy, reweight
    }
};

pub const RoleArchive = struct {
    // The behavioral grid: 2D array indexed by [token_efficiency_bin][thoroughness_bin]
    grid: [GRID_TOKEN_BINS][GRID_THOROUGH_BINS]Cell,

    // All variants for this role (including those not in the grid)
    variants: std.ArrayList(PromptVariant),

    // Role-level stats
    total_weight: f64,              // sum of all variant weights (should be ~1.0)
    best_fitness: f64,              // highest ema_fitness seen
};

pub const Cell = struct {
    // Weighted frame: multiple variants per cell, not just one elite
    occupants: std.BoundedArray(*PromptVariant, MAX_CELL_OCCUPANTS),

    // Cell-level aggregates
    mean_fitness: f64,
    coverage: u32,                  // number of evaluations that landed here
};
```

### Grid Dimensions

The behavioral grid has two axes (see Section 5 for descriptor definitions):

| Axis | Range | Bins | Bin Width |
|------|-------|------|-----------|
| Token efficiency | 0.0 – 1.0 | 8 | 0.125 |
| Thoroughness | 0.0 – 1.0 | 8 | 0.125 |

Total: **64 cells per role**. With `MAX_CELL_OCCUPANTS = 4`, the maximum archive size is 256 variants per role — enough for diversity without unbounded growth.

### Persistence Format

The archive is serialized to `.devswarm/archive.json`:

```json
{
  "generation": 42,
  "next_variant_id": 387,
  "roles": {
    "finder": {
      "variants": [
        {
          "id": 12,
          "generation": 3,
          "body": "You are a read-only code search agent. Locate logic...",
          "parent_ids": [null, null],
          "mutation_op": null,
          "descriptor": { "token_efficiency": 0.72, "thoroughness": 0.85 },
          "weight": 0.31,
          "cumulative_evals": 47,
          "ema_fitness": 0.68
        }
      ]
    }
  }
}
```

### Seeding

On first run (no archive exists), the archive is **seeded from `roles.zig`**: each built-in role's `system_prompt` becomes variant ID 0 for that role with `weight = 1.0`, `generation = 0`, `parent_ids = [null, null]`. This ensures backward compatibility — the system starts behaving identically to the current static prompts.

---

## 4. Mutation Operators

Mutations operate on the `body` text of a prompt variant. Each operator is a structured transformation that preserves prompt validity while exploring the instruction space.

### MutationOp enum

```zig
pub const MutationOp = enum {
    rephrase,           // Reword instructions without changing semantics
    emphasize,          // Strengthen a specific behavioral directive
    de_emphasize,       // Soften or remove a directive
    inject_constraint,  // Add a new constraint (e.g., "always cite line numbers")
    relax_constraint,   // Remove or weaken an existing constraint
    reorder,            // Shuffle the order of instruction paragraphs
    crossover,          // Recombine sections from two parent variants
    interpolate,        // Blend instructions from two parents (weighted merge)
};
```

### Operator Specifications

**`rephrase`** — Semantic-preserving rewrite  
- Input: full `body` text  
- Process: LLM call with meta-prompt: *"Rewrite these agent instructions to convey the same meaning using different wording. Do not add or remove any behavioral directives."*  
- Why: Explores surface-level variation; some phrasings elicit better model compliance than others.

**`emphasize` / `de_emphasize`** — Directive strength adjustment  
- Input: `body` text + target directive (selected by keyword scan or random paragraph)  
- Process: LLM call: *"In these instructions, make the directive about {X} significantly stronger/weaker. Use imperative language and repetition to emphasize / soften with hedging language to de-emphasize."*  
- Why: The relative weight of instructions matters; models respond differently to "ALWAYS do X" vs "consider doing X."

**`inject_constraint` / `relax_constraint`** — Structural mutation  
- Input: `body` text + constraint drawn from a **constraint bank** (curated list of behavioral directives relevant to coding agents)  
- Constraint bank examples: `"cite file:line for every finding"`, `"verify changes compile before reporting"`, `"search at least 3 different patterns before concluding"`, `"limit response to under 500 tokens"`  
- Why: Adds/removes behavioral dimensions the original prompt may not have covered.

**`reorder`** — Positional mutation  
- Input: `body` text split on `\n\n` (paragraph boundaries)  
- Process: Random permutation of paragraph order  
- Why: LLMs exhibit positional bias; instruction order affects compliance.

**`crossover`** — Two-parent recombination  
- Input: two parent `body` texts  
- Process: Split each parent on paragraph boundaries. For each paragraph position, select from parent A or B with equal probability. Deduplicate near-identical paragraphs.  
- Why: Combines proven instruction fragments from independently successful variants.

**`interpolate`** — Weighted semantic merge  
- Input: two parent `body` texts + blend ratio α ∈ [0.3, 0.7]  
- Process: LLM call: *"Merge these two sets of agent instructions. Weight the first set at {α} and the second at {1-α}. Produce a single coherent instruction set that blends both approaches."*  
- Why: Enables smooth exploration between distinct instruction strategies — this is the operator most aligned with weighted-frame continuity.

### Mutation Selection Policy

Each generation, for each role with ≥ 2 variants:
1. Select a parent variant via **fitness-proportional sampling** (weight × ema_fitness)
2. Choose an operator: 40% rephrase, 15% emphasize, 10% de-emphasize, 10% inject, 5% relax, 5% reorder, 10% crossover, 5% interpolate
3. For crossover/interpolate: select second parent via **anti-correlated sampling** (prefer parents in different grid cells)
4. Execute the mutation (LLM call for semantic operators, deterministic for reorder)
5. Assign the child an initial weight of `w_parent * 0.5` (half the parent's weight) and renormalize

### When Mutations Run

Mutations are **not** run inline during swarm execution. They run in the evolution phase (Section 7), which is triggered asynchronously after telemetry ingestion. This keeps the hot path (swarm → workers) allocation-free with respect to evolution.

For LLM-based operators (rephrase, emphasize, de-emphasize, inject, relax, interpolate): the evolution phase dispatches a single agent (role=`evolve_meta`, mode=`rush`, model=Haiku) with a structured meta-prompt. Cost per mutation: ~$0.0003 at Haiku rates. Budget: max 4 mutations per role per generation.

---

## 5. Behavioral Descriptors

Behavioral descriptors are the axes of the QD grid. They capture **how** a prompt variant behaves, not just how well it performs. Two variants can have equal fitness but occupy different behavioral niches — and we want both.

### BehavioralDescriptor struct

```zig
pub const BehavioralDescriptor = struct {
    // Axis 1: Token Efficiency — how economically the variant uses tokens
    // 0.0 = maximally verbose, 1.0 = maximally concise
    token_efficiency: f64,

    // Axis 2: Thoroughness — how exhaustively the variant explores before answering
    // 0.0 = minimal search, 1.0 = exhaustive multi-pass search
    thoroughness: f64,

    pub fn gridCell(self: BehavioralDescriptor) [2]u8 {
        return .{
            @intCast(@min(GRID_TOKEN_BINS - 1, @as(u8, @intFromFloat(self.token_efficiency * GRID_TOKEN_BINS)))),
            @intCast(@min(GRID_THOROUGH_BINS - 1, @as(u8, @intFromFloat(self.thoroughness * GRID_THOROUGH_BINS)))),
        };
    }
};
```

### Descriptor Computation from Telemetry

Both descriptors are derived from existing `WorkerMetrics` fields — no new instrumentation needed.

**Token Efficiency:**

```
token_efficiency = 1.0 - clamp(tokens_out / EXPECTED_OUTPUT_CEILING, 0.0, 1.0)
```

Where `EXPECTED_OUTPUT_CEILING` is per-role (e.g., finder=2000, fixer=4000, reviewer=3000). A variant that solves the task in 500 output tokens when the ceiling is 2000 gets efficiency 0.75. This rewards conciseness *without* penalizing roles that inherently need more output.

**Thoroughness:**

```
thoroughness = clamp(tool_calls / EXPECTED_TOOL_CEILING, 0.0, 1.0)
```

Where `EXPECTED_TOOL_CEILING` is per-role (e.g., finder=15, fixer=8, reviewer=10). Tool calls are a direct proxy for search/verification depth — a variant that makes 12 tool calls when the ceiling is 15 gets thoroughness 0.8.

### Why These Two Axes

These axes capture the fundamental tension in agent behavior:

- **Efficient + Thorough** (top-right): The ideal — concise answers after deep search. Rare but valuable.
- **Efficient + Shallow** (top-left): Fast answers with minimal exploration. Good for simple tasks.
- **Verbose + Thorough** (bottom-right): Exhaustive but wordy. Good for complex debugging.
- **Verbose + Shallow** (bottom-left): Worst case — neither efficient nor deep. Low fitness expected.

The grid preserves variants across all four quadrants because task difficulty varies: a "rush" mode swarm benefits from efficient+shallow variants, while a "deep" mode swarm benefits from verbose+thorough ones.

### Descriptor Update Rule

Descriptors are updated via exponential moving average (same α = 0.3 as fitness):

```
d.token_efficiency = (1 - α) * d.token_efficiency + α * measured_efficiency
d.thoroughness = (1 - α) * d.thoroughness + α * measured_thoroughness
```

If the updated descriptor lands in a different grid cell, the variant migrates. This prevents noisy single-run measurements from causing jitter.

---

## 6. Selection, Weighting, and the Weighted-Frames Connection

This is the core theoretical contribution of the design: replacing canonical "best prompt" selection with distributional weighted selection that preserves continuity.

### The Problem with Canonical Selection

If we simply tracked fitness and always selected the highest-fitness variant per role, we'd get **discontinuous jumps** whenever a new variant overtakes the current best. This causes:

1. **Regression spikes**: The new "best" may excel on recent tasks but fail on task types the old best handled well.
2. **Loss of coverage**: Discarding lower-fitness variants permanently loses behavioral niches they occupied.
3. **Brittleness**: A single variant is a single point of failure.

### Weighted Frames: The Solution

Dym, Lawrence, & Siegel (2024) prove that for group actions on data (here: the symmetry group of "equivalent prompts for a role"), continuously-computable canonical forms don't exist for most practically-relevant groups. Their solution: **weighted frames**, which replace a single canonical choice with a weighted distribution over group elements (here: prompt variants) where:

- Weights are **continuous functions** of the input (task distribution)
- Weights **vanish smoothly** at ill-defined points (variants that perform poorly on a task type approach zero weight rather than being abruptly discarded)
- The distribution **sums to 1** per role (proper probability distribution)

### Weight Update Rule

After each telemetry ingestion for variant `v` in role `r`:

```
// 1. Update fitness EMA
v.ema_fitness = (1 - α) * v.ema_fitness + α * measured_fitness

// 2. Compute raw weight from fitness (softmax over all variants in role)
for each variant u in role r:
    u.raw_weight = exp(β * u.ema_fitness)

// 3. Apply continuity regularization (weighted-frame smoothing)
//    Blend toward previous weight to prevent discontinuous jumps
for each variant u in role r:
    u.weight = (1 - λ) * u.weight + λ * (u.raw_weight / sum(raw_weights))

// 4. Renormalize
total = sum(weights for role r)
for each variant u in role r:
    u.weight /= total
```

**Parameters:**
- `α = 0.3` — fitness EMA smoothing. Balances recency vs. stability.
- `β = 5.0` — softmax temperature. Higher = more exploitative (concentrates weight on high-fitness variants). Lower = more exploratory (flatter distribution).
- `λ = 0.4` — continuity rate. Controls how fast weights can change per step. At 0.4, weights can shift at most 40% toward the softmax-implied distribution per generation. This is the **continuity-preserving** mechanism from weighted frames.

### Fitness Function

Fitness is a composite score derived from telemetry:

```
fitness = w_success * success
        + w_cost    * (1.0 - clamp(cost_usd / budget_ceiling, 0, 1))
        + w_speed   * (1.0 - clamp(wall_ms / time_ceiling, 0, 1))
        + w_errors  * (1.0 - clamp(errors / 3.0, 0, 1))
```

**Default weights (tunable in `[evolution]` config):**

| Component | Weight | Rationale |
|-----------|--------|-----------|
| `w_success` | 0.5 | Binary: did the worker produce a useful result? Dominant signal. |
| `w_cost` | 0.2 | Token cost relative to budget. Prevents expensive-but-marginal variants. |
| `w_speed` | 0.15 | Wall-clock time. Rewards faster completion. |
| `w_errors` | 0.15 | Error count. Penalizes tool failures and retries. |

### Selection at Runtime (in `prompts.zig:assemble()`)

When assembling a prompt for a worker:

```zig
// In assemble(), replace static role lookup with:
if (archive.sample(role_name)) |variant| {
    role_prompt = variant.body;
    // Tag the worker with variant.id for telemetry attribution
} else {
    // Fallback to static prompt (archive empty or not initialized)
    role_prompt = roles.getRole(role_name).system_prompt;
}
```

Selection is **weighted random**: `sample()` draws from the categorical distribution defined by variant weights. This means:
- High-weight variants are selected more often (exploitation)
- Low-weight variants are still occasionally selected (exploration)
- No variant is ever completely excluded unless its weight reaches zero (continuity)

### Minimum Weight Floor

To prevent premature convergence, no variant's weight can drop below `ε = 0.02`. If a role has 10 variants, the minimum per-variant probability is 2%. This ensures every variant gets at least occasional deployment, enabling the system to detect if a previously-poor variant has become viable due to distribution shift.

---

## 7. Robustness Rationale

### Why Weighted Archives Beat Single-Best Selection

| Property | Single-Best | Weighted Archive |
|----------|-------------|-----------------|
| Task distribution shift | Catastrophic regression | Graceful reweighting |
| New variant introduction | All-or-nothing replacement | Gradual weight gain |
| Coverage of behavioral space | Single point | Full grid coverage |
| Sensitivity to noise | High (one bad run can dethrone) | Low (EMA smoothing) |
| Recovery from bad mutations | Requires rollback mechanism | Automatic (weight → 0) |

### Continuity Guarantee

The λ-blending in the weight update rule provides a **Lipschitz continuity** bound on how fast the selection distribution can change:

```
‖w(t+1) - w(t)‖₁ ≤ 2λ
```

With λ = 0.4, the total variation distance between consecutive selection distributions is at most 0.8. In practice, because the softmax output is correlated with previous weights (fitness changes slowly via EMA), actual shifts are much smaller.

### Failure Modes and Mitigations

| Failure Mode | Detection | Mitigation |
|-------------|-----------|------------|
| All variants converge to same body | Pairwise text similarity > 0.95 | Inject random constraint mutations |
| Archive bloat (too many variants) | `variants.len > 256` per role | Prune: remove lowest-weight variants below ε threshold for > 10 generations |
| Mutation quality collapse | Child fitness consistently < parent | Reduce mutation rate; increase rephrase % |
| Fitness signal too noisy | High variance in ema_fitness | Increase α (more smoothing); require min 5 evals before weight update |
| Stale archive (no evolution triggers) | `generation` unchanged for > 100 swarm runs | Auto-trigger evolution every N runs |

### Safety Invariants

1. **Backward compatibility**: If no archive exists, `assemble()` falls back to static `roles.zig` prompts. Zero behavior change for users who don't opt in.
2. **Prompt validity**: All mutations preserve the basic structure (instructions for a coding agent). The meta-prompt for LLM-based mutations explicitly constrains output format.
3. **Cost bounded**: Max 4 mutations per role per generation × ~$0.0003/mutation = $0.0012/generation for 12 roles. Negligible vs. swarm execution cost.
4. **Deterministic replay**: Archive snapshots + RNG seed enable reproducible selection for debugging.

---

## 8. The Meta-Loop: Swarm → Telemetry → Evolve → Repeat

### Phase-by-Phase Flow

```
                    ┌─────────────────────────────────┐
                    │          SWARM EXECUTION         │
                    │                                   │
                    │  1. Load archive (or seed from    │
                    │     roles.zig on first run)       │
                    │  2. For each worker:              │
                    │     a. Sample variant from archive │
                    │     b. Tag WorkerMetrics with      │
                    │        variant_id                  │
                    │     c. Execute worker              │
                    │  3. Collect WorkerMetrics          │
                    └──────────────┬────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────────┐
                    │       TELEMETRY INGESTION        │
                    │                                   │
                    │  4. For each WorkerMetrics:       │
                    │     a. Compute fitness score      │
                    │     b. Compute behavioral         │
                    │        descriptors                │
                    │     c. Update variant's           │
                    │        ema_fitness + descriptor   │
                    │     d. Migrate variant if cell    │
                    │        changed                    │
                    └──────────────┬────────────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────────┐
                    │         EVOLUTION STEP            │
                    │  (triggered every K swarm runs    │
                    │   or when fitness variance is     │
                    │   above threshold)                │
                    │                                   │
                    │  5. For each role:                │
                    │     a. Reweight all variants      │
                    │        (softmax + λ-blend)        │
                    │     b. Prune dead variants        │
                    │        (weight < ε for >10 gen)   │
                    │     c. Select parents for         │
                    │        mutation                   │
                    │     d. Apply mutation operators    │
                    │        (max 4 per role)            │
                    │     e. Insert children into       │
                    │        archive with initial       │
                    │        weights                    │
                    │  6. Increment generation counter  │
                    │  7. Persist archive to            │
                    │     .devswarm/archive.json        │
                    └──────────────┬────────────────────┘
                                   │
                                   ▼
                              (next swarm run
                               samples from
                               updated archive)
```

### Trigger Policy

Evolution does **not** run after every swarm execution. Trigger conditions:

```
trigger_evolution = (
    swarm_runs_since_last_evolution >= K          // K = 5 by default
    OR max_fitness_variance_across_roles > 0.1    // high variance = rapid learning opportunity
)
AND total_evals_this_generation >= MIN_EVALS       // MIN_EVALS = 10; don't evolve on sparse data
```

### Telemetry Extensions

The existing `WorkerMetrics` struct gains two fields:

```zig
// Added to WorkerMetrics in telemetry.zig:
variant_id: ?u64 = null,    // which prompt variant was used (null = static prompt)
fitness: ?f64 = null,       // computed fitness score (null = not yet computed)
```

These are **optional** and backward-compatible — existing telemetry consumers ignore unknown fields.

### Config Section

```toml
[evolution]
enabled = true                  # master switch
archive_path = ".devswarm/archive.json"
trigger_interval = 5            # evolve every N swarm runs
min_evals_per_generation = 10   # minimum data points before evolving
mutations_per_role = 4          # max mutations per role per generation
softmax_temperature = 5.0       # β — exploitation vs exploration
continuity_rate = 0.4           # λ — weight update speed
fitness_ema_alpha = 0.3         # α — fitness smoothing
min_weight = 0.02               # ε — weight floor
mutation_model = "haiku"        # model for LLM-based mutations
```

### Integration with Existing Architecture

**Minimal invasion.** The design touches existing code at exactly three points:

1. **`runtime/prompts.zig:assemble()`** — Add archive lookup before static role fallback (3 lines changed)
2. **`telemetry.zig:WorkerMetrics`** — Add `variant_id: ?u64` field (1 line added)
3. **`swarm.zig:workerFn`** — Pass sampled `variant_id` into WorkerMetrics (2 lines added)

Everything else lives in new files (`runtime/archive.zig`, `runtime/evolve.zig`) and the config extension.

### Implementation Order

| Step | Files | Acceptance Criteria |
|------|-------|-------------------|
| 1. Archive data structures | `runtime/archive.zig` | Compiles; seed from roles.zig; sample returns static prompts; round-trip JSON serialization |
| 2. Telemetry attribution | `telemetry.zig`, `swarm.zig` | WorkerMetrics carries variant_id; JSON output includes it |
| 3. Prompt assembly integration | `runtime/prompts.zig` | `assemble()` samples from archive when available; falls back to static |
| 4. Fitness + descriptor computation | `runtime/archive.zig` | Fitness scores match expected values for known telemetry inputs |
| 5. Weight update (softmax + λ-blend) | `runtime/archive.zig` | Weights sum to 1.0; continuity bound holds; min weight ≥ ε |
| 6. Mutation operators | `runtime/evolve.zig` | Each operator produces valid prompt text; lineage tracked |
| 7. Evolution trigger + meta-loop | `runtime/evolve.zig`, `swarm.zig` | Evolution fires at configured intervals; archive persists across runs |
| 8. Config integration | `config.zig` | All parameters configurable; defaults match this document |

---

## 9. Summary of Key Design Decisions

| Decision | Choice | Alternative Considered | Why |
|----------|--------|----------------------|-----|
| Archive structure | Weighted grid (MAP-Elites + weighted frames) | Single ranked list | Grid preserves behavioral diversity; weights preserve continuity |
| Selection | Weighted random sampling | Argmax (pick best) | Distributional selection avoids discontinuous jumps per Dym et al. |
| Fitness | Composite (success + cost + speed + errors) | Success only | Multi-objective captures the full quality picture |
| Behavioral axes | Token efficiency × Thoroughness | Single axis (fitness only) | Two axes capture the fundamental fast-vs-deep tradeoff |
| Weight update | Softmax + λ-blending | Raw softmax | λ-blend provides Lipschitz continuity bound |
| Mutation source | LLM meta-calls (Haiku) | Template-based string ops | LLM understands prompt semantics; template ops produce gibberish |
| Persistence | JSON file in `.devswarm/` | SQLite | JSON is human-readable, diffable, and zero-dependency |
| Evolution trigger | Interval + variance threshold | Every run / manual only | Balances data efficiency with compute budget |

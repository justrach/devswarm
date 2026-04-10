// evolver.zig — MAP-Elites evolutionary prompt optimiser for devswarm.
//
// Architecture:
//   BehaviorDescriptor  — 2-D execution characterisation (token_efficiency, thoroughness)
//   PromptVariant       — a prompt candidate with lineage, fitness, and behavior
//   EvaluationResult    — raw outcome of one agent execution
//   Archive             — per-role 8×8 MAP-Elites grid: insert / sample / best / persist
//
// Core functions:
//   computeFitness        — WorkerMetrics → f64 ∈ [0, 1]
//   weightedSelect        — softmax-weighted sample from a role's cells
//   resolvePromptForRole  — convenience: sampled prompt string or null

const std = @import("std");

// ── WorkerMetrics ──────────────────────────────────────────────────────────────
// Mirrors telemetry.WorkerMetrics field-for-field so callers can pass either.
// Keep in sync with src/telemetry.zig:WorkerMetrics.

pub const WorkerMetrics = struct {
    worker_id: u32,
    role: []const u8,
    model: []const u8,
    tool_calls: u32 = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    wall_ms: u64 = 0,
    errors: u32 = 0,
    success: bool = false,
};

// ── Constants ──────────────────────────────────────────────────────────────────

pub const GRID_SIZE: usize = 8;
const SOFTMAX_TEMP: f64 = 1.0;

// ── Core types ─────────────────────────────────────────────────────────────────

/// 2-D behavior descriptor; both fields should be normalised to [0, 1].
///   token_efficiency — 1 = achieved the task with very few tokens
///   thoroughness     — 1 = used many tool-calls / searched broadly
pub const BehaviorDescriptor = struct {
    token_efficiency: f32,
    thoroughness: f32,

    /// Map descriptor to an (x, y) MAP-Elites cell, each in [0, GRID_SIZE-1].
    pub fn gridCell(self: BehaviorDescriptor) struct { x: usize, y: usize } {
        return .{
            .x = quantize(self.token_efficiency),
            .y = quantize(self.thoroughness),
        };
    }
};

pub const PromptVariant = struct {
    id: u64,
    role: []const u8,
    prompt: []const u8,
    parent_id: ?u64,
    fitness: f64,
    generation: u32,
    eval_count: u32,
    behavior: BehaviorDescriptor,
};

/// A code-patch organism: a candidate solution to a coding problem.
pub const Organism = struct {
    id: u64,
    parent_id: ?u64 = null,
    parent_ids: ?[]const u64 = null,
    generation: u32 = 0,
    explanation: []const u8 = "",
    diff: []const u8 = "",
    fitness: f64 = 0.0,
    problem_hash: []const u8 = "",
};

pub const FailureCase = struct {
    test_name: []const u8,
    snippet: []const u8,
};

pub const EvaluationResult = struct {
    success: bool,
    tokens_in: u64,
    tokens_out: u64,
    wall_ms: u64,
    tool_calls: u32,
    errors: u32,
};

// ── Archive ────────────────────────────────────────────────────────────────────

const RoleGrid = struct {
    cells: [GRID_SIZE][GRID_SIZE]?PromptVariant,
};

fn emptyGrid() RoleGrid {
    var g: RoleGrid = undefined;
    for (&g.cells) |*row| {
        for (row) |*cell| cell.* = null;
    }
    return g;
}

/// Per-role 8×8 MAP-Elites archive backed by JSON at `.devswarm/archive.json`.
pub const Archive = struct {
    alloc: std.mem.Allocator,
    grids: std.StringHashMap(RoleGrid),

    pub fn init(alloc: std.mem.Allocator) Archive {
        return .{
            .alloc = alloc,
            .grids = std.StringHashMap(RoleGrid).init(alloc),
        };
    }

    pub fn deinit(self: *Archive) void {
        var it = self.grids.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            for (&entry.value_ptr.cells) |*row| {
                for (row) |*cell| {
                    if (cell.*) |v| {
                        self.alloc.free(v.role);
                        self.alloc.free(v.prompt);
                    }
                }
            }
        }
        self.grids.deinit();
    }

    /// Insert variant into its MAP-Elites cell.
    /// Accepts only when the cell is empty or the new variant has strictly higher fitness.
    /// Returns true when the cell was written.
    pub fn insert(self: *Archive, variant: PromptVariant) !bool {
        const pos = variant.behavior.gridCell();

        if (!self.grids.contains(variant.role)) {
            const owned_key = try self.alloc.dupe(u8, variant.role);
            errdefer self.alloc.free(owned_key);
            try self.grids.put(owned_key, emptyGrid());
        }

        const grid = self.grids.getPtr(variant.role).?;
        const cell = &grid.cells[pos.x][pos.y];

        if (cell.*) |existing| {
            if (variant.fitness <= existing.fitness) return false;
            self.alloc.free(existing.role);
            self.alloc.free(existing.prompt);
        }

        var v = variant;
        v.role = try self.alloc.dupe(u8, variant.role);
        errdefer self.alloc.free(v.role);
        v.prompt = try self.alloc.dupe(u8, variant.prompt);
        cell.* = v;
        return true;
    }

    /// Pointer to highest-fitness variant for role, or null.
    pub fn bestForRole(self: *Archive, role: []const u8) ?*PromptVariant {
        const grid = self.grids.getPtr(role) orelse return null;
        var best: ?*PromptVariant = null;
        for (&grid.cells) |*row| {
            for (row) |*cell| {
                if (cell.*) |*v| {
                    if (best == null or v.fitness > best.?.fitness) best = v;
                }
            }
        }
        return best;
    }

    /// Count non-empty cells for role.
    pub fn countForRole(self: *Archive, role: []const u8) usize {
        const grid = self.grids.getPtr(role) orelse return 0;
        var n: usize = 0;
        for (grid.cells) |row| {
            for (row) |cell| {
                if (cell != null) n += 1;
            }
        }
        return n;
    }

    /// Serialise archive to a JSON file at path.
    pub fn save(self: *Archive, path: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, "{\"variants\":[");
        var first = true;
        var it = self.grids.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.cells) |row| {
                for (row) |maybe| {
                    if (maybe) |v| {
                        if (!first) try buf.append(self.alloc, ',');
                        first = false;
                        try appendVariantJson(self.alloc, &buf, v);
                    }
                }
            }
        }
        try buf.appendSlice(self.alloc, "]}");

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(buf.items);
    }

    /// Load archive from JSON file at path.  No-op if file is absent.
    pub fn load(self: *Archive, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.alloc, 8 * 1024 * 1024);
        defer self.alloc.free(data);
        try self.loadSlice(data);
    }

    /// Parse and merge variants from a JSON byte slice (also used by tests).
    pub fn loadSlice(self: *Archive, json_str: []const u8) !void {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.alloc,
            json_str,
            .{},
        );
        defer parsed.deinit();

        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const variants_val = root_obj.get("variants") orelse return;
        const items = switch (variants_val) {
            .array => |a| a.items,
            else => return,
        };

        for (items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const id: u64 = @intCast(jInt(obj.get("id") orelse continue));
            const role = jStr(obj.get("role") orelse continue);
            const prompt_s = jStr(obj.get("prompt") orelse continue);
            const parent_id: ?u64 = blk: {
                const pv = obj.get("parent_id") orelse break :blk null;
                break :blk switch (pv) {
                    .null => null,
                    .integer => |i| @as(u64, @intCast(i)),
                    else => null,
                };
            };
            const fitness = jFloat(obj.get("fitness") orelse continue);
            const generation: u32 = @intCast(jInt(obj.get("generation") orelse continue));
            const eval_count: u32 = @intCast(jInt(obj.get("eval_count") orelse continue));
            const beh_val = obj.get("behavior") orelse continue;
            const beh_obj = switch (beh_val) {
                .object => |o| o,
                else => continue,
            };
            const tok_eff: f32 = @floatCast(
                jFloat(beh_obj.get("token_efficiency") orelse continue),
            );
            const thorough: f32 = @floatCast(
                jFloat(beh_obj.get("thoroughness") orelse continue),
            );
            const v = PromptVariant{
                .id = id,
                .role = role,
                .prompt = prompt_s,
                .parent_id = parent_id,
                .fitness = fitness,
                .generation = generation,
                .eval_count = eval_count,
                .behavior = .{ .token_efficiency = tok_eff, .thoroughness = thorough },
            };
            _ = try self.insert(v);
        }
    }
};

// ── CrossoverMutator (#154) ───────────────────────────────────────────────────
//
// Multi-parent synthesis: builds a prompt showing top-K parent organisms,
// asks the LLM to combine their best insights into a single improved patch.

/// Build a crossover prompt from multiple parent organisms.
pub fn buildCrossoverPrompt(
    alloc: std.mem.Allocator,
    problem: []const u8,
    parents: []const Organism,
    history: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);

    try w.writeAll("Problem:\n");
    try w.writeAll(if (problem.len > 1000) problem[0..1000] else problem);
    try w.writeAll("\n\nTop-performing solutions so far:\n");

    for (parents, 0..) |p, i| {
        var idx_buf: [64]u8 = undefined;
        const idx_s = std.fmt.bufPrint(&idx_buf, "\n  [Parent {d} — fitness {:.3}]\n", .{ i + 1, p.fitness }) catch "\n  [Parent]\n";
        try w.writeAll(idx_s);
        try w.writeAll("  Explanation: ");
        try w.writeAll(if (p.explanation.len > 400) p.explanation[0..400] else p.explanation);
        try w.writeAll("\n  Diff:\n");
        try w.writeAll(if (p.diff.len > 2000) p.diff[0..2000] else p.diff);
        try w.writeAll("\n");
    }

    if (history.len > 0) {
        try w.writeAll("\nPast attempts:\n");
        try w.writeAll(if (history.len > 2000) history[0..2000] else history);
        try w.writeAll("\n");
    }

    try w.writeAll(
        \\
        \\Synthesize the best insights from all solutions into a single improved patch.
        \\Explain what you're combining and why.
        \\
        \\Respond with EXACTLY this format:
        \\
        \\EXPLANATION:
        \\<your explanation here>
        \\
        \\DIFF:
        \\```diff
        \\<your unified diff here>
        \\```
    );

    return buf.toOwnedSlice(alloc);
}

/// Parse LLM response to extract explanation and diff sections.
pub fn parseMutationResponse(response: []const u8) ?struct { explanation: []const u8, diff: []const u8 } {
    const expl_start = std.mem.indexOf(u8, response, "EXPLANATION:") orelse return null;
    const expl_body_start = expl_start + "EXPLANATION:".len;

    const diff_marker = std.mem.indexOf(u8, response[expl_body_start..], "DIFF:") orelse return null;
    const explanation = std.mem.trim(u8, response[expl_body_start .. expl_body_start + diff_marker], " \t\r\n");

    const diff_section_start = expl_body_start + diff_marker + "DIFF:".len;
    const diff_content = std.mem.trim(u8, response[diff_section_start..], " \t\r\n");

    const stripped = blk: {
        if (std.mem.startsWith(u8, diff_content, "```diff")) {
            const inner_start = std.mem.indexOf(u8, diff_content, "\n") orelse break :blk diff_content;
            if (std.mem.lastIndexOf(u8, diff_content, "```")) |end| {
                if (end > inner_start) {
                    break :blk std.mem.trim(u8, diff_content[inner_start + 1 .. end], " \t\r\n");
                }
            }
            break :blk std.mem.trim(u8, diff_content[inner_start + 1 ..], " \t\r\n");
        }
        if (std.mem.startsWith(u8, diff_content, "```")) {
            const inner_start = std.mem.indexOf(u8, diff_content, "\n") orelse break :blk diff_content;
            if (std.mem.lastIndexOf(u8, diff_content, "```")) |end| {
                if (end > inner_start) {
                    break :blk std.mem.trim(u8, diff_content[inner_start + 1 .. end], " \t\r\n");
                }
            }
        }
        break :blk diff_content;
    };

    if (stripped.len == 0) return null;
    return .{ .explanation = explanation, .diff = stripped };
}

pub const CrossoverMutator = struct {
    k: u32,
    model: []const u8,
    alloc: std.mem.Allocator,
    next_id: u64 = 2000,

    pub fn init(alloc: std.mem.Allocator, model: []const u8, k: u32) CrossoverMutator {
        return .{ .k = k, .model = model, .alloc = alloc };
    }

    /// Create a child organism by combining the top-K parents.
    /// In production this calls the LLM; prompt and parsing are testable separately.
    pub fn crossover(
        self: *CrossoverMutator,
        parents: []const Organism,
        history: []const u8,
        problem: []const u8,
    ) !Organism {
        const count = @min(parents.len, @as(usize, self.k));
        if (count == 0) return error.NoParents;

        const prompt = try buildCrossoverPrompt(self.alloc, problem, parents[0..count], history);
        defer self.alloc.free(prompt);

        // Placeholder: in production, this calls the LLM.
        const id = self.next_id;
        self.next_id += 1;

        var parent_ids = try self.alloc.alloc(u64, count);
        for (parents[0..count], 0..) |p, i| parent_ids[i] = p.id;

        return Organism{
            .id = id,
            .parent_id = parents[0].id,
            .parent_ids = parent_ids,
            .generation = parents[0].generation + 1,
            .explanation = "crossover pending LLM integration",
            .diff = "",
            .fitness = 0.0,
            .problem_hash = parents[0].problem_hash,
        };
    }
};

// ── Core functions ─────────────────────────────────────────────────────────────

/// Compute fitness ∈ [0, 1] from a worker's execution metrics.
/// Formula: 0.5 * success + 0.2 * cost_efficiency + 0.15 * speed + 0.15 * (1 - error_rate)
pub fn computeFitness(metrics: WorkerMetrics) f64 {
    const success: f64 = if (metrics.success) 1.0 else 0.0;

    // cost_efficiency: total tokens proxy; ≥200 K tokens → 0.
    const total_tok = metrics.tokens_in + metrics.tokens_out;
    const cost_eff = std.math.clamp(
        1.0 - @as(f64, @floatFromInt(total_tok)) / 200_000.0,
        0.0,
        1.0,
    );

    // speed: ≥60 s wall time → 0.
    const speed = std.math.clamp(
        1.0 - @as(f64, @floatFromInt(metrics.wall_ms)) / 60_000.0,
        0.0,
        1.0,
    );

    // error_rate = errors / max(1, tool_calls), clamped to [0, 1].
    const denom: f64 = @floatFromInt(@max(1, metrics.tool_calls));
    const err_rate = std.math.clamp(
        @as(f64, @floatFromInt(metrics.errors)) / denom,
        0.0,
        1.0,
    );

    return 0.5 * success + 0.2 * cost_eff + 0.15 * speed + 0.15 * (1.0 - err_rate);
}

/// Softmax-weighted sample over all non-empty cells for role.
/// Returns null when the role has no archive entries.
pub fn weightedSelect(
    archive: *Archive,
    role: []const u8,
    rng: std.Random,
) ?*PromptVariant {
    const grid = archive.grids.getPtr(role) orelse return null;

    var ptrs: [GRID_SIZE * GRID_SIZE]*PromptVariant = undefined;
    var n: usize = 0;
    for (&grid.cells) |*row| {
        for (row) |*cell| {
            if (cell.* != null) {
                ptrs[n] = &cell.*.?;
                n += 1;
            }
        }
    }
    if (n == 0) return null;
    if (n == 1) return ptrs[0];

    // Subtract max fitness for numerical stability before exponentiation.
    var max_f: f64 = ptrs[0].fitness;
    for (ptrs[0..n]) |p| if (p.fitness > max_f) {
        max_f = p.fitness;
    };

    var weights: [GRID_SIZE * GRID_SIZE]f64 = undefined;
    var total: f64 = 0.0;
    for (ptrs[0..n], 0..) |p, i| {
        weights[i] = std.math.exp((p.fitness - max_f) / SOFTMAX_TEMP);
        total += weights[i];
    }

    const r = rng.float(f64) * total;
    var cum: f64 = 0.0;
    for (ptrs[0..n], 0..) |p, i| {
        cum += weights[i];
        if (r <= cum) return p;
    }
    return ptrs[n - 1];
}

/// Return a sampled prompt string for role, or null if archive is empty for that role.
pub fn resolvePromptForRole(
    archive: *Archive,
    role: []const u8,
    rng: std.Random,
) ?[]const u8 {
    return if (weightedSelect(archive, role, rng)) |v| v.prompt else null;
}

// ── Internal helpers ───────────────────────────────────────────────────────────

fn quantize(v: f32) usize {
    const c = if (v < 0.0) @as(f32, 0.0) else if (v > 1.0) @as(f32, 1.0) else v;
    const idx: usize = @intFromFloat(c * @as(f32, @floatFromInt(GRID_SIZE)));
    return if (idx >= GRID_SIZE) GRID_SIZE - 1 else idx;
}

fn appendVariantJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), v: PromptVariant) !void {
    var tmp: [64]u8 = undefined;

    try buf.appendSlice(alloc, "{\"id\":");
    try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{v.id}) catch return error.OutOfMemory);
    try buf.appendSlice(alloc, ",\"role\":\"");
    try appendEscaped(alloc, buf, v.role);
    try buf.appendSlice(alloc, "\",\"prompt\":\"");
    try appendEscaped(alloc, buf, v.prompt);
    try buf.appendSlice(alloc, "\",\"parent_id\":");
    if (v.parent_id) |p| {
        try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{p}) catch return error.OutOfMemory);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"fitness\":");
    try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d:.6}", .{v.fitness}) catch return error.OutOfMemory);
    try buf.appendSlice(alloc, ",\"generation\":");
    try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{v.generation}) catch return error.OutOfMemory);
    try buf.appendSlice(alloc, ",\"eval_count\":");
    try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d}", .{v.eval_count}) catch return error.OutOfMemory);
    try buf.appendSlice(alloc, ",\"behavior\":{\"token_efficiency\":");
    try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d:.6}", .{v.behavior.token_efficiency}) catch return error.OutOfMemory);
    try buf.appendSlice(alloc, ",\"thoroughness\":");
    try buf.appendSlice(alloc, std.fmt.bufPrint(&tmp, "{d:.6}", .{v.behavior.thoroughness}) catch return error.OutOfMemory);
    try buf.appendSlice(alloc, "}}");
}

fn appendEscaped(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var tmp: [8]u8 = undefined;
                const s2 = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(alloc, s2);
            },
            else => try buf.append(alloc, c),
        }
    }
}

fn jInt(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn jFloat(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

fn jStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "evolver: BehaviorDescriptor quantizes to correct grid cell" {
    // 0.0 * 8 = 0
    const a = BehaviorDescriptor{ .token_efficiency = 0.0, .thoroughness = 0.0 };
    const ca = a.gridCell();
    try std.testing.expectEqual(@as(usize, 0), ca.x);
    try std.testing.expectEqual(@as(usize, 0), ca.y);

    // 0.5 * 8 = 4
    const b = BehaviorDescriptor{ .token_efficiency = 0.5, .thoroughness = 0.5 };
    const cb = b.gridCell();
    try std.testing.expectEqual(@as(usize, 4), cb.x);
    try std.testing.expectEqual(@as(usize, 4), cb.y);

    // 0.125 * 8 = 1,  0.875 * 8 = 7
    const c = BehaviorDescriptor{ .token_efficiency = 0.125, .thoroughness = 0.875 };
    const cc = c.gridCell();
    try std.testing.expectEqual(@as(usize, 1), cc.x);
    try std.testing.expectEqual(@as(usize, 7), cc.y);
}

test "evolver: BehaviorDescriptor extreme values clamp to valid cells" {
    const hi = BehaviorDescriptor{ .token_efficiency = 1.0, .thoroughness = 1.5 };
    const chi = hi.gridCell();
    try std.testing.expectEqual(@as(usize, GRID_SIZE - 1), chi.x);
    try std.testing.expectEqual(@as(usize, GRID_SIZE - 1), chi.y);

    const lo = BehaviorDescriptor{ .token_efficiency = -0.5, .thoroughness = -1.0 };
    const clo = lo.gridCell();
    try std.testing.expectEqual(@as(usize, 0), clo.x);
    try std.testing.expectEqual(@as(usize, 0), clo.y);
}

test "evolver: archive insert into empty cell" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    const ok = try ar.insert(.{
        .id = 1,
        .role = "finder",
        .prompt = "Search thoroughly",
        .parent_id = null,
        .fitness = 0.7,
        .generation = 0,
        .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.5, .thoroughness = 0.5 },
    });
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), ar.countForRole("finder"));
}

test "evolver: archive insert improves fitness replaces existing" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    const beh = BehaviorDescriptor{ .token_efficiency = 0.5, .thoroughness = 0.5 };
    _ = try ar.insert(.{
        .id = 1, .role = "fixer", .prompt = "old",
        .parent_id = null, .fitness = 0.4, .generation = 0, .eval_count = 1,
        .behavior = beh,
    });
    const replaced = try ar.insert(.{
        .id = 2, .role = "fixer", .prompt = "new",
        .parent_id = 1, .fitness = 0.8, .generation = 1, .eval_count = 1,
        .behavior = beh,
    });
    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(usize, 1), ar.countForRole("fixer"));
    try std.testing.expectEqualStrings("new", ar.bestForRole("fixer").?.prompt);
}

test "evolver: archive insert regresses fitness is rejected" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    const beh = BehaviorDescriptor{ .token_efficiency = 0.5, .thoroughness = 0.5 };
    _ = try ar.insert(.{
        .id = 1, .role = "reviewer", .prompt = "good",
        .parent_id = null, .fitness = 0.9, .generation = 0, .eval_count = 1,
        .behavior = beh,
    });
    const rejected = try ar.insert(.{
        .id = 2, .role = "reviewer", .prompt = "worse",
        .parent_id = 1, .fitness = 0.5, .generation = 1, .eval_count = 1,
        .behavior = beh,
    });
    try std.testing.expect(!rejected);
    try std.testing.expectEqualStrings("good", ar.bestForRole("reviewer").?.prompt);
}

test "evolver: archive bestForRole returns highest fitness across cells" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    _ = try ar.insert(.{
        .id = 1, .role = "architect", .prompt = "ok",
        .parent_id = null, .fitness = 0.3, .generation = 0, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.1, .thoroughness = 0.1 },
    });
    _ = try ar.insert(.{
        .id = 2, .role = "architect", .prompt = "best",
        .parent_id = null, .fitness = 0.95, .generation = 1, .eval_count = 2,
        .behavior = .{ .token_efficiency = 0.9, .thoroughness = 0.9 },
    });
    _ = try ar.insert(.{
        .id = 3, .role = "architect", .prompt = "mid",
        .parent_id = null, .fitness = 0.6, .generation = 1, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.5, .thoroughness = 0.1 },
    });

    const best = ar.bestForRole("architect").?;
    try std.testing.expectEqualStrings("best", best.prompt);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), best.fitness, 1e-9);
    try std.testing.expectEqual(@as(?*PromptVariant, null), ar.bestForRole("nonexistent"));
}

test "evolver: computeFitness success case" {
    const m = WorkerMetrics{
        .worker_id = 0, .role = "fixer", .model = "claude-sonnet-4-6",
        .success = true, .tokens_in = 1000, .tokens_out = 500,
        .wall_ms = 3000, .tool_calls = 5, .errors = 0,
    };
    const f = computeFitness(m);
    try std.testing.expect(f > 0.9);
    try std.testing.expect(f <= 1.0);
}

test "evolver: computeFitness failure case" {
    // success=0, cost_eff=1, speed=1, err_rate=0  →  0 + 0.2 + 0.15 + 0.15 = 0.5
    const m = WorkerMetrics{
        .worker_id = 0, .role = "finder", .model = "claude-sonnet-4-6",
        .success = false, .tokens_in = 0, .tokens_out = 0,
        .wall_ms = 0, .tool_calls = 0, .errors = 0,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), computeFitness(m), 1e-9);
}

test "evolver: computeFitness error rate reduces score" {
    const base = WorkerMetrics{
        .worker_id = 0, .role = "monitor", .model = "claude-sonnet-4-6",
        .success = true, .tokens_in = 0, .tokens_out = 0,
        .wall_ms = 0, .tool_calls = 4, .errors = 0,
    };
    var errored = base;
    errored.errors = 4; // error_rate = 1.0
    try std.testing.expect(computeFitness(errored) < computeFitness(base));
}

test "evolver: computeFitness clamping" {
    // Extreme values must not produce fitness outside [0, 1].
    const m = WorkerMetrics{
        .worker_id = 0, .role = "fixer", .model = "claude-sonnet-4-6",
        .success = false, .tokens_in = 10_000_000, .tokens_out = 10_000_000,
        .wall_ms = 999_999_999, .tool_calls = 1, .errors = 999,
    };
    const f = computeFitness(m);
    try std.testing.expect(f >= 0.0);
    try std.testing.expect(f <= 1.0);
}

test "evolver: weightedSelect empty role returns null" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    try std.testing.expectEqual(
        @as(?*PromptVariant, null),
        weightedSelect(&ar, "finder", prng.random()),
    );
}

test "evolver: weightedSelect with single variant always returns it" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    _ = try ar.insert(.{
        .id = 7, .role = "synthesizer", .prompt = "only one",
        .parent_id = null, .fitness = 0.5, .generation = 0, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.5, .thoroughness = 0.5 },
    });

    var prng = std.Random.DefaultPrng.init(99);
    const rng = prng.random();
    for (0..20) |_| {
        const v = weightedSelect(&ar, "synthesizer", rng).?;
        try std.testing.expectEqualStrings("only one", v.prompt);
    }
}

test "evolver: weightedSelect biases toward higher fitness" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    _ = try ar.insert(.{
        .id = 1, .role = "explorer", .prompt = "low",
        .parent_id = null, .fitness = 0.2, .generation = 0, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.1, .thoroughness = 0.1 },
    });
    _ = try ar.insert(.{
        .id = 2, .role = "explorer", .prompt = "high",
        .parent_id = null, .fitness = 0.9, .generation = 0, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.9, .thoroughness = 0.9 },
    });

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    var high_count: usize = 0;
    for (0..1000) |_| {
        const v = weightedSelect(&ar, "explorer", rng).?;
        if (std.mem.eql(u8, v.prompt, "high")) high_count += 1;
    }
    // P("high") = exp(0)/(exp(0)+exp(-0.7)) ≈ 0.668; expect well above 50%.
    try std.testing.expect(high_count > 550);
}

test "evolver: resolvePromptForRole empty archive returns null" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        resolvePromptForRole(&ar, "orchestrator", prng.random()),
    );
}

test "evolver: resolvePromptForRole populated returns prompt" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    _ = try ar.insert(.{
        .id = 3, .role = "orchestrator", .prompt = "Decompose the task",
        .parent_id = null, .fitness = 0.6, .generation = 0, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.4, .thoroughness = 0.6 },
    });

    var prng = std.Random.DefaultPrng.init(7);
    const p = resolvePromptForRole(&ar, "orchestrator", prng.random());
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("Decompose the task", p.?);
}

test "evolver: PromptVariant JSON round-trip via loadSlice" {
    const alloc = std.testing.allocator;

    // Serialize one variant into the archive envelope.
    var snippet: std.ArrayList(u8) = .empty;
    defer snippet.deinit(alloc);
    try appendVariantJson(alloc, &snippet, PromptVariant{
        .id = 42,
        .role = "zig_specialist",
        .prompt = "Fix errdefer",
        .parent_id = 7,
        .fitness = 0.75,
        .generation = 3,
        .eval_count = 5,
        .behavior = .{ .token_efficiency = 0.6, .thoroughness = 0.4 },
    });

    var envelope: std.ArrayList(u8) = .empty;
    defer envelope.deinit(alloc);
    try envelope.appendSlice(alloc, "{\"variants\":[");
    try envelope.appendSlice(alloc, snippet.items);
    try envelope.appendSlice(alloc, "]}");

    var ar = Archive.init(alloc);
    defer ar.deinit();
    try ar.loadSlice(envelope.items);

    try std.testing.expectEqual(@as(usize, 1), ar.countForRole("zig_specialist"));
    const best = ar.bestForRole("zig_specialist").?;
    try std.testing.expectEqual(@as(u64, 42), best.id);
    try std.testing.expectEqual(@as(?u64, 7), best.parent_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), best.fitness, 1e-4);
    try std.testing.expectEqualStrings("Fix errdefer", best.prompt);
    try std.testing.expectEqual(@as(u32, 3), best.generation);
    try std.testing.expectEqual(@as(u32, 5), best.eval_count);
}

test "evolver: archive persistence file round-trip" {
    const alloc = std.testing.allocator;

    var ar1 = Archive.init(alloc);
    defer ar1.deinit();
    _ = try ar1.insert(.{
        .id = 10, .role = "test_writer", .prompt = "Write a failing test",
        .parent_id = null, .fitness = 0.88, .generation = 2, .eval_count = 3,
        .behavior = .{ .token_efficiency = 0.3, .thoroughness = 0.8 },
    });
    _ = try ar1.insert(.{
        .id = 11, .role = "test_writer", .prompt = "Cover edge cases",
        .parent_id = 10, .fitness = 0.55, .generation = 3, .eval_count = 1,
        .behavior = .{ .token_efficiency = 0.7, .thoroughness = 0.2 },
    });

    const tmp_path = "/tmp/_evolver_roundtrip_test.json";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try ar1.save(tmp_path);

    var ar2 = Archive.init(alloc);
    defer ar2.deinit();
    try ar2.load(tmp_path);

    try std.testing.expectEqual(@as(usize, 2), ar2.countForRole("test_writer"));
    const best = ar2.bestForRole("test_writer").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.88), best.fitness, 1e-4);
    try std.testing.expectEqualStrings("Write a failing test", best.prompt);
}

test "evolver: archive sampling across multiple roles" {
    const alloc = std.testing.allocator;
    var ar = Archive.init(alloc);
    defer ar.deinit();

    const roles = [_][]const u8{
        "finder", "reviewer", "fixer", "explorer", "architect",
        "orchestrator", "synthesizer", "monitor",
    };
    for (roles, 0..) |role, i| {
        _ = try ar.insert(.{
            .id = @intCast(i),
            .role = role,
            .prompt = role, // prompt equals role name for easy assertion
            .parent_id = null,
            .fitness = 0.5 + @as(f64, @floatFromInt(i)) * 0.01,
            .generation = 0,
            .eval_count = 1,
            .behavior = .{
                .token_efficiency = @as(f32, @floatFromInt(i)) / 16.0,
                .thoroughness = 0.5,
            },
        });
    }

    var prng = std.Random.DefaultPrng.init(123);
    const rng = prng.random();

    for (roles) |role| {
        const p = resolvePromptForRole(&ar, role, rng);
        try std.testing.expect(p != null);
        try std.testing.expectEqualStrings(role, p.?);
    }
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        resolvePromptForRole(&ar, "nonexistent_role", rng),
    );
}

// ── CrossoverMutator tests (#154) ────────────────────────────────────────────

test "evolver: buildCrossoverPrompt includes all parents" {
    const alloc = std.testing.allocator;
    const parents = [_]Organism{
        .{ .id = 1, .fitness = 0.7, .explanation = "Added null check", .diff = "--- a/x\n+++ b/x\n+check", .problem_hash = "h" },
        .{ .id = 2, .fitness = 0.6, .explanation = "Changed return type", .diff = "--- a/y\n+++ b/y\n+ret", .problem_hash = "h" },
        .{ .id = 3, .fitness = 0.5, .explanation = "Refactored loop", .diff = "--- a/z\n+++ b/z\n+loop", .problem_hash = "h" },
    };
    const prompt = try buildCrossoverPrompt(alloc, "Fix timeout bug", &parents, "");
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Parent 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Parent 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Parent 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "null check") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Changed return") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Refactored loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Synthesize") != null);
}

test "evolver: buildCrossoverPrompt with history" {
    const alloc = std.testing.allocator;
    const parents = [_]Organism{
        .{ .id = 1, .fitness = 0.8, .problem_hash = "h" },
    };
    const prompt = try buildCrossoverPrompt(alloc, "problem", &parents, "prev attempt failed");
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "prev attempt") != null);
}

test "evolver: parseMutationResponse valid" {
    const response =
        \\EXPLANATION:
        \\Combined null check with return type fix.
        \\
        \\DIFF:
        \\```diff
        \\--- a/src/auth.zig
        \\+++ b/src/auth.zig
        \\@@ -1 +1 @@
        \\-old
        \\+new
        \\```
    ;
    const parsed = parseMutationResponse(response) orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, parsed.explanation, "Combined") != null);
    try std.testing.expect(std.mem.startsWith(u8, parsed.diff, "--- a/src/auth.zig"));
}

test "evolver: parseMutationResponse returns null on garbage" {
    try std.testing.expect(parseMutationResponse("no structure here") == null);
}

test "evolver: CrossoverMutator.crossover creates child from parents" {
    const alloc = std.testing.allocator;
    var cm = CrossoverMutator.init(alloc, "claude-test", 3);
    const parents = [_]Organism{
        .{ .id = 10, .fitness = 0.9, .generation = 2, .problem_hash = "ph" },
        .{ .id = 20, .fitness = 0.7, .generation = 2, .problem_hash = "ph" },
    };
    const child = try cm.crossover(&parents, "", "fix it");
    defer alloc.free(child.parent_ids.?);

    try std.testing.expectEqual(@as(u64, 10), child.parent_id.?);
    try std.testing.expectEqual(@as(u32, 3), child.generation);
    try std.testing.expectEqual(@as(usize, 2), child.parent_ids.?.len);
    try std.testing.expectEqual(@as(u64, 10), child.parent_ids.?[0]);
    try std.testing.expectEqual(@as(u64, 20), child.parent_ids.?[1]);
}

test "evolver: CrossoverMutator.crossover caps at k parents" {
    const alloc = std.testing.allocator;
    var cm = CrossoverMutator.init(alloc, "test", 2);
    const parents = [_]Organism{
        .{ .id = 1, .fitness = 0.9, .generation = 1, .problem_hash = "x" },
        .{ .id = 2, .fitness = 0.8, .generation = 1, .problem_hash = "x" },
        .{ .id = 3, .fitness = 0.7, .generation = 1, .problem_hash = "x" },
    };
    const child = try cm.crossover(&parents, "", "problem");
    defer alloc.free(child.parent_ids.?);

    // k=2 so only first 2 parents should be used
    try std.testing.expectEqual(@as(usize, 2), child.parent_ids.?.len);
}

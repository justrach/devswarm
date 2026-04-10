// runtime/grid.zig — Model grid (#265)
//
// Static Role→Model mapping. The grid defines which model tier each role
// gets by default. resolve() uses this as one input in the resolution chain.
//
// Override hierarchy (highest priority first):
//   1. MCP param (model: "opus")
//   2. model_grid.toml override
//   3. Role config default
//   4. Mode default (smart→Sonnet, deep→Opus, etc.)
//   5. Grid tier (this file)
//   6. config.toml [defaults]
//   7. Hardcoded fallback (Sonnet)

const std = @import("std");
const types = @import("types.zig");
const AgentMode = types.AgentMode;

/// Model tier — abstract categories that map to concrete model IDs.
/// Model tier — abstract categories that map to concrete model IDs.
pub const ModelTier = enum {
    haiku,   // fast, cheap: Haiku
    sonnet,  // balanced: Sonnet
    opus,    // powerful: Opus
    spark,   // fast, cheap Codex: gpt-5.3-codex-spark
    bolt,    // OpenAI flagship: gpt-5.4

    pub fn toModelId(self: ModelTier) []const u8 {
        return switch (self) {
            .haiku  => "claude-haiku-4-5-20251001",
            .sonnet => "claude-sonnet-4-6",
            .opus   => "claude-opus-4-6",
            .spark  => "gpt-5.3-codex-spark",
            .bolt   => "gpt-5.4",
        };
    }

    pub fn fromString(s: []const u8) ?ModelTier {
        if (std.mem.eql(u8, s, "haiku"))  return .haiku;
        if (std.mem.eql(u8, s, "sonnet")) return .sonnet;
        if (std.mem.eql(u8, s, "opus"))   return .opus;
        if (std.mem.eql(u8, s, "spark"))  return .spark;
        if (std.mem.eql(u8, s, "bolt"))   return .bolt;
        return null;
    }
};

/// Grid entry: role name → recommended model tier.
const GridEntry = struct {
    role: []const u8,
    tier: ModelTier,
};

/// Default grid — can be overridden by model_grid.toml.
const default_grid = [_]GridEntry{
    // Orchestration
    .{ .role = "orchestrator",  .tier = .bolt },
    .{ .role = "synthesizer",   .tier = .sonnet },

    // Worker roles
    .{ .role = "finder",        .tier = .sonnet },
    .{ .role = "reviewer",      .tier = .sonnet },
    .{ .role = "fixer",         .tier = .sonnet },
    .{ .role = "explorer",      .tier = .sonnet },
    .{ .role = "architect",     .tier = .opus },

    // Specialist roles
    .{ .role = "safety_auditor", .tier = .opus },
    .{ .role = "zig_specialist", .tier = .sonnet },
    .{ .role = "api_reviewer",   .tier = .sonnet },
    .{ .role = "test_writer",    .tier = .sonnet },

    // Budget roles
    .{ .role = "monitor",       .tier = .haiku },
    .{ .role = "linter",        .tier = .haiku },
    .{ .role = "formatter",     .tier = .haiku },
};

/// Look up the grid tier for a role.  Returns null if the role isn't in the grid.
pub fn tierForRole(role: []const u8) ?ModelTier {
    for (default_grid) |entry| {
        if (std.mem.eql(u8, entry.role, role)) return entry.tier;
    }
    return null;
}

// ── Grid override file (.codedb/model_grid.toml) ─────────────────────────────

const MAX_OVERRIDES = 32;
const OVERRIDE_PATH = ".codedb/model_grid.toml";

pub const GridOverride = struct {
    role: []const u8,
    tier: ModelTier,
    rationale: []const u8,
};

var g_overrides: [MAX_OVERRIDES]GridOverride = undefined;
var g_override_count: usize = 0;
var g_overrides_loaded: bool = false;

/// Parse a minimal TOML-like override file. Supports:
///   [role_name]
///   model = "tier_name"
///   rationale = "reason"
pub fn parseOverrides(content: []const u8) struct { overrides: [MAX_OVERRIDES]GridOverride, count: usize } {
    var result: [MAX_OVERRIDES]GridOverride = undefined;
    var count: usize = 0;
    var current_role: ?[]const u8 = null;
    var current_rationale: []const u8 = "";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Section header: [role_name]
        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_role = line[1 .. line.len - 1];
            current_rationale = "";
            continue;
        }

        if (current_role == null) continue;

        // Key = "value"
        if (std.mem.indexOf(u8, line, "=")) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            // Strip surrounding quotes
            const val = if (raw_val.len >= 2 and raw_val[0] == '"' and raw_val[raw_val.len - 1] == '"')
                raw_val[1 .. raw_val.len - 1]
            else
                raw_val;

            if (std.mem.eql(u8, key, "model")) {
                if (ModelTier.fromString(val)) |tier| {
                    if (count < MAX_OVERRIDES) {
                        result[count] = .{
                            .role = current_role.?,
                            .tier = tier,
                            .rationale = current_rationale,
                        };
                        count += 1;
                    }
                }
            } else if (std.mem.eql(u8, key, "rationale")) {
                current_rationale = val;
                // Update the last entry's rationale if it matches this role
                if (count > 0 and std.mem.eql(u8, result[count - 1].role, current_role.?)) {
                    result[count - 1].rationale = val;
                }
            }
        }
    }

    return .{ .overrides = result, .count = count };
}

/// Load overrides from the file system. Caches after first load.
pub fn loadOverrides() void {
    if (g_overrides_loaded) return;
    g_overrides_loaded = true;

    const file = std.fs.cwd().openFile(OVERRIDE_PATH, .{}) catch return;
    defer file.close();

    var buf: [8192]u8 = undefined;
    const len = file.readAll(&buf) catch return;

    const parsed = parseOverrides(buf[0..len]);
    g_overrides = parsed.overrides;
    g_override_count = parsed.count;
}

/// Reset cached overrides (for testing).
pub fn resetOverrides() void {
    g_overrides_loaded = false;
    g_override_count = 0;
}

/// Look up override tier for a role.
pub fn overrideTierForRole(role: []const u8) ?ModelTier {
    loadOverrides();
    for (g_overrides[0..g_override_count]) |ov| {
        if (std.mem.eql(u8, ov.role, role)) return ov.tier;
    }
    return null;
}

/// Resolve the model ID for a given role + mode combination.
/// Priority: override file → role grid → mode default → fallback (Sonnet).
pub fn resolveModel(role: ?[]const u8, mode: AgentMode) []const u8 {
    if (role) |r| {
        // 1. Check override file (highest priority)
        if (overrideTierForRole(r)) |tier| {
            return tier.toModelId();
        }
        // 2. Check grid for role-specific tier
        if (tierForRole(r)) |tier| {
            return tier.toModelId();
        }
    }
    // 3. Fall back to mode default
    return mode.defaultModel();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "grid: tierForRole returns correct tiers" {
    try std.testing.expectEqual(ModelTier.bolt,   tierForRole("orchestrator").?);
    try std.testing.expectEqual(ModelTier.sonnet, tierForRole("finder").?);
    try std.testing.expectEqual(ModelTier.haiku,  tierForRole("monitor").?);
    try std.testing.expectEqual(@as(?ModelTier, null), tierForRole("unknown_role"));
}

test "grid: resolveModel uses grid for known roles" {
    try std.testing.expectEqualStrings("gpt-5.4", resolveModel("orchestrator", .smart));
    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolveModel("finder", .rush));
}

test "grid: resolveModel falls back to mode when role unknown" {
    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolveModel("unknown", .smart));
    try std.testing.expectEqualStrings("claude-opus-4-6", resolveModel(null, .deep));
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", resolveModel(null, .rush));
}

test "grid: ModelTier round-trips" {
    try std.testing.expectEqual(ModelTier.haiku, ModelTier.fromString("haiku").?);
    try std.testing.expectEqual(ModelTier.sonnet, ModelTier.fromString("sonnet").?);
    try std.testing.expectEqual(ModelTier.opus, ModelTier.fromString("opus").?);
    try std.testing.expectEqual(@as(?ModelTier, null), ModelTier.fromString("gpt4"));
}

// ── Grid override tests (#269) ──────────────────────────────────────────────

test "grid: parseOverrides basic TOML" {
    const toml =
        \\# Generated by evolve_agent
        \\[orchestrator]
        \\model = "sonnet"
        \\rationale = "Haiku failed to decompose complex tasks"
        \\
        \\[mutator]
        \\model = "opus"
        \\rationale = "Opus produces higher fitness organisms"
    ;
    const result = parseOverrides(toml);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("orchestrator", result.overrides[0].role);
    try std.testing.expectEqual(ModelTier.sonnet, result.overrides[0].tier);
    try std.testing.expectEqualStrings("mutator", result.overrides[1].role);
    try std.testing.expectEqual(ModelTier.opus, result.overrides[1].tier);
}

test "grid: parseOverrides skips invalid tier" {
    const toml =
        \\[reviewer]
        \\model = "nonexistent"
    ;
    const result = parseOverrides(toml);
    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "grid: parseOverrides handles empty content" {
    const result = parseOverrides("");
    try std.testing.expectEqual(@as(usize, 0), result.count);
}

test "grid: parseOverrides rationale before model" {
    const toml =
        \\[fixer]
        \\rationale = "Better at fixing"
        \\model = "haiku"
    ;
    const result = parseOverrides(toml);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(ModelTier.haiku, result.overrides[0].tier);
}

test "grid: parseOverrides strips quotes" {
    const toml =
        \\[finder]
        \\model = "sonnet"
    ;
    const result = parseOverrides(toml);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(ModelTier.sonnet, result.overrides[0].tier);
}

test "grid: parseOverrides no quotes works too" {
    const toml =
        \\[finder]
        \\model = opus
    ;
    const result = parseOverrides(toml);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(ModelTier.opus, result.overrides[0].tier);
}

test "grid: resolveModel existing tests still pass with override reset" {
    resetOverrides();
    try std.testing.expectEqualStrings("gpt-5.4", resolveModel("orchestrator", .smart));
    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolveModel("finder", .rush));
    resetOverrides();
}

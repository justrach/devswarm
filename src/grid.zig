const std = @import("std");
const telemetry = @import("telemetry.zig");

pub const SandboxPolicy = enum {
    read_only,
    writable,
    sandboxed,
};

pub const SynthesisStrategy = enum {
    merge,
    concat,
    adversarial_merge,
    first_wins,
    last_wins,
    custom,
};

pub const TelemetryConfig = struct {
    enabled: bool = true,
    track_tokens: bool = true,
    track_tool_calls: bool = true,
    track_wall_time: bool = true,
    track_files: bool = false,
    output_path: ?[]const u8 = null,
};

pub const ResourceBudget = struct {
    max_workers: u32 = 10,
    max_total_tokens: u64 = 1_000_000,
    max_wall_ms: u64 = 300_000,
    max_cost_usd: ?f32 = 10.0,
};

pub const Role = struct {
    name: []const u8,
    model: []const u8 = "claude-sonnet-4-6",
    max_tool_calls: u32 = 50,
    tool_allowlist: ?[]const []const u8 = null,
};

pub const Grid = struct {
    name: []const u8,
    roles: []const Role,
    policy: SandboxPolicy = .read_only,
    synthesis: SynthesisStrategy = .merge,
    telemetry_config: TelemetryConfig = .{},
    budget: ResourceBudget = .{},

    metrics: ?telemetry.GridMetrics = null,
    output: std.ArrayList(u8) = .empty,
    completed: bool = false,
    error_msg: ?[]const u8 = null,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, name: []const u8, roles: []const Role) Self {
        return .{
            .name = name,
            .roles = roles,
            .metrics = telemetry.GridMetrics.init(alloc, name),
        };
    }

    pub fn initWithConfig(
        alloc: std.mem.Allocator,
        name: []const u8,
        roles: []const Role,
        policy: SandboxPolicy,
        synthesis: SynthesisStrategy,
        budget: ResourceBudget,
        telemetry_config: TelemetryConfig,
    ) Self {
        return .{
            .name = name,
            .roles = roles,
            .policy = policy,
            .synthesis = synthesis,
            .budget = budget,
            .telemetry_config = telemetry_config,
            .metrics = telemetry.GridMetrics.init(alloc, name),
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        if (self.metrics) |*m| m.deinit(alloc);
        self.output.deinit(alloc);
        if (self.error_msg) |e| alloc.free(e);
    }

    pub fn isWritable(self: *const Self) bool {
        return self.policy == .writable;
    }

    pub fn checkBudget(self: *const Self, current_tokens: u64, current_ms: u64, current_cost: f64) bool {
        if (current_tokens > self.budget.max_total_tokens) return false;
        if (current_ms > self.budget.max_wall_ms) return false;
        if (self.budget.max_cost_usd) |max_cost| {
            if (current_cost > max_cost) return false;
        }
        return true;
    }

    pub fn maxWorkers(self: *const Self) u32 {
        return @min(self.budget.max_workers, @as(u32, @intCast(self.roles.len)));
    }

    pub fn setOutput(self: *Self, alloc: std.mem.Allocator, data: []const u8) void {
        self.output.clearRetainingCapacity();
        self.output.appendSlice(alloc, data) catch {};
        self.completed = true;
    }

    pub fn setError(self: *Self, alloc: std.mem.Allocator, msg: []const u8) void {
        if (self.error_msg) |e| alloc.free(e);
        self.error_msg = alloc.dupe(u8, msg) catch null;
        self.completed = true;
    }

    pub fn addWorkerMetrics(self: *Self, alloc: std.mem.Allocator, wm: telemetry.WorkerMetrics) void {
        if (self.metrics) |*m| {
            m.addWorker(alloc, wm) catch {};
        }
    }

};

pub const GridPipeline = struct {
    grids: std.ArrayList(*Grid),
    current_idx: usize = 0,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .grids = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        self.grids.deinit(self.alloc);
    }

    pub fn addGrid(self: *Self, grid: *Grid) void {
        self.grids.append(self.alloc, grid) catch {};
    }

    pub fn current(self: *const Self) ?*Grid {
        if (self.current_idx >= self.grids.items.len) return null;
        return self.grids.items[self.current_idx];
    }

    pub fn advance(self: *Self) bool {
        if (self.current_idx >= self.grids.items.len) return false;
        self.current_idx += 1;
        return self.current_idx < self.grids.items.len;
    }

    pub fn isComplete(self: *const Self) bool {
        return self.current_idx >= self.grids.items.len;
    }

    pub fn getOutput(self: *const Self) ?[]const u8 {
        if (self.grids.items.len == 0) return null;
        const last = self.grids.items[self.grids.items.len - 1];
        if (last.completed and last.output.items.len > 0) {
            return last.output.items;
        }
        return null;
    }

    pub fn hasErrors(self: *const Self) bool {
        for (self.grids.items) |grid| {
            if (grid.error_msg != null) return true;
        }
        return false;
    }

    pub fn getFirstError(self: *const Self) ?[]const u8 {
        for (self.grids.items) |grid| {
            if (grid.error_msg) |e| return e;
        }
        return null;
    }
};

pub fn synthesizeResults(
    alloc: std.mem.Allocator,
    strategy: SynthesisStrategy,
    outputs: []const []const u8,
    out: *std.ArrayList(u8),
) void {
    if (outputs.len == 0) return;

    switch (strategy) {
        .merge => {
            out.appendSlice(alloc, "## Synthesis\n\n") catch {};
            for (outputs, 0..) |output, i| {
                const header = std.fmt.allocPrint(alloc, "### Result {d}\n", .{i + 1}) catch "";
                defer alloc.free(header);
                out.appendSlice(alloc, header) catch {};
                out.appendSlice(alloc, output) catch {};
                out.appendSlice(alloc, "\n\n") catch {};
            }
        },
        .concat => {
            for (outputs) |output| {
                out.appendSlice(alloc, output) catch {};
                out.appendSlice(alloc, "\n") catch {};
            }
        },
        .adversarial_merge => {
            out.appendSlice(alloc, "## Verified Results\n\n") catch {};
            for (outputs, 0..) |output, i| {
                const marker = if (i == 0) "✅ " else "🔍 ";
                out.appendSlice(alloc, marker) catch {};
                out.appendSlice(alloc, output) catch {};
                out.appendSlice(alloc, "\n\n") catch {};
            }
        },
        .first_wins => {
            if (outputs.len > 0) {
                out.appendSlice(alloc, outputs[0]) catch {};
            }
        },
        .last_wins => {
            if (outputs.len > 0) {
                out.appendSlice(alloc, outputs[outputs.len - 1]) catch {};
            }
        },
        .custom => {
            for (outputs) |output| {
                out.appendSlice(alloc, output) catch {};
                out.appendSlice(alloc, "\n") catch {};
            }
        },
    }
}

test "grid: SandboxPolicy enum values" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(SandboxPolicy).@"enum".fields.len);
    try std.testing.expectEqual(SandboxPolicy.read_only, @as(SandboxPolicy, @enumFromInt(0)));
    try std.testing.expectEqual(SandboxPolicy.writable, @as(SandboxPolicy, @enumFromInt(1)));
    try std.testing.expectEqual(SandboxPolicy.sandboxed, @as(SandboxPolicy, @enumFromInt(2)));
}

test "grid: SynthesisStrategy enum values" {
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(SynthesisStrategy).@"enum".fields.len);
}

test "grid: ResourceBudget defaults" {
    const budget = ResourceBudget{};
    try std.testing.expectEqual(@as(u32, 10), budget.max_workers);
    try std.testing.expectEqual(@as(u64, 1_000_000), budget.max_total_tokens);
    try std.testing.expectEqual(@as(u64, 300_000), budget.max_wall_ms);
    try std.testing.expectEqual(@as(f32, 10.0), budget.max_cost_usd.?);
}

test "grid: Grid init with name and roles" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "finder" }};
    var grid = Grid.init(alloc, "search", &roles);
    defer grid.deinit(alloc);

    try std.testing.expectEqualStrings("search", grid.name);
    try std.testing.expectEqual(@as(usize, 1), grid.roles.len);
    try std.testing.expectEqual(SandboxPolicy.read_only, grid.policy);
    try std.testing.expectEqual(SynthesisStrategy.merge, grid.synthesis);
}

test "grid: Grid initWithConfig" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "fixer" }};
    const budget = ResourceBudget{ .max_workers = 5, .max_cost_usd = null };
    const telemetry_config = TelemetryConfig{ .enabled = false };

    var grid = Grid.initWithConfig(
        alloc,
        "fix",
        &roles,
        .writable,
        .adversarial_merge,
        budget,
        telemetry_config,
    );
    defer grid.deinit(alloc);

    try std.testing.expectEqualStrings("fix", grid.name);
    try std.testing.expectEqual(SandboxPolicy.writable, grid.policy);
    try std.testing.expectEqual(SynthesisStrategy.adversarial_merge, grid.synthesis);
    try std.testing.expectEqual(@as(u32, 5), grid.budget.max_workers);
    try std.testing.expect(grid.budget.max_cost_usd == null);
    try std.testing.expect(!grid.telemetry_config.enabled);
}

test "grid: isWritable returns correct value" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};

    var ro_grid = Grid.init(alloc, "ro", &roles);
    defer ro_grid.deinit(alloc);
    try std.testing.expect(!ro_grid.isWritable());

    var rw_grid = Grid.initWithConfig(alloc, "rw", &roles, .writable, .merge, .{}, .{});
    defer rw_grid.deinit(alloc);
    try std.testing.expect(rw_grid.isWritable());
}

test "grid: checkBudget respects limits" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    const budget = ResourceBudget{
        .max_total_tokens = 1000,
        .max_wall_ms = 5000,
        .max_cost_usd = 1.0,
    };
    var grid = Grid.initWithConfig(alloc, "test", &roles, .read_only, .merge, budget, .{});
    defer grid.deinit(alloc);

    try std.testing.expect(grid.checkBudget(500, 2000, 0.5));
    try std.testing.expect(!grid.checkBudget(1500, 2000, 0.5));
    try std.testing.expect(!grid.checkBudget(500, 6000, 0.5));
    try std.testing.expect(!grid.checkBudget(500, 2000, 1.5));
}

test "grid: maxWorkers respects budget" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" } };
    const budget = ResourceBudget{ .max_workers = 2 };
    var grid = Grid.initWithConfig(alloc, "test", &roles, .read_only, .merge, budget, .{});
    defer grid.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), grid.maxWorkers());
}

test "grid: setOutput and setError" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    var grid = Grid.init(alloc, "test", &roles);
    defer grid.deinit(alloc);

    grid.setOutput(alloc, "result data");
    try std.testing.expect(grid.completed);
    try std.testing.expectEqualStrings("result data", grid.output.items);

    grid.setError(alloc, "something failed");
    try std.testing.expect(grid.error_msg != null);
    try std.testing.expectEqualStrings("something failed", grid.error_msg.?);
}

test "grid: GridPipeline basic operations" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};

    var grid1 = Grid.init(alloc, "grid1", &roles);
    defer grid1.deinit(alloc);
    var grid2 = Grid.init(alloc, "grid2", &roles);
    defer grid2.deinit(alloc);

    var pipeline = GridPipeline.init(alloc);
    defer pipeline.deinit();

    pipeline.addGrid(&grid1);
    pipeline.addGrid(&grid2);

    try std.testing.expectEqual(@as(usize, 2), pipeline.grids.items.len);
    try std.testing.expectEqual(@as(usize, 0), pipeline.current_idx);
    try std.testing.expect(pipeline.current() == &grid1);

    _ = pipeline.advance();
    try std.testing.expectEqual(@as(usize, 1), pipeline.current_idx);
    try std.testing.expect(pipeline.current() == &grid2);

    _ = pipeline.advance();
    try std.testing.expect(pipeline.isComplete());
    try std.testing.expect(pipeline.current() == null);
}

test "grid: GridPipeline error handling" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};

    var grid1 = Grid.init(alloc, "grid1", &roles);
    defer grid1.deinit(alloc);
    var grid2 = Grid.init(alloc, "grid2", &roles);
    defer grid2.deinit(alloc);

    grid2.setError(alloc, "failure");

    var pipeline = GridPipeline.init(alloc);
    defer pipeline.deinit();

    pipeline.addGrid(&grid1);
    pipeline.addGrid(&grid2);

    try std.testing.expect(pipeline.hasErrors());
    const err = pipeline.getFirstError();
    try std.testing.expect(err != null);
    try std.testing.expectEqualStrings("failure", err.?);
}

test "grid: synthesizeResults merge strategy" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{ "output1", "output2" };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .merge, &outputs, &result);

    try std.testing.expect(std.mem.indexOf(u8, result.items, "output1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "output2") != null);
}

test "grid: synthesizeResults first_wins strategy" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{ "first", "second" };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .first_wins, &outputs, &result);

    try std.testing.expectEqualStrings("first", result.items);
}

test "grid: synthesizeResults last_wins strategy" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{ "first", "second" };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .last_wins, &outputs, &result);

    try std.testing.expectEqualStrings("second", result.items);
}

test "grid: synthesizeResults empty inputs" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{};

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .merge, &outputs, &result);

    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}

test "grid: TelemetryConfig defaults" {
    const tc = TelemetryConfig{};
    try std.testing.expect(tc.enabled);
    try std.testing.expect(tc.track_tokens);
    try std.testing.expect(tc.track_tool_calls);
    try std.testing.expect(tc.track_wall_time);
    try std.testing.expect(!tc.track_files);
    try std.testing.expect(tc.output_path == null);
}

test "grid: Role defaults" {
    const role = Role{ .name = "test_role" };
    try std.testing.expectEqualStrings("test_role", role.name);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", role.model);
    try std.testing.expectEqual(@as(u32, 50), role.max_tool_calls);
    try std.testing.expect(role.tool_allowlist == null);
}

test "edge: Grid with empty roles array" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{};
    var g = Grid.init(alloc, "empty", &roles);
    defer g.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), g.roles.len);
    try std.testing.expectEqual(@as(u32, 0), g.maxWorkers());
}

test "edge: ResourceBudget with zero limits" {
    const budget = ResourceBudget{
        .max_workers = 0,
        .max_total_tokens = 0,
        .max_wall_ms = 0,
        .max_cost_usd = 0.0,
    };

    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    var g = Grid.initWithConfig(alloc, "zero", &roles, .read_only, .merge, budget, .{});
    defer g.deinit(alloc);

    try std.testing.expect(!g.checkBudget(1, 1, 0.0));
    try std.testing.expectEqual(@as(u32, 0), g.maxWorkers());
}

test "edge: ResourceBudget with null cost allows any cost" {
    const budget = ResourceBudget{ .max_cost_usd = null };

    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    var g = Grid.initWithConfig(alloc, "no_cost_limit", &roles, .read_only, .merge, budget, .{});
    defer g.deinit(alloc);

    try std.testing.expect(g.checkBudget(100, 100, 1_000_000.0));
}

test "edge: GridPipeline with empty grids" {
    const alloc = std.testing.allocator;
    var pipeline = GridPipeline.init(alloc);
    defer pipeline.deinit();

    try std.testing.expectEqual(@as(usize, 0), pipeline.grids.items.len);
    try std.testing.expect(pipeline.current() == null);
    try std.testing.expect(pipeline.isComplete());
    try std.testing.expect(!pipeline.hasErrors());
    try std.testing.expect(pipeline.getFirstError() == null);
}

test "edge: synthesizeResults with single output" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{"only one"};

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .merge, &outputs, &result);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "only one") != null);
}

test "edge: Grid output overwrites previous" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    var g = Grid.init(alloc, "test", &roles);
    defer g.deinit(alloc);

    g.setOutput(alloc, "first");
    try std.testing.expectEqualStrings("first", g.output.items);

    g.setOutput(alloc, "second");
    try std.testing.expectEqualStrings("second", g.output.items);
}

test "edge: Grid error overwrites previous" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    var g = Grid.init(alloc, "test", &roles);
    defer g.deinit(alloc);

    g.setError(alloc, "first error");
    try std.testing.expectEqualStrings("first error", g.error_msg.?);

    g.setError(alloc, "second error");
    try std.testing.expectEqualStrings("second error", g.error_msg.?);
}

test "edge: SandboxPolicy sandboxed is not writable" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    var g = Grid.initWithConfig(alloc, "sandboxed", &roles, .sandboxed, .merge, .{}, .{});
    defer g.deinit(alloc);

    try std.testing.expect(!g.isWritable());
    try std.testing.expectEqual(SandboxPolicy.sandboxed, g.policy);
}

test "edge: checkBudget with exact boundary values" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};
    const budget = ResourceBudget{
        .max_total_tokens = 1000,
        .max_wall_ms = 5000,
        .max_cost_usd = 1.0,
    };
    var g = Grid.initWithConfig(alloc, "test", &roles, .read_only, .merge, budget, .{});
    defer g.deinit(alloc);

    try std.testing.expect(g.checkBudget(1000, 5000, 1.0));
    try std.testing.expect(!g.checkBudget(1001, 5000, 1.0));
    try std.testing.expect(!g.checkBudget(1000, 5001, 1.0));
    try std.testing.expect(!g.checkBudget(1000, 5000, 1.01));
}

test "edge: GridPipeline getOutput from incomplete pipeline" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};

    var g = Grid.init(alloc, "test", &roles);
    defer g.deinit(alloc);

    var pipeline = GridPipeline.init(alloc);
    defer pipeline.deinit();

    pipeline.addGrid(&g);

    try std.testing.expect(pipeline.getOutput() == null);

    g.setOutput(alloc, "done");
    try std.testing.expect(pipeline.getOutput() != null);
    try std.testing.expectEqualStrings("done", pipeline.getOutput().?);
}

test "edge: Pipeline with mixed success/error grids" {
    const alloc = std.testing.allocator;
    const roles = [_]Role{.{ .name = "test" }};

    var g1 = Grid.init(alloc, "success", &roles);
    defer g1.deinit(alloc);
    var g2 = Grid.init(alloc, "error", &roles);
    defer g2.deinit(alloc);
    var g3 = Grid.init(alloc, "success2", &roles);
    defer g3.deinit(alloc);

    g1.setOutput(alloc, "ok");
    g2.setError(alloc, "failed");
    g3.setOutput(alloc, "ok2");

    var pipeline = GridPipeline.init(alloc);
    defer pipeline.deinit();

    pipeline.addGrid(&g1);
    pipeline.addGrid(&g2);
    pipeline.addGrid(&g3);

    try std.testing.expect(pipeline.hasErrors());
    try std.testing.expectEqualStrings("failed", pipeline.getFirstError().?);
}

test "edge: Role with custom model and tool allowlist" {
    const alloc = std.testing.allocator;
    const allowlist = [_][]const u8{ "zigrep", "zigread" };
    const roles = [_]Role{.{
        .name = "restricted",
        .model = "claude-opus-4-6",
        .max_tool_calls = 100,
        .tool_allowlist = &allowlist,
    }};
    var g = Grid.init(alloc, "restricted", &roles);
    defer g.deinit(alloc);

    try std.testing.expectEqualStrings("claude-opus-4-6", g.roles[0].model);
    try std.testing.expectEqual(@as(u32, 100), g.roles[0].max_tool_calls);
    try std.testing.expect(g.roles[0].tool_allowlist != null);
    try std.testing.expectEqual(@as(usize, 2), g.roles[0].tool_allowlist.?.len);
}

test "edge: synthesizeResults adversarial_merge adds markers" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{ "verified", "challenged" };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .adversarial_merge, &outputs, &result);

    try std.testing.expect(std.mem.indexOf(u8, result.items, "✅") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "🔍") != null);
}

test "edge: synthesizeResults with unicode content" {
    const alloc = std.testing.allocator;
    const outputs = [_][]const u8{ "Hello 世界 🌍", "Привет мир" };

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    synthesizeResults(alloc, .merge, &outputs, &result);

    try std.testing.expect(std.mem.indexOf(u8, result.items, "世界") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.items, "Привет") != null);
}

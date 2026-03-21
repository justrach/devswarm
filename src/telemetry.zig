const std = @import("std");
const mj = @import("mcp").json;

pub const WorkerMetrics = struct {
    worker_id: u32,
    role: []const u8,
    model: []const u8,
    tool_calls: u32 = 0,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    wall_ms: u64 = 0,
    errors: u32 = 0,
    files_read: std.ArrayList([]const u8) = .empty,
    files_written: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *WorkerMetrics, alloc: std.mem.Allocator) void {
        for (self.files_read.items) |f| alloc.free(f);
        self.files_read.deinit(alloc);
        for (self.files_written.items) |f| alloc.free(f);
        self.files_written.deinit(alloc);
    }

    pub fn addFileRead(self: *WorkerMetrics, alloc: std.mem.Allocator, path: []const u8) void {
        const duped = alloc.dupe(u8, path) catch return;
        self.files_read.append(alloc, duped) catch {
            alloc.free(duped);
        };
    }

    pub fn addFileWritten(self: *WorkerMetrics, alloc: std.mem.Allocator, path: []const u8) void {
        const duped = alloc.dupe(u8, path) catch return;
        self.files_written.append(alloc, duped) catch {
            alloc.free(duped);
        };
    }
};

pub const GridMetrics = struct {
    name: []const u8,
    workers: std.ArrayList(WorkerMetrics) = .empty,
    synthesis_ms: u64 = 0,
    convergence_score: ?f32 = null,
    total_tokens: u64 = 0,
    total_tool_calls: u32 = 0,

    pub fn deinit(self: *GridMetrics, alloc: std.mem.Allocator) void {
        for (self.workers.items) |*w| w.deinit(alloc);
        self.workers.deinit(alloc);
    }

    pub fn addWorker(self: *GridMetrics, alloc: std.mem.Allocator, worker: WorkerMetrics) void {
        self.total_tokens += worker.tokens_in + worker.tokens_out;
        self.total_tool_calls += worker.tool_calls;
        self.workers.append(alloc, worker) catch {};
    }
};

pub const SwarmTelemetry = struct {
    alloc: std.mem.Allocator,
    swarm_id: [16]u8,
    repo: []const u8,
    task: []const u8,
    grids: std.ArrayList(GridMetrics) = .empty,
    start_ms: i64,
    end_ms: ?i64 = null,
    mu: std.Thread.Mutex,

    pub fn init(alloc: std.mem.Allocator, repo: []const u8, task: []const u8) SwarmTelemetry {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);

        return .{
            .alloc = alloc,
            .swarm_id = id,
            .repo = alloc.dupe(u8, repo) catch "",
            .task = alloc.dupe(u8, task) catch "",
            .grids = .empty,
            .start_ms = std.time.milliTimestamp(),
            .mu = .{},
        };
    }

    pub fn deinit(self: *SwarmTelemetry) void {
        self.alloc.free(self.repo);
        self.alloc.free(self.task);
        for (self.grids.items) |*g| g.deinit(self.alloc);
        self.grids.deinit(self.alloc);
    }

    pub fn addGrid(self: *SwarmTelemetry, grid: GridMetrics) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.grids.append(self.alloc, grid) catch {};
    }

    pub fn finalize(self: *SwarmTelemetry) void {
        self.end_ms = std.time.milliTimestamp();
    }

    pub fn totalWallMs(self: *const SwarmTelemetry) u64 {
        const end = self.end_ms orelse std.time.milliTimestamp();
        return @intCast(@max(end - self.start_ms, 0));
    }

    pub fn totalTokens(self: *const SwarmTelemetry) u64 {
        var total: u64 = 0;
        for (self.grids.items) |g| {
            total += g.total_tokens;
        }
        return total;
    }

    pub fn totalToolCalls(self: *const SwarmTelemetry) u32 {
        var total: u32 = 0;
        for (self.grids.items) |g| {
            total += g.total_tool_calls;
        }
        return total;
    }

    pub fn totalWorkers(self: *const SwarmTelemetry) u32 {
        var count: u32 = 0;
        for (self.grids.items) |g| {
            count += @intCast(g.workers.items.len);
        }
        return count;
    }

    pub fn estimateCostUsd(self: *const SwarmTelemetry) f64 {
        var cost: f64 = 0.0;
        for (self.grids.items) |g| {
            for (g.workers.items) |w| {
                cost += estimateWorkerCost(w);
            }
        }
        return cost;
    }

    fn estimateWorkerCost(w: WorkerMetrics) f64 {
        const model = w.model;
        const input_per_1k: f64 = if (std.mem.indexOf(u8, model, "opus") != null)
            15.0
        else if (std.mem.indexOf(u8, model, "sonnet") != null)
            3.0
        else if (std.mem.indexOf(u8, model, "haiku") != null)
            0.25
        else
            3.0;

        const output_per_1k: f64 = if (std.mem.indexOf(u8, model, "opus") != null)
            75.0
        else if (std.mem.indexOf(u8, model, "sonnet") != null)
            15.0
        else if (std.mem.indexOf(u8, model, "haiku") != null)
            1.25
        else
            15.0;

        const input_cost = @as(f64, @floatFromInt(w.tokens_in)) / 1000.0 * input_per_1k;
        const output_cost = @as(f64, @floatFromInt(w.tokens_out)) / 1000.0 * output_per_1k;
        return input_cost + output_cost;
    }

    pub fn toJson(self: *const SwarmTelemetry, alloc: std.mem.Allocator) []u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "{") catch return alloc.dupe(u8, "{}") catch "";

        buf.appendSlice(alloc, "\"swarm_id\":\"") catch {};
        for (self.swarm_id) |b| {
            var hex: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "{x:0>2}", .{b}) catch {};
            buf.appendSlice(alloc, &hex) catch {};
        }
        buf.appendSlice(alloc, "\",") catch {};

        buf.appendSlice(alloc, "\"repo\":\"") catch {};
        mj.writeEscaped(alloc, &buf, self.repo);
        buf.appendSlice(alloc, "\",") catch {};

        buf.appendSlice(alloc, "\"task\":\"") catch {};
        mj.writeEscaped(alloc, &buf, self.task);
        buf.appendSlice(alloc, "\",") catch {};

        buf.appendSlice(alloc, "\"grids\":[") catch {};
        for (self.grids.items, 0..) |g, gi| {
            if (gi > 0) buf.appendSlice(alloc, ",") catch {};
            writeGridJson(alloc, &buf, g);
        }
        buf.appendSlice(alloc, "],") catch {};

        var cost_buf: [32]u8 = undefined;
        const cost_str = std.fmt.bufPrint(&cost_buf, "{d:.4}", .{self.estimateCostUsd()}) catch "0";
        buf.appendSlice(alloc, "\"total_cost_usd\":") catch {};
        buf.appendSlice(alloc, cost_str) catch {};
        buf.appendSlice(alloc, ",") catch {};

        var wall_buf: [16]u8 = undefined;
        const wall_str = std.fmt.bufPrint(&wall_buf, "{d}", .{self.totalWallMs()}) catch "0";
        buf.appendSlice(alloc, "\"total_wall_ms\":") catch {};
        buf.appendSlice(alloc, wall_str) catch {};
        buf.appendSlice(alloc, ",") catch {};

        const workers = self.totalWorkers();
        const wall_sec = @as(f64, @floatFromInt(self.totalWallMs())) / 1000.0;
        const parallelism: f64 = if (wall_sec > 0)
            @as(f64, @floatFromInt(workers)) / wall_sec * 1000.0
        else
            0.0;

        var par_buf: [32]u8 = undefined;
        const par_str = std.fmt.bufPrint(&par_buf, "{d:.1}", .{parallelism}) catch "0";
        buf.appendSlice(alloc, "\"parallelism_achieved\":") catch {};
        buf.appendSlice(alloc, par_str) catch {};

        buf.appendSlice(alloc, "}") catch {};

        return buf.toOwnedSlice(alloc) catch alloc.dupe(u8, "{}") catch "";
    }
};

fn writeGridJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), grid: GridMetrics) void {
    buf.appendSlice(alloc, "{") catch return;

    buf.appendSlice(alloc, "\"name\":\"") catch {};
    mj.writeEscaped(alloc, buf, grid.name);
    buf.appendSlice(alloc, "\",") catch {};

    buf.appendSlice(alloc, "\"workers\":[") catch {};
    for (grid.workers.items, 0..) |w, wi| {
        if (wi > 0) buf.appendSlice(alloc, ",") catch {};
        writeWorkerJson(alloc, buf, w);
    }
    buf.appendSlice(alloc, "],") catch {};

    var synth_buf: [16]u8 = undefined;
    const synth_str = std.fmt.bufPrint(&synth_buf, "{d}", .{grid.synthesis_ms}) catch "0";
    buf.appendSlice(alloc, "\"synthesis_ms\":") catch {};
    buf.appendSlice(alloc, synth_str) catch {};

    if (grid.convergence_score) |score| {
        var conv_buf: [16]u8 = undefined;
        const conv_str = std.fmt.bufPrint(&conv_buf, ",\"convergence_score\":{d:.2}", .{score}) catch "";
        buf.appendSlice(alloc, conv_str) catch {};
    }

    buf.appendSlice(alloc, "}") catch {};
}

fn writeWorkerJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), w: WorkerMetrics) void {
    buf.appendSlice(alloc, "{") catch return;

    var num_buf: [16]u8 = undefined;

    buf.appendSlice(alloc, "\"id\":") catch {};
    buf.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{w.worker_id}) catch "0") catch {};
    buf.appendSlice(alloc, ",") catch {};

    buf.appendSlice(alloc, "\"role\":\"") catch {};
    mj.writeEscaped(alloc, buf, w.role);
    buf.appendSlice(alloc, "\",") catch {};

    buf.appendSlice(alloc, "\"model\":\"") catch {};
    mj.writeEscaped(alloc, buf, w.model);
    buf.appendSlice(alloc, "\",") catch {};

    buf.appendSlice(alloc, "\"tool_calls\":") catch {};
    buf.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{w.tool_calls}) catch "0") catch {};
    buf.appendSlice(alloc, ",") catch {};

    buf.appendSlice(alloc, "\"tokens_in\":") catch {};
    buf.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{w.tokens_in}) catch "0") catch {};
    buf.appendSlice(alloc, ",") catch {};

    buf.appendSlice(alloc, "\"tokens_out\":") catch {};
    buf.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{w.tokens_out}) catch "0") catch {};
    buf.appendSlice(alloc, ",") catch {};

    buf.appendSlice(alloc, "\"wall_ms\":") catch {};
    buf.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{w.wall_ms}) catch "0") catch {};
    buf.appendSlice(alloc, ",") catch {};

    buf.appendSlice(alloc, "\"errors\":") catch {};
    buf.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{w.errors}) catch "0") catch {};
    buf.appendSlice(alloc, ",") catch {};

    buf.appendSlice(alloc, "\"files_read\":[") catch {};
    for (w.files_read.items, 0..) |f, fi| {
        if (fi > 0) buf.appendSlice(alloc, ",") catch {};
        buf.appendSlice(alloc, "\"") catch {};
        mj.writeEscaped(alloc, buf, f);
        buf.appendSlice(alloc, "\"") catch {};
    }
    buf.appendSlice(alloc, "],") catch {};

    buf.appendSlice(alloc, "\"files_written\":[") catch {};
    for (w.files_written.items, 0..) |f, fi| {
        if (fi > 0) buf.appendSlice(alloc, ",") catch {};
        buf.appendSlice(alloc, "\"") catch {};
        mj.writeEscaped(alloc, buf, f);
        buf.appendSlice(alloc, "\"") catch {};
    }
    buf.appendSlice(alloc, "]") catch {};

    buf.appendSlice(alloc, "}") catch {};
}

test "telemetry: WorkerMetrics tracks files" {
    const alloc = std.testing.allocator;
    var w: WorkerMetrics = .{
        .worker_id = 1,
        .role = "finder",
        .model = "claude-sonnet-4-6",
        .tokens_in = 1000,
        .tokens_out = 500,
        .wall_ms = 1500,
    };
    defer w.deinit(alloc);

    w.addFileRead(alloc, "src/main.zig");
    w.addFileRead(alloc, "src/lib.zig");
    w.addFileWritten(alloc, "src/generated.zig");

    try std.testing.expectEqual(@as(usize, 2), w.files_read.items.len);
    try std.testing.expectEqual(@as(usize, 1), w.files_written.items.len);
    try std.testing.expectEqualStrings("src/main.zig", w.files_read.items[0]);
}

test "telemetry: GridMetrics aggregates workers" {
    const alloc = std.testing.allocator;
    var g: GridMetrics = .{ .name = "search" };
    defer g.deinit(alloc);

    const w1: WorkerMetrics = .{ .worker_id = 0, .tokens_in = 1000, .tokens_out = 500, .tool_calls = 5 };
    const w2: WorkerMetrics = .{ .worker_id = 1, .tokens_in = 2000, .tokens_out = 800, .tool_calls = 8 };

    g.addWorker(alloc, w1);
    g.addWorker(alloc, w2);

    try std.testing.expectEqual(@as(usize, 2), g.workers.items.len);
    try std.testing.expectEqual(@as(u64, 4300), g.total_tokens);
    try std.testing.expectEqual(@as(u32, 13), g.total_tool_calls);
}

test "telemetry: SwarmTelemetry calculates cost" {
    const alloc = std.testing.allocator;
    var t = SwarmTelemetry.init(alloc, "owner/repo", "test task");
    defer t.deinit();

    var g: GridMetrics = .{ .name = "review" };
    const w: WorkerMetrics = .{
        .worker_id = 0,
        .role = "reviewer",
        .model = "claude-sonnet-4-6",
        .tokens_in = 10000,
        .tokens_out = 5000,
    };
    g.addWorker(alloc, w);
    t.addGrid(g);
    t.finalize();

    const cost = t.estimateCostUsd();
    try std.testing.expect(cost > 0);

    const json = t.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"swarm_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_cost_usd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"repo\":\"owner/repo\"") != null);
}

test "telemetry: cost estimation for different models" {
    const alloc = std.testing.allocator;

    var w_haiku: WorkerMetrics = .{ .model = "claude-haiku-4-5", .tokens_in = 1000, .tokens_out = 1000 };
    defer w_haiku.deinit(alloc);

    var w_sonnet: WorkerMetrics = .{ .model = "claude-sonnet-4-6", .tokens_in = 1000, .tokens_out = 1000 };
    defer w_sonnet.deinit(alloc);

    var w_opus: WorkerMetrics = .{ .model = "claude-opus-4-6", .tokens_in = 1000, .tokens_out = 1000 };
    defer w_opus.deinit(alloc);

    const cost_haiku = SwarmTelemetry.estimateWorkerCost(w_haiku);
    const cost_sonnet = SwarmTelemetry.estimateWorkerCost(w_sonnet);
    const cost_opus = SwarmTelemetry.estimateWorkerCost(w_opus);

    try std.testing.expect(cost_haiku < cost_sonnet);
    try std.testing.expect(cost_sonnet < cost_opus);
}

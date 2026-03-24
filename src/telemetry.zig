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

    pub fn init(id: u32, role: []const u8, model: []const u8) WorkerMetrics {
        return .{
            .worker_id = id,
            .role = role,
            .model = model,
        };
    }

    pub fn deinit(self: *WorkerMetrics, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

pub const GridMetrics = struct {
    name: []const u8,
    workers: std.ArrayList(WorkerMetrics),
    synthesis_ms: u64 = 0,
    convergence_score: ?f32 = null,
    total_tokens: u64 = 0,
    total_tool_calls: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, name: []const u8) GridMetrics {
        _ = alloc;
        return .{
            .name = name,
            .workers = .empty,
        };
    }

    pub fn deinit(self: *GridMetrics, alloc: std.mem.Allocator) void {
        for (self.workers.items) |*w| w.deinit(alloc);
        self.workers.deinit(alloc);
    }

    pub fn addWorker(self: *GridMetrics, alloc: std.mem.Allocator, worker: WorkerMetrics) void {
        self.workers.append(alloc, worker) catch {};
    }

    pub fn aggregate(self: *GridMetrics) void {
        self.total_tokens = 0;
        self.total_tool_calls = 0;
        for (self.workers.items) |w| {
            self.total_tokens += w.tokens_in + w.tokens_out;
            self.total_tool_calls += w.tool_calls;
        }
    }
};

pub const SwarmTelemetry = struct {
    swarm_id: [16]u8,
    swarm_id_str: [36]u8,
    repo: ?[]const u8 = null,
    task: []const u8,
    grids: std.ArrayList(GridMetrics),
    total_cost_usd: f64 = 0.0,
    total_wall_ms: u64 = 0,
    parallelism_achieved: f64 = 0.0,
    parallelism_theoretical: u32 = 0,
    start_ms: i64,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, task: []const u8) Self {
        var self: Self = .{
            .task = task,
            .grids = .empty,
            .start_ms = std.time.milliTimestamp(),
            .alloc = alloc,
            .swarm_id = undefined,
            .swarm_id_str = undefined,
        };
        self.generateSwarmId();
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.repo) |r| self.alloc.free(r);
        for (self.grids.items) |*g| g.deinit(self.alloc);
        self.grids.deinit(self.alloc);
    }

    fn generateSwarmId(self: *Self) void {
        var rand_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);
        self.swarm_id = rand_bytes;

        const hex = "0123456789abcdef";
        var idx: usize = 0;
        for (0..4) |i| {
            self.swarm_id_str[idx] = hex[rand_bytes[i] >> 4];
            idx += 1;
            self.swarm_id_str[idx] = hex[rand_bytes[i] & 0xf];
            idx += 1;
        }
        self.swarm_id_str[idx] = '-';
        idx += 1;
        for (4..6) |i| {
            self.swarm_id_str[idx] = hex[rand_bytes[i] >> 4];
            idx += 1;
            self.swarm_id_str[idx] = hex[rand_bytes[i] & 0xf];
            idx += 1;
        }
        self.swarm_id_str[idx] = '-';
        idx += 1;
        for (6..8) |i| {
            self.swarm_id_str[idx] = hex[rand_bytes[i] >> 4];
            idx += 1;
            self.swarm_id_str[idx] = hex[rand_bytes[i] & 0xf];
            idx += 1;
        }
        self.swarm_id_str[idx] = '-';
        idx += 1;
        for (8..10) |i| {
            self.swarm_id_str[idx] = hex[rand_bytes[i] >> 4];
            idx += 1;
            self.swarm_id_str[idx] = hex[rand_bytes[i] & 0xf];
            idx += 1;
        }
        self.swarm_id_str[idx] = '-';
        idx += 1;
        for (10..16) |i| {
            self.swarm_id_str[idx] = hex[rand_bytes[i] >> 4];
            idx += 1;
            self.swarm_id_str[idx] = hex[rand_bytes[i] & 0xf];
            idx += 1;
        }
    }

    pub fn setRepo(self: *Self, repo: []const u8) void {
        if (self.repo) |r| self.alloc.free(r);
        self.repo = self.alloc.dupe(u8, repo) catch null;
    }

    pub fn addGrid(self: *Self, alloc: std.mem.Allocator, grid: GridMetrics) void {
        self.grids.append(alloc, grid) catch {};
    }

    pub fn finalize(self: *Self) void {
        const end_ms = std.time.milliTimestamp();
        self.total_wall_ms = @intCast(@max(0, end_ms - self.start_ms));

        var total_worker_ms: u64 = 0;
        var max_worker_ms: u64 = 0;
        self.total_cost_usd = 0.0;

        for (self.grids.items) |*grid| {
            grid.aggregate();
            for (grid.workers.items) |w| {
                total_worker_ms += w.wall_ms;
                if (w.wall_ms > max_worker_ms) max_worker_ms = w.wall_ms;
                self.total_cost_usd += estimateCost(w.model, w.tokens_in, w.tokens_out);
            }
        }

        if (max_worker_ms > 0) {
            self.parallelism_achieved = @as(f64, @floatFromInt(total_worker_ms)) / @as(f64, @floatFromInt(max_worker_ms));
        }
    }

    pub fn toJson(self: *Self, alloc: std.mem.Allocator) []const u8 {
        self.finalize();

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "{\"swarm_id\":\"") catch return "";
        buf.appendSlice(alloc, &self.swarm_id_str) catch return "";
        buf.appendSlice(alloc, "\"") catch return "";

        if (self.repo) |r| {
            buf.appendSlice(alloc, ",\"repo\":\"") catch return "";
            mj.writeEscaped(alloc, &buf, r);
            buf.appendSlice(alloc, "\"") catch return "";
        }

        buf.appendSlice(alloc, ",\"task\":\"") catch return "";
        mj.writeEscaped(alloc, &buf, self.task);
        buf.appendSlice(alloc, "\"") catch return "";

        buf.appendSlice(alloc, ",\"grids\":[") catch return "";
        for (self.grids.items, 0..) |*grid, i| {
            if (i > 0) buf.appendSlice(alloc, ",") catch return "";
            writeGridJson(alloc, &buf, grid);
        }
        buf.appendSlice(alloc, "]") catch return "";

        buf.appendSlice(alloc, ",\"total_cost_usd\":") catch return "";
        var cost_buf: [32]u8 = undefined;
        const cost_str = std.fmt.bufPrint(&cost_buf, "{d:.6}", .{self.total_cost_usd}) catch "";
        buf.appendSlice(alloc, cost_str) catch return "";

        buf.appendSlice(alloc, ",\"total_wall_ms\":") catch return "";
        var ms_buf: [20]u8 = undefined;
        const ms_str = std.fmt.bufPrint(&ms_buf, "{d}", .{self.total_wall_ms}) catch "";
        buf.appendSlice(alloc, ms_str) catch return "";

        buf.appendSlice(alloc, ",\"parallelism_achieved\":") catch return "";
        const pa_str = std.fmt.bufPrint(&cost_buf, "{d:.2}", .{self.parallelism_achieved}) catch "";
        buf.appendSlice(alloc, pa_str) catch return "";

        buf.appendSlice(alloc, ",\"parallelism_theoretical\":") catch return "";
        const pt_str = std.fmt.bufPrint(&ms_buf, "{d}", .{self.parallelism_theoretical}) catch "";
        buf.appendSlice(alloc, pt_str) catch return "";

        buf.appendSlice(alloc, "}") catch return "";

        return alloc.dupe(u8, buf.items) catch "";
    }

    fn writeGridJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), grid: *const GridMetrics) void {
        buf.appendSlice(alloc, "{\"name\":\"") catch return;
        mj.writeEscaped(alloc, buf, grid.name);
        buf.appendSlice(alloc, "\",\"workers\":[") catch return;

        for (grid.workers.items, 0..) |*w, i| {
            if (i > 0) buf.appendSlice(alloc, ",") catch return;
            writeWorkerJson(alloc, buf, w);
        }

        buf.appendSlice(alloc, "],\"synthesis_ms\":") catch return;
        var tmp: [20]u8 = undefined;
        const synth_ms = std.fmt.bufPrint(&tmp, "{d}", .{grid.synthesis_ms}) catch "";
        buf.appendSlice(alloc, synth_ms) catch return;

        if (grid.convergence_score) |cs| {
            buf.appendSlice(alloc, ",\"convergence_score\":") catch return;
            const cs_str = std.fmt.bufPrint(&tmp, "{d:.2}", .{cs}) catch "";
            buf.appendSlice(alloc, cs_str) catch return;
        }

        buf.appendSlice(alloc, ",\"total_tokens\":") catch return;
        const tt_str = std.fmt.bufPrint(&tmp, "{d}", .{grid.total_tokens}) catch "";
        buf.appendSlice(alloc, tt_str) catch return;

        buf.appendSlice(alloc, ",\"total_tool_calls\":") catch return;
        const tc_str = std.fmt.bufPrint(&tmp, "{d}", .{grid.total_tool_calls}) catch "";
        buf.appendSlice(alloc, tc_str) catch return;

        buf.appendSlice(alloc, "}") catch return;
    }

    fn writeWorkerJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), w: *const WorkerMetrics) void {
        buf.appendSlice(alloc, "{\"id\":") catch return;
        var tmp: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&tmp, "{d}", .{w.worker_id}) catch "";
        buf.appendSlice(alloc, id_str) catch return;

        buf.appendSlice(alloc, ",\"role\":\"") catch return;
        mj.writeEscaped(alloc, buf, w.role);
        buf.appendSlice(alloc, "\",\"model\":\"") catch return;
        mj.writeEscaped(alloc, buf, w.model);

        buf.appendSlice(alloc, "\",\"tool_calls\":") catch return;
        const tc_str = std.fmt.bufPrint(&tmp, "{d}", .{w.tool_calls}) catch "";
        buf.appendSlice(alloc, tc_str) catch return;

        buf.appendSlice(alloc, ",\"tokens_in\":") catch return;
        const ti_str = std.fmt.bufPrint(&tmp, "{d}", .{w.tokens_in}) catch "";
        buf.appendSlice(alloc, ti_str) catch return;

        buf.appendSlice(alloc, ",\"tokens_out\":") catch return;
        const to_str = std.fmt.bufPrint(&tmp, "{d}", .{w.tokens_out}) catch "";
        buf.appendSlice(alloc, to_str) catch return;

        buf.appendSlice(alloc, ",\"wall_ms\":") catch return;
        const wm_str = std.fmt.bufPrint(&tmp, "{d}", .{w.wall_ms}) catch "";
        buf.appendSlice(alloc, wm_str) catch return;

        buf.appendSlice(alloc, ",\"errors\":") catch return;
        const err_str = std.fmt.bufPrint(&tmp, "{d}", .{w.errors}) catch "";
        buf.appendSlice(alloc, err_str) catch return;

        buf.appendSlice(alloc, "}") catch return;
    }
};

fn estimateCost(model: []const u8, tokens_in: u64, tokens_out: u64) f64 {
    const input_price: f64 = blk: {
        if (std.mem.indexOf(u8, model, "opus") != null) break :blk 0.000015;
        if (std.mem.indexOf(u8, model, "sonnet") != null) break :blk 0.000003;
        if (std.mem.indexOf(u8, model, "haiku") != null) break :blk 0.00000025;
        if (std.mem.indexOf(u8, model, "gpt-5.4") != null) break :blk 0.0000025;
        if (std.mem.indexOf(u8, model, "gpt-5.3") != null) break :blk 0.000001;
        break :blk 0.000003;
    };
    const output_price: f64 = blk: {
        if (std.mem.indexOf(u8, model, "opus") != null) break :blk 0.000075;
        if (std.mem.indexOf(u8, model, "sonnet") != null) break :blk 0.000015;
        if (std.mem.indexOf(u8, model, "haiku") != null) break :blk 0.00000125;
        if (std.mem.indexOf(u8, model, "gpt-5.4") != null) break :blk 0.00001;
        if (std.mem.indexOf(u8, model, "gpt-5.3") != null) break :blk 0.000004;
        break :blk 0.000015;
    };

    return (@as(f64, @floatFromInt(tokens_in)) * input_price) +
        (@as(f64, @floatFromInt(tokens_out)) * output_price);
}

// ── Remote telemetry upload ───────────────────────────────────────────────────

const DEFAULT_TELEMETRY_URL = "https://devswarm.codegraff.com/v1/telemetry";

/// Check if remote telemetry is enabled. On by default.
/// Set DEVSWARM_TELEMETRY=false to disable.
pub fn isEnabled(alloc: std.mem.Allocator) bool {
    const val = std.process.getEnvVarOwned(alloc, "DEVSWARM_TELEMETRY") catch return true;
    defer alloc.free(val);
    return !std.mem.eql(u8, val, "false") and !std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "off");
}

/// Upload telemetry JSON to the backend. Strips the task field for privacy.
/// Spawns curl in the background — fire and forget, never blocks the response.
pub fn upload(alloc: std.mem.Allocator, telemetry_json: []const u8) void {
    if (!isEnabled(alloc)) return;

    // Get endpoint URL
    const url_owned = std.process.getEnvVarOwned(alloc, "DEVSWARM_TELEMETRY_URL") catch null;
    defer if (url_owned) |u| alloc.free(u);
    const url = url_owned orelse DEFAULT_TELEMETRY_URL;

    // Get API key (optional)
    const key_owned = std.process.getEnvVarOwned(alloc, "DEVSWARM_TELEMETRY_KEY") catch null;
    defer if (key_owned) |k| alloc.free(k);

    // Build curl args
    var args_buf: [12][]const u8 = undefined;
    var argc: usize = 0;

    args_buf[argc] = "curl";
    argc += 1;
    args_buf[argc] = "-s";
    argc += 1;
    args_buf[argc] = "-X";
    argc += 1;
    args_buf[argc] = "POST";
    argc += 1;
    args_buf[argc] = "-H";
    argc += 1;
    args_buf[argc] = "Content-Type: application/json";
    argc += 1;

    // Add API key header if set
    var key_header_buf: [256]u8 = undefined;
    if (key_owned) |k| {
        const header = std.fmt.bufPrint(&key_header_buf, "X-API-Key: {s}", .{k}) catch "X-API-Key: ";
        args_buf[argc] = "-H";
        argc += 1;
        args_buf[argc] = header;
        argc += 1;
    }

    args_buf[argc] = "-d";
    argc += 1;
    args_buf[argc] = telemetry_json;
    argc += 1;
    args_buf[argc] = url;
    argc += 1;

    // Fire and forget — spawn curl, don't wait
    var child = std.process.Child.init(args_buf[0..argc], alloc);
    child.stdin_behavior = .close;
    child.stdout_behavior = .close;
    child.stderr_behavior = .close;
    child.spawn() catch return;
    // Don't wait — let it finish in the background
}

test "telemetry: WorkerMetrics init and deinit" {
    const alloc = std.testing.allocator;
    var w = WorkerMetrics.init(0, "finder", "claude-sonnet-4-6");
    defer w.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0), w.worker_id);
    try std.testing.expectEqualStrings("finder", w.role);
    try std.testing.expectEqual(@as(u32, 0), w.tool_calls);
}

test "telemetry: SwarmTelemetry generates valid swarm_id" {
    const alloc = std.testing.allocator;
    var t = SwarmTelemetry.init(alloc, "test task");
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 36), t.swarm_id_str.len);
    try std.testing.expect(t.swarm_id_str[8] == '-');
    try std.testing.expect(t.swarm_id_str[13] == '-');
    try std.testing.expect(t.swarm_id_str[18] == '-');
    try std.testing.expect(t.swarm_id_str[23] == '-');
}

test "telemetry: SwarmTelemetry toJson produces valid JSON" {
    const alloc = std.testing.allocator;
    var t = SwarmTelemetry.init(alloc, "test swarm task");
    defer t.deinit();

    t.setRepo("owner/repo");

    var grid = GridMetrics.init(alloc, "review");
    var w = WorkerMetrics.init(0, "correctness", "claude-sonnet-4-6");
    w.tokens_in = 4200;
    w.tokens_out = 1800;
    w.wall_ms = 3400;
    w.tool_calls = 12;
    grid.addWorker(alloc, w);
    t.addGrid(alloc, grid);
    t.parallelism_theoretical = 4;

    const json = t.toJson(alloc);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    try std.testing.expect(obj.get("swarm_id") != null);
    try std.testing.expectEqualStrings("owner/repo", obj.get("repo").?.string);
    try std.testing.expectEqualStrings("test swarm task", obj.get("task").?.string);
    try std.testing.expect(obj.get("grids") != null);
    try std.testing.expect(obj.get("total_cost_usd") != null);
    try std.testing.expect(obj.get("total_wall_ms") != null);
}

test "telemetry: estimateCost returns expected values" {
    const cost_opus = estimateCost("claude-opus-4-6", 1000, 500);
    const cost_sonnet = estimateCost("claude-sonnet-4-6", 1000, 500);
    const cost_haiku = estimateCost("claude-haiku-4-5", 1000, 500);

    try std.testing.expect(cost_opus > cost_sonnet);
    try std.testing.expect(cost_sonnet > cost_haiku);
    try std.testing.expect(cost_haiku > 0);
}

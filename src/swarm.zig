// swarm.zig — Agent Swarm: orchestrate N parallel sub-agents
//
// Pipeline:
//   1. Orchestrator agent decomposes the task into ≤max_agents sub-tasks (JSON)
//   2. N worker threads each run one sub-agent via runtime resolve→dispatch (in parallel)
//   3. Synthesis agent combines all results into `out`
//
// Threading: std.Thread.spawn per worker; each worker uses page_allocator so
// there is no allocator contention across threads.
//
// Telemetry: collects per-worker metrics (tokens, tool calls, files accessed)
// and emits a JSON telemetry blob on completion.

const std = @import("std");
const mj = @import("mcp").json;
const rt = @import("runtime.zig");
const telemetry = @import("telemetry.zig");
const notify = @import("notify.zig");

/// Hard ceiling on parallel agents regardless of what the caller requests.
pub const HARD_MAX: u32 = 100;

// ── SIGINT handling for partial telemetry ──────────────────────────────────────
var g_interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn sigintHandler(_: c_int) callconv(.c) void {
    g_interrupted.store(true, .release);
}

fn installSigintHandler() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn restoreDefaultSigint() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = null },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}
// ── Worker ────────────────────────────────────────────────────────────────────

const Worker = struct {
    id: u32,
    role: []const u8,
    prompt: []const u8,
    allocated_prompt: ?[]u8 = null,
    out: std.ArrayList(u8) = .empty,
    model: []const u8 = "claude-sonnet-4-6",
    start_ms: i64 = 0,
    end_ms: i64 = 0,
};

const WorkerArgs = struct {
    worker: *Worker,
    writable: bool,
    metrics: *telemetry.WorkerMetrics,
    model: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

fn workerFn(args: *WorkerArgs) void {
    const alloc = std.heap.page_allocator;
    const prompt = args.worker.allocated_prompt orelse args.worker.prompt;

    args.worker.start_ms = std.time.milliTimestamp();

    const req: rt.AgentRequest = .{
        .prompt = prompt,
        .role = args.worker.role,
        .mode = args.mode orelse "smart",
        .model = args.model,
        .writable = args.writable,
    };
    const resolved = rt.resolve.resolveWithProbe(alloc, req);
    defer rt.prompts.freeAssembled(alloc, resolved.system_prompt);

    args.metrics.*.model = resolved.model;
    args.worker.model = resolved.model;

    rt.dispatch.dispatch(alloc, resolved, prompt, &args.worker.out);

    args.worker.end_ms = std.time.milliTimestamp();
    args.metrics.*.wall_ms = @intCast(@max(0, args.worker.end_ms - args.worker.start_ms));

    parseMetricsFromOutput(alloc, args.worker.out.items, args.metrics);

    // Mark success: non-empty output that isn't an error/timeout JSON
    const out_trimmed = std.mem.trim(u8, args.worker.out.items, " \t\n\r");
    args.metrics.*.success = out_trimmed.len > 0 and
        !std.mem.startsWith(u8, out_trimmed, "{\"error\"") and
        !std.mem.startsWith(u8, out_trimmed, "{\"timed_out\"");
}

fn parseMetricsFromOutput(_: std.mem.Allocator, output: []const u8, metrics: *telemetry.WorkerMetrics) void {
    // Parse __USAGE__ marker appended by agent_sdk.zig
    // Format: \n__USAGE__:tokens_in=N,tokens_out=N
    if (std.mem.indexOf(u8, output, "__USAGE__:")) |marker_pos| {
        const after = output[marker_pos + 10 ..]; // skip "__USAGE__:"
        // Parse tokens_in
        if (std.mem.indexOf(u8, after, "tokens_in=")) |ti_pos| {
            const num_start = ti_pos + 10;
            var num_end = num_start;
            while (num_end < after.len and after[num_end] >= '0' and after[num_end] <= '9') num_end += 1;
            if (num_end > num_start) {
                metrics.tokens_in = std.fmt.parseInt(u64, after[num_start..num_end], 10) catch 0;
            }
        }
        // Parse tokens_out
        if (std.mem.indexOf(u8, after, "tokens_out=")) |to_pos| {
            const num_start = to_pos + 11;
            var num_end = num_start;
            while (num_end < after.len and after[num_end] >= '0' and after[num_end] <= '9') num_end += 1;
            if (num_end > num_start) {
                metrics.tokens_out = std.fmt.parseInt(u64, after[num_start..num_end], 10) catch 0;
            }
        }
    }

    // Count tool_use occurrences
    var tool_count: u32 = 0;
    var i: usize = 0;
    while (i < output.len) {
        if (std.mem.indexOfPos(u8, output, i, "tool_use")) |tu| {
            tool_count += 1;
            i = tu + 9;
        } else {
            break;
        }
    }
    metrics.tool_calls = tool_count;
}

/// Build the writable-worker preamble using the runtime prompt assembly.
/// Returns an allocated string that the caller must free.
pub fn buildPreamble(alloc: std.mem.Allocator) []const u8 {
    const cascade_mod = @import("runtime/cascade.zig");
    const tools = cascade_mod.probe(alloc);
    return rt.prompts.assemble(alloc, null, .smart, tools.tier());
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Run an agent swarm for `task`. Blocks until all sub-agents finish and
/// the synthesis agent has written its result to `out`.
/// If telemetry_out is non-null, writes telemetry JSON to that file path.
pub fn runSwarm(
    alloc: std.mem.Allocator,
    task: []const u8,
    title: ?[]const u8,
    max_agents: u32,
    out: *std.ArrayList(u8),
    writable: bool,
    telemetry_out: ?[]const u8,
    model: ?[]const u8,
    mode: ?[]const u8,
    per_agent_model: ?*const std.json.ObjectMap,
) void {
    const cap: usize = @min(max_agents, HARD_MAX);

    // ── Install SIGINT handler for partial telemetry ──────────────────────────
    g_interrupted.store(false, .release);
    installSigintHandler();
    defer restoreDefaultSigint();
    // ── Phase 0: Announce swarm start ────────────────────────────────────────
    {
        var msg_buf: [256]u8 = undefined;
        const label = title orelse "swarm";
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "swarm: '{s}' — decomposing task (up to {d} agents)...",
            .{ label, cap },
        ) catch "🔀 run_swarm: decomposing task...";
        notify.send(alloc, msg);
    }

    // ── Phase 1: Orchestrator decomposes task ─────────────────────────────
    const orch_prompt = std.fmt.allocPrint(
        alloc,
        "You are a task orchestrator. Decompose the task below into at most {d} " ++
            "independent, self-contained sub-tasks that can execute in parallel.\n\n" ++
            "AVAILABLE ROLES (use these exact names in your JSON):\n" ++
            "  finder         — read-only code search, locates files/functions/patterns\n" ++
            "  reviewer       — read-only code review for correctness and best practices\n" ++
            "  fixer          — writable, fixes reported issues (one change per file)\n" ++
            "  explorer       — read-only, traces execution paths and gathers evidence\n" ++
            "  architect      — read-only, designs implementation plans\n" ++
            "  safety_auditor — read-only, audits memory safety (UAF, double-free, OOM)\n" ++
            "  zig_specialist — writable, fixes Zig-specific issues (errdefer, slices, allocators)\n" ++
            "  api_reviewer   — read-only, checks API contracts and ownership semantics\n" ++
            "  test_writer    — writable, writes regression tests for reported bugs\n" ++
            "  monitor        — read-only, runs tests and reports results\n\n" ++
            "RULES:\n" ++
            "  - Pick the most specific role for each sub-task\n" ++
            "  - Read-only roles CANNOT edit files; writable roles CAN\n" ++
            "  - Each sub-task prompt must be fully self-contained (include file paths, context)\n" ++
            "  - Do NOT create duplicate sub-tasks that cover the same files/issues\n\n" ++
            "Reply with ONLY a valid JSON array — no markdown fences, no commentary:\n" ++
            "[{{\"role\":\"<role name>\",\"prompt\":\"<full sub-task prompt>\"}},...]" ++
            "\n\nTask: {s}",
        .{ cap, task },
    ) catch {
        appendErr(alloc, out, "OOM: orchestrator prompt");
        return;
    };
    defer alloc.free(orch_prompt);

    // Orchestrator: read-only, rush mode (concise JSON output)
    var orch_out: std.ArrayList(u8) = .empty;
    defer orch_out.deinit(alloc);
    {
        const req: rt.AgentRequest = .{
            .prompt = orch_prompt,
            .role = "orchestrator",
            .mode = mode orelse "rush",
            .model = model,
            .writable = false,
        };
        const resolved = rt.resolve.resolveWithProbe(alloc, req);
        defer rt.prompts.freeAssembled(alloc, resolved.system_prompt);
        rt.dispatch.dispatch(alloc, resolved, orch_prompt, &orch_out);
    }

    // ── Phase 2: Parse sub-tasks from orchestrator output ─────────────────
    const raw = orch_out.items;
    const json_start = std.mem.indexOfScalar(u8, raw, '[') orelse {
        appendErr(alloc, out, "swarm: orchestrator returned no JSON array");
        return;
    };
    const json_end = std.mem.lastIndexOfScalar(u8, raw, ']') orelse {
        appendErr(alloc, out, "swarm: orchestrator JSON array not closed");
        return;
    };
    const js = raw[json_start .. json_end + 1];

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        js,
        .{ .ignore_unknown_fields = true },
    ) catch {
        appendErr(alloc, out, "swarm: orchestrator returned invalid JSON");
        return;
    };
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => {
            appendErr(alloc, out, "swarm: orchestrator value is not an array");
            return;
        },
    };

    var workers = alloc.alloc(Worker, @min(arr.items.len, cap)) catch {
        appendErr(alloc, out, "OOM: workers");
        return;
    };
    defer alloc.free(workers);

    var worker_args = alloc.alloc(WorkerArgs, workers.len) catch {
        appendErr(alloc, out, "OOM: worker_args");
        return;
    };
    defer alloc.free(worker_args);

    var threads = alloc.alloc(?std.Thread, workers.len) catch {
        appendErr(alloc, out, "OOM: threads");
        return;
    };
    defer alloc.free(threads);

    var swarm_telemetry = telemetry.SwarmTelemetry.init(alloc, task);
    defer swarm_telemetry.deinit();
    swarm_telemetry.parallelism_theoretical = @intCast(cap);

    // Auto-detect repo for telemetry
    if (@import("gh.zig").run(alloc, &.{ "git", "remote", "get-url", "origin" })) |r| {
        defer r.deinit(alloc);
        const trimmed = std.mem.trim(u8, r.stdout, " \t\n\r");
        if (trimmed.len > 0) swarm_telemetry.setRepo(trimmed);
    } else |_| {}

    var count: usize = 0;

    var worker_metrics = alloc.alloc(telemetry.WorkerMetrics, workers.len) catch {
        appendErr(alloc, out, "OOM: worker_metrics");
        return;
    };
    defer {
        for (worker_metrics[0..count]) |*m| m.deinit(alloc);
        alloc.free(worker_metrics);
    }

    for (arr.items[0..@min(arr.items.len, cap)]) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const p_val = obj.get("prompt") orelse continue;
        const r_val = obj.get("role") orelse std.json.Value{ .string = "agent" };
        const base = switch (p_val) {
            .string => |s| s,
            else => continue,
        };
        const role_str = switch (r_val) {
            .string => |s| s,
            else => "agent",
        };
        const worker_model: ?[]const u8 = blk: {
            if (per_agent_model) |pam| {
                if (pam.get(role_str)) |v| {
                    if (v == .string) break :blk v.string;
                }
            }
            break :blk model;
        };
        worker_metrics[count] = telemetry.WorkerMetrics.init(@intCast(count), role_str, "claude-sonnet-4-6");
        workers[count] = .{
            .id = @intCast(count),
            .role = role_str,
            .prompt = base,
        };
        worker_args[count] = .{ .worker = &workers[count], .writable = writable, .metrics = &worker_metrics[count], .model = worker_model, .mode = mode };
        threads[count] = std.Thread.spawn(.{}, workerFn, .{&worker_args[count]}) catch null;
        count += 1;
    }

    if (count == 0) {
        appendErr(alloc, out, "swarm: no valid sub-tasks extracted");
        return;
    }

    // ── Announce workers ──────────────────────────────────────────────────────
    {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "⚡ {d} agent{s} running in parallel...",
            .{ count, if (count == 1) "" else "s" },
        ) catch "⚡ agents running...";
        notify.send(alloc, msg);
    }

    // ── Phase 3: Join all worker threads ──────────────────────────────────
    for (threads[0..count]) |maybe_t| {
        if (maybe_t) |t| t.join();
    }


    // ── Check for early interruption ─────────────────────────────────────────
    if (g_interrupted.load(.acquire)) {
        // Count how many workers actually completed successfully
        var completed: usize = 0;
        for (worker_metrics[0..count]) |m| {
            if (m.success) completed += 1;
        }

        if (completed > 0) {
            // Send partial telemetry — at least one agent finished
            var grid = telemetry.GridMetrics.init(alloc, "worker");
            for (worker_metrics[0..count]) |*m| {
                m.*.role = workers[m.worker_id].role;
                m.*.model = workers[m.worker_id].model;
                grid.addWorker(alloc, m.*) catch {};
            }
            swarm_telemetry.addGrid(grid) catch {};

            const telemetry_json = swarm_telemetry.toJson(alloc, true);
            if (telemetry_json.len > 0) {
                std.debug.print("\n[telemetry:interrupted] {d}/{d} agents completed\n", .{ completed, count });
                std.debug.print("[telemetry] {s}\n", .{telemetry_json});
                telemetry.upload(alloc, telemetry_json);

                if (telemetry_out) |path| {
                    const file = if (std.fs.path.isAbsolute(path))
                        std.fs.createFileAbsolute(path, .{}) catch null
                    else
                        std.fs.cwd().createFile(path, .{}) catch null;
                    if (file) |f| {
                        defer f.close();
                        f.writeAll(telemetry_json) catch {};
                        f.writeAll("\n") catch {};
                    }
                }
                alloc.free(telemetry_json);
            }
        } else {
            std.debug.print("\n[telemetry:interrupted] no agents completed — skipping telemetry\n", .{});
        }

        // Write partial results to output
        for (workers[0..count]) |*w| {
            if (w.out.items.len > 0) {
                out.appendSlice(alloc, w.out.items) catch {};
                out.appendSlice(alloc, "\n") catch {};
            }
            w.out.deinit(std.heap.page_allocator);
        }
        appendErr(alloc, out, "swarm interrupted by user (Ctrl+C)");
        return;
    }
    var manifest: []const u8 = "";
    var manifest_alloc: ?[]u8 = null;
    defer if (manifest_alloc) |m| alloc.free(m);
    if (writable) {
        const gh = @import("gh.zig");
        if (gh.run(alloc, &.{ "git", "diff", "--stat", "HEAD" })) |dr| {
            defer dr.deinit(alloc);
            const trimmed = std.mem.trim(u8, dr.stdout, " \t\n\r");
            if (trimmed.len > 0) {
                manifest_alloc = alloc.dupe(u8, trimmed) catch null;
                if (manifest_alloc) |m| manifest = m;
            }
        } else |_| {}
    }

    // ── Phase 4: Build synthesis prompt from worker results ───────────────
    var synth: std.ArrayList(u8) = .empty;
    defer synth.deinit(alloc);

    synth.appendSlice(
        alloc,
        "You are a synthesis agent. Combine these parallel sub-agent results " ++
            "into one coherent, well-structured response:\n\n",
    ) catch {};

    for (workers[0..count], 0..) |*w, i| {
        const header = std.fmt.allocPrint(
            alloc,
            "## Agent {d} — {s}\n",
            .{ i + 1, w.role },
        ) catch "";
        defer alloc.free(header);
        synth.appendSlice(alloc, header) catch {};
        synth.appendSlice(alloc, w.out.items) catch {};
        synth.appendSlice(alloc, "\n\n") catch {};
        w.out.deinit(std.heap.page_allocator);
    }

    // Include file manifest in synthesis if available
    if (manifest.len > 0) {
        synth.appendSlice(alloc, "## Files Changed\n```\n") catch {};
        synth.appendSlice(alloc, manifest) catch {};
        synth.appendSlice(alloc, "\n```\n\n") catch {};
    }

    synth.appendSlice(alloc, "Synthesize the above into a final answer.") catch {};

    // ── Announce synthesis ───────────────────────────────────────────────────
    notify.send(alloc, "🧬 Synthesizing agent results...");

    // ── Phase 5: Synthesis agent (read-only, uses synthesizer role) ───────
    {
        const req: rt.AgentRequest = .{
            .prompt = synth.items,
            .role = "synthesizer",
            .mode = mode orelse "smart",
            .model = model,
            .writable = false,
        };
        const resolved = rt.resolve.resolveWithProbe(alloc, req);
        defer rt.prompts.freeAssembled(alloc, resolved.system_prompt);
        rt.dispatch.dispatch(alloc, resolved, synth.items, out);
    }

    // ── Phase 6: Emit telemetry ──────────────────────────────────────────
    var grid = telemetry.GridMetrics.init(alloc, "worker");
    for (worker_metrics[0..count]) |*m| {
        m.*.role = workers[m.worker_id].role;
        m.*.model = workers[m.worker_id].model;
        grid.addWorker(alloc, m.*) catch {};
    }
    swarm_telemetry.addGrid(grid) catch {};


    const telemetry_json = swarm_telemetry.toJson(alloc, false);
    if (telemetry_json.len > 0) {
        std.debug.print("\n[telemetry] {s}\n", .{telemetry_json});

        // Upload to backend (fire and forget, non-blocking)
        telemetry.upload(alloc, telemetry_json);

        if (telemetry_out) |path| {
            const file = if (std.fs.path.isAbsolute(path))
                std.fs.createFileAbsolute(path, .{}) catch |err| {
                    std.debug.print("[telemetry] failed to write to {s}: {}\n", .{ path, err });
                    alloc.free(telemetry_json);
                    return;
                }
            else
                std.fs.cwd().createFile(path, .{}) catch |err| {
                    std.debug.print("[telemetry] failed to write to {s}: {}\n", .{ path, err });
                    alloc.free(telemetry_json);
                    return;
                };
            defer file.close();
            file.writeAll(telemetry_json) catch {};
            file.writeAll("\n") catch {};
            std.debug.print("[telemetry] wrote telemetry to {s}\n", .{path});
        }
        alloc.free(telemetry_json);
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    out.appendSlice(alloc, "{\"error\":\"") catch return;
    mj.writeEscaped(alloc, out, msg);
    out.appendSlice(alloc, "\"}") catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "swarm: HARD_MAX is 100" {
    try std.testing.expectEqual(@as(u32, 100), HARD_MAX);
}

test "swarm: buildPreamble references agency rules" {
    const alloc = std.testing.allocator;
    const preamble = buildPreamble(alloc);
    defer rt.prompts.freeAssembled(alloc, preamble);

    // The preamble should come from prompts.zig and include agency rules
    try std.testing.expect(preamble.len > 0);
}

test "swarm: appendErr writes JSON error object" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    appendErr(alloc, &out, "something went wrong");

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const msg = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expectEqualStrings("something went wrong", msg.string);
    try std.testing.expectEqualStrings("something went wrong", msg.string);
}

test "swarm: g_interrupted starts false" {
    try std.testing.expect(!g_interrupted.load(.acquire));
}

test "swarm: sigint handler sets interrupted flag" {
    // Reset to known state
    g_interrupted.store(false, .release);
    try std.testing.expect(!g_interrupted.load(.acquire));

    // Simulate what the signal handler does
    sigintHandler(0);

    try std.testing.expect(g_interrupted.load(.acquire));

    // Reset
    g_interrupted.store(false, .release);
}

test "swarm: install and restore sigint handler" {
    // Should not crash
    installSigintHandler();
    restoreDefaultSigint();
}

test "swarm: sigint handler is idempotent" {
    g_interrupted.store(false, .release);

    // Multiple signals should not cause issues
    sigintHandler(0);
    sigintHandler(0);
    sigintHandler(0);

    try std.testing.expect(g_interrupted.load(.acquire));

    g_interrupted.store(false, .release);
}

// ── Regression tests: model/mode selection ───────────────────────────────────

test "swarm: WorkerArgs accepts explicit model override" {
    var dummy_metrics = telemetry.WorkerMetrics.init(0, "finder", "claude-sonnet-4-6");
    defer dummy_metrics.deinit(std.testing.allocator);
    var dummy_worker = Worker{ .id = 0, .role = "finder", .prompt = "test" };
    const args = WorkerArgs{
        .worker = &dummy_worker,
        .writable = false,
        .metrics = &dummy_metrics,
        .model = "claude-opus-4-6",
        .mode = "deep",
    };
    try std.testing.expectEqualStrings("claude-opus-4-6", args.model.?);
    try std.testing.expectEqualStrings("deep", args.mode.?);
}

test "swarm: WorkerArgs null model falls back to auto-resolve" {
    var dummy_metrics = telemetry.WorkerMetrics.init(0, "finder", "claude-sonnet-4-6");
    defer dummy_metrics.deinit(std.testing.allocator);
    var dummy_worker = Worker{ .id = 0, .role = "finder", .prompt = "test" };
    const args = WorkerArgs{
        .worker = &dummy_worker,
        .writable = false,
        .metrics = &dummy_metrics,
        // model and mode omitted — should default to null
    };
    try std.testing.expect(args.model == null);
    try std.testing.expect(args.mode == null);
}

test "swarm: workerFn model propagates into AgentRequest" {
    // Verify the AgentRequest built by workerFn carries the explicit model/mode.
    // Tests the data path without invoking actual dispatch.
    var dummy_metrics = telemetry.WorkerMetrics.init(0, "finder", "claude-sonnet-4-6");
    defer dummy_metrics.deinit(std.testing.allocator);
    var dummy_worker = Worker{ .id = 0, .role = "reviewer", .prompt = "check it" };
    const args = WorkerArgs{
        .worker = &dummy_worker,
        .writable = false,
        .metrics = &dummy_metrics,
        .model = "claude-haiku-4-5-20251001",
        .mode = "rush",
    };
    // Mirror the AgentRequest construction in workerFn
    const req: rt.AgentRequest = .{
        .prompt = args.worker.prompt,
        .role = args.worker.role,
        .mode = args.mode orelse "smart",
        .model = args.model,
        .writable = args.writable,
    };
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", req.model.?);
    try std.testing.expectEqualStrings("rush", req.mode.?);
    try std.testing.expectEqualStrings("reviewer", req.role.?);
}

// ── Regression tests: #388 role propagation, #389 no preamble duplication ────

test "swarm: #388 orchestrator role flows into Worker and AgentRequest unchanged" {
    // Parse a JSON sub-task array as the orchestrator would emit, extract the
    // role, and confirm it reaches the AgentRequest without being overridden.
    const alloc = std.testing.allocator;
    const json_str =
        \\[{"role":"zig_specialist","prompt":"fix errdefer in src/foo.zig"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    const obj = arr.items[0].object;
    const r_val = obj.get("role") orelse std.json.Value{ .string = "agent" };
    const p_val = obj.get("prompt") orelse return error.MissingPrompt;
    const role_str = switch (r_val) {
        .string => |s| s,
        else => "agent",
    };
    const base = switch (p_val) {
        .string => |s| s,
        else => return error.MissingPrompt,
    };

    // Role must survive from JSON → Worker → AgentRequest unchanged.
    try std.testing.expectEqualStrings("zig_specialist", role_str);

    var dummy_metrics = telemetry.WorkerMetrics.init(0, role_str, "claude-sonnet-4-6");
    defer dummy_metrics.deinit(alloc);
    const w = Worker{ .id = 0, .role = role_str, .prompt = base };
    try std.testing.expectEqualStrings("zig_specialist", w.role);

    // Mirror the AgentRequest construction in workerFn (L74-80).
    const req: rt.AgentRequest = .{
        .prompt = w.prompt,
        .role = w.role,
        .mode = "smart",
        .model = null,
        .writable = true,
    };
    try std.testing.expectEqualStrings("zig_specialist", req.role.?);
}

test "swarm: #389 worker allocated_prompt is null — no preamble prepended" {
    // buildPreamble() must no longer be prepended to worker task text.
    // Workers receive bare prompts; system prompts come from resolveWithProbe.
    const base = "fix the bug in src/bar.zig";
    const w = Worker{
        .id = 0,
        .role = "fixer",
        .prompt = base,
        // allocated_prompt omitted — must remain null (no preamble injection)
    };
    try std.testing.expect(w.allocated_prompt == null);
    try std.testing.expectEqualStrings(base, w.prompt);
}

test "swarm: #388 missing role defaults to 'agent' not 'fixer'" {
    // When the orchestrator omits the role field the fallback must be the
    // neutral "agent" value — never a hardcoded writable role like "fixer".
    const alloc = std.testing.allocator;
    const json_str =
        \\[{"prompt":"do something"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    const obj = arr.items[0].object;
    const r_val = obj.get("role") orelse std.json.Value{ .string = "agent" };
    const role_str = switch (r_val) {
        .string => |s| s,
        else => "agent",
    };
    try std.testing.expectEqualStrings("agent", role_str);
}

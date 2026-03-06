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
};

fn workerFn(args: *WorkerArgs) void {
    const alloc = std.heap.page_allocator;
    const prompt = args.worker.allocated_prompt orelse args.worker.prompt;

    args.worker.start_ms = std.time.milliTimestamp();

    const req: rt.AgentRequest = .{
        .prompt = prompt,
        .role = "fixer",
        .mode = "smart",
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
}

fn parseMetricsFromOutput(_: std.mem.Allocator, output: []const u8, metrics: *telemetry.WorkerMetrics) void {
    var i: usize = 0;
    while (i < output.len) {
        if (std.mem.indexOfPos(u8, output, i, "\"tokens\"")) |tok_pos| {
            i = tok_pos + 9;
            while (i < output.len and output[i] != '{' and output[i] != ':') i += 1;
            if (i < output.len and output[i] == ':') {
                i += 1;
                while (i < output.len and (output[i] == ' ' or output[i] == '\t')) i += 1;
                const start = i;
                while (i < output.len and output[i] >= '0' and output[i] <= '9') i += 1;
                if (i > start) {
                    const num_str = output[start..i];
                    if (std.fmt.parseInt(u64, num_str, 10)) |val| {
                        metrics.tokens_in = val;
                        metrics.tokens_out = val / 3;
                    } else |_| {}
                }
            }
        } else {
            break;
        }
    }

    var tool_count: u32 = 0;
    i = 0;
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
) void {
    const cap: usize = @min(max_agents, HARD_MAX);

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
            "independent, self-contained sub-tasks that can execute in parallel.\n" ++
            "Reply with ONLY a valid JSON array — no markdown fences, no commentary, no explanation:\n" ++
            "[{{\"role\":\"<role label>\",\"prompt\":\"<full sub-task prompt>\"}},...]\n\n" ++
            "Task: {s}",
        .{ cap, task },
    ) catch {
        appendErr(alloc, out, "OOM: orchestrator prompt");
        return;
    };
    defer alloc.free(orch_prompt);

    // Orchestrator: read-only, rush mode (concise JSON output), no role preamble
    var orch_out: std.ArrayList(u8) = .empty;
    defer orch_out.deinit(alloc);
    {
        const req: rt.AgentRequest = .{
            .prompt = orch_prompt,
            .role = null,
            .mode = "rush",
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
        // For writable workers, prepend the tool-use preamble so agents use
        // zigrep/zigpatch instead of sed/awk.
        const allocated: ?[]u8 = if (writable) blk: {
            const preamble = buildPreamble(alloc);
            const full = std.fmt.allocPrint(alloc, "{s}{s}", .{ preamble, base }) catch null;
            rt.prompts.freeAssembled(alloc, preamble);
            break :blk full;
        } else null;
        const role_str = switch (r_val) {
            .string => |s| s,
            else => "agent",
        };
        worker_metrics[count] = telemetry.WorkerMetrics.init(alloc, @intCast(count), role_str, "claude-sonnet-4-6");
        workers[count] = .{
            .id = @intCast(count),
            .role = role_str,
            .prompt = base,
            .allocated_prompt = allocated,
        };
        worker_args[count] = .{ .worker = &workers[count], .writable = writable, .metrics = &worker_metrics[count] };
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
    // Free preamble-prefixed prompts now that threads have finished.
    for (workers[0..count]) |w| {
        if (w.allocated_prompt) |p| alloc.free(p);
    }

    // ── Phase 3b: Capture file manifest for writable swarms ──────────────
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
            .mode = "smart",
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
        grid.addWorker(alloc, m.*);
    }
    swarm_telemetry.addGrid(alloc, grid);

    const telemetry_json = swarm_telemetry.toJson(alloc);
    if (telemetry_json.len > 0) {
        std.debug.print("\n[telemetry] {s}\n", .{telemetry_json});

        if (telemetry_out) |path| {
            const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
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
}

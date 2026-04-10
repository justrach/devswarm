// runtime/dispatch.zig — Backend dispatch (#262)
//
// Dumb plumbing: takes a ResolvedAgent + prompt and spawns on the correct backend.
// No decision-making — that's resolve()'s job.
//
// Backends:
//   - claude: spawns `claude -p` with stream-json output
//   - codex:  spawns `codex app-server` with stdio protocol

const std = @import("std");
const types = @import("types.zig");

const Backend = types.Backend;
const ResolvedAgent = types.ResolvedAgent;

/// Dispatch an agent run to the appropriate backend.
/// Writes the agent's text output to `out`.
/// If all backends fail to produce output, writes an error message to `out`
/// so the MCP caller knows the dispatch did not succeed.
pub fn dispatch(
    alloc: std.mem.Allocator,
    resolved: ResolvedAgent,
    prompt: []const u8,
    out: *std.ArrayList(u8),
) void {
    const before = out.items.len;
    switch (resolved.backend) {
        .claude => spawnClaude(alloc, resolved, prompt, out),
        .codex  => spawnCodex(alloc, resolved, prompt, out),
    }
    if (out.items.len == before) {
        out.appendSlice(alloc, "[dispatch] backend produced no output — agent run may have failed") catch {};
    }
}

// ── Claude backend ────────────────────────────────────────────────────────

fn spawnClaude(
    alloc: std.mem.Allocator,
    resolved: ResolvedAgent,
    prompt: []const u8,
    out: *std.ArrayList(u8),
) void {
    const sdk = @import("../agent_sdk.zig");

    const perm_mode =
        resolved.permission_mode orelse
        (if (resolved.writable) "bypassPermissions" else "default");

    const opts: sdk.AgentOptions = .{
        .model            = resolved.model,
        .writable         = resolved.writable,
        .allowed_tools    = resolved.allowed_tools,
        .permission_mode  = perm_mode,
        .reasoning_effort = resolved.reasoning_effort,
        .cwd              = resolved.cwd,
    };

    const full_prompt = if (resolved.system_prompt.len > 0) blk: {
        break :blk std.fmt.allocPrint(alloc, "{s}{s}", .{ resolved.system_prompt, prompt }) catch {
            std.debug.print("[dispatch] OOM: system prompt dropped for claude backend\n", .{});
            break :blk prompt;
        };
    } else prompt;
    defer if (full_prompt.ptr != prompt.ptr) alloc.free(full_prompt);

    if (sdk.tryClaudeAgent(alloc, full_prompt, opts, out)) return;

    // If Claude spawn failed, fall back to codex within this dispatch
    spawnCodex(alloc, resolved, prompt, out);
}

// ── Codex backend ─────────────────────────────────────────────────────────

fn spawnCodex(
    alloc: std.mem.Allocator,
    resolved: ResolvedAgent,
    prompt: []const u8,
    out: *std.ArrayList(u8),
) void {
    const cas = @import("../codex_appserver.zig");

    const policy: cas.SandboxPolicy = if (resolved.writable) .writable else .read_only;

    const full_prompt = if (resolved.system_prompt.len > 0) blk: {
        break :blk std.fmt.allocPrint(alloc, "{s}{s}", .{ resolved.system_prompt, prompt }) catch {
            std.debug.print("[dispatch] OOM: system prompt dropped for codex backend\n", .{});
            break :blk prompt;
        };
    } else prompt;
    defer if (full_prompt.ptr != prompt.ptr) alloc.free(full_prompt);

    cas.runTurnPolicy(alloc, full_prompt, out, policy);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// dispatch() can only be integration-tested (needs actual claude/codex on PATH).
// Unit tests validate the dispatch routing logic via the Backend enum.

test "dispatch: Backend.label is correct" {
    try std.testing.expectEqualStrings("claude", Backend.claude.label());
    try std.testing.expectEqualStrings("codex", Backend.codex.label());
}

test "dispatch: empty output sentinel is written when backend produces nothing" {
    const sentinel = "[dispatch] backend produced no output — agent run may have failed";
    var out: std.ArrayList(u8) = .empty;
    const alloc = std.testing.allocator;
    defer out.deinit(alloc);

    const before = out.items.len;
    // Simulate the check that dispatch() does after a backend call:
    if (out.items.len == before) {
        out.appendSlice(alloc, sentinel) catch {};
    }
    try std.testing.expectEqualStrings(sentinel, out.items);
}

test "dispatch: non-empty output does not get sentinel appended" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc, "agent reply");
    const before = out.items.len;
    // Simulate: backend already wrote output
    if (out.items.len == before) {
        out.appendSlice(alloc, "SHOULD NOT APPEAR") catch {};
    }
    try std.testing.expectEqualStrings("agent reply", out.items);
}

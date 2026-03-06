// notify.zig — MCP progress notifications
//
// Sends JSON-RPC notifications/message to the client while a long-running
// tool is executing.  Thread-safe — worker threads in run_swarm all share
// the same global notifier.
//
// The MCP client (Claude Code) displays these as status lines inline while
// "Running…" is shown.
//
// Usage:
//   notify.init(use_headers);            // once, at server startup
//   notify.send(alloc, "Phase 1/4: Orchestrator running…");   // any thread

const std = @import("std");

/// Call once at server startup with the framing mode in use.
pub fn init(use_headers: bool) void {
    g_use_headers = use_headers;
    g_ready = true;
}

/// Send a notifications/message to the MCP client.
/// Thread-safe.  No-ops if init() was not called.
pub fn send(alloc: std.mem.Allocator, message: []const u8) void {
    if (!g_ready) return;

    // Build JSON-escaped message string
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(alloc);
    escaped.append(alloc, '"') catch return;
    for (message) |c| {
        switch (c) {
            '"'  => escaped.appendSlice(alloc, "\\\"") catch return,
            '\\' => escaped.appendSlice(alloc, "\\\\") catch return,
            '\n' => escaped.appendSlice(alloc, "\\n")  catch return,
            '\r' => escaped.appendSlice(alloc, "\\r")  catch return,
            '\t' => escaped.appendSlice(alloc, "\\t")  catch return,
            else => escaped.append(alloc, c) catch return,
        }
    }
    escaped.append(alloc, '"') catch return;

    const payload = std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{{\"level\":\"info\",\"data\":{s}}}}}",
        .{escaped.items},
    ) catch return;
    defer alloc.free(payload);

    const stdout = std.fs.File.stdout();
    g_mutex.lock();
    defer g_mutex.unlock();

    if (g_use_headers) {
        const header = std.fmt.allocPrint(
            alloc, "Content-Length: {d}\r\n\r\n", .{payload.len},
        ) catch return;
        defer alloc.free(header);
        stdout.writeAll(header)   catch {};
        stdout.writeAll(payload)  catch {};
        stdout.writeAll("\r\n")   catch {};
    } else {
        stdout.writeAll(payload) catch {};
        stdout.writeAll("\n")    catch {};
    }
}

// ── Globals ───────────────────────────────────────────────────────────────────
var g_mutex:       std.Thread.Mutex = .{};
var g_use_headers: bool             = false;
var g_ready:       bool             = false;

// ── Tests ─────────────────────────────────────────────────────────────────────

test "notify: init sets ready flag" {
    // We can't easily test stdout writes in unit tests, but we can verify
    // the module compiles and the init path runs without error.
    init(false);
    // send() should be a no-op when called before init in a fresh process,
    // but after init it should not crash.
    send(std.testing.allocator, "test message");
}

// notify.zig — MCP progress notifications (keepalive heartbeats)
//
// Sends JSON-RPC notifications/message to the client while a long-running
// tool is executing.  Thread-safe — worker threads in run_swarm all share
// the same global writer mutex.
//
// The MCP client (Claude Code / external bridges) uses these as proof that
// the server is still alive.  Without periodic heartbeats, external MCP
// bridges time out long-running tool calls with MCP error -32001.
//
// Usage:
//   notify.init(use_headers);                          // once, at startup
//   notify.send(alloc, "agent 'explorer' running…");   // any thread

const std = @import("std");

/// Call once at server startup with the framing mode in use.
pub fn init(use_headers: bool) void {
    g_use_headers = use_headers;
    g_ready = true;
}

/// Send a notifications/message to the MCP client.
/// Thread-safe.  No-ops silently if init() was not called.
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
        stdout.writeAll(header)  catch {};
        stdout.writeAll(payload) catch {};
        stdout.writeAll("\r\n")  catch {};
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
    init(false);
    send(std.testing.allocator, "test message");
}

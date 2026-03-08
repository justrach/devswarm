// progress.zig — MCP progress notification emitter
//
// Writes `notifications/progress` JSON-RPC notifications to stdout mid-call.
// The MCP client (Claude Code) displays these as live status updates in the
// tool call view instead of just "Running…".
//
// Usage:
//   if (progress) |p| p.emit(alloc, 0.1, "decomposing task…");

const std = @import("std");

/// Holds the stdout handle and the progressToken from the MCP request _meta.
/// Pass as `?ProgressCtx` — null when client didn't send a token.
pub const ProgressCtx = struct {
    stdout: std.fs.File,
    token:  []const u8,

    /// Emit one `notifications/progress` notification.
    /// `progress` is 0.0–1.0. Silently no-ops if token is empty.
    pub fn emit(self: ProgressCtx, alloc: std.mem.Allocator, progress: f32, message: []const u8) void {
        if (self.token.len == 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc,
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\""
        ) catch return;

        // JSON-escape the token
        for (self.token) |c| {
            if (c == '"' or c == '\\') buf.append(alloc, '\\') catch return;
            buf.append(alloc, c) catch return;
        }

        var prog_buf: [16]u8 = undefined;
        const prog_s = std.fmt.bufPrint(&prog_buf, "{d:.2}", .{progress}) catch return;

        buf.appendSlice(alloc, "\",\"progress\":") catch return;
        buf.appendSlice(alloc, prog_s) catch return;
        buf.appendSlice(alloc, ",\"message\":\"") catch return;

        // JSON-escape the message
        for (message) |c| {
            if (c == '"' or c == '\\') buf.append(alloc, '\\') catch return;
            buf.append(alloc, c) catch return;
        }

        buf.appendSlice(alloc, "\"}}\n") catch return;
        _ = self.stdout.write(buf.items) catch 0;
    }
};

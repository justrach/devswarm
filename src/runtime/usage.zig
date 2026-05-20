// runtime/usage.zig — Usage tracking (#268)
//
// Tracks API calls per backend within a rolling 5-hour window.
// Used by resolve() to overflow to a secondary provider when the primary
// is nearing its quota.
//
// Thread-safe: all mutations guarded by mutex.

const std = @import("std");
const types = @import("types.zig");
const Backend = types.Backend;

const WINDOW_NS: i128 = 5 * 60 * 60 * std.time.ns_per_s;

pub const UsageTracker = struct {
    claude_calls: u32 = 0,
    codex_calls: u32 = 0,
    window_start_ns: i128,
    mu: std.Thread.Mutex = .{},

    pub fn init() UsageTracker {
        return .{
            .window_start_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn initWithStart(start_ns: i128) UsageTracker {
        return .{
            .window_start_ns = start_ns,
        };
    }

    /// Record a call to the given backend. Resets window if expired.
    pub fn record(self: *UsageTracker, backend: Backend) void {
        self.mu.lock();
        defer self.mu.unlock();

        self.maybeResetWindow();
        switch (backend) {
            .claude => self.claude_calls += 1,
            .codex => self.codex_calls += 1,
        }
    }

    /// Check if the given backend is near its quota limit.
    /// `warn_at_percent` is a fraction (0.0 to 1.0), e.g. 0.8 for 80%.
    /// `quota` is the maximum calls allowed in a 5h window.
    pub fn nearLimit(self: *UsageTracker, backend: Backend, quota: u32, warn_at_percent: f64) bool {
        self.mu.lock();
        defer self.mu.unlock();

        self.maybeResetWindow();
        const calls = switch (backend) {
            .claude => self.claude_calls,
            .codex => self.codex_calls,
        };
        if (quota == 0) return false;
        const threshold: u32 = @intFromFloat(@as(f64, @floatFromInt(quota)) * warn_at_percent);
        return calls >= threshold;
    }

    /// Get current call count for a backend.
    pub fn callCount(self: *UsageTracker, backend: Backend) u32 {
        self.mu.lock();
        defer self.mu.unlock();

        self.maybeResetWindow();
        return switch (backend) {
            .claude => self.claude_calls,
            .codex => self.codex_calls,
        };
    }

    /// Get total calls across all backends in current window.
    pub fn totalCalls(self: *UsageTracker) u32 {
        self.mu.lock();
        defer self.mu.unlock();

        self.maybeResetWindow();
        return self.claude_calls + self.codex_calls;
    }

    /// Time remaining in the current window, in seconds.
    pub fn windowRemainingSeconds(self: *UsageTracker) u32 {
        self.mu.lock();
        defer self.mu.unlock();

        const now = std.time.nanoTimestamp();
        const elapsed = now - self.window_start_ns;
        if (elapsed >= WINDOW_NS) return 0;
        const remaining_ns = WINDOW_NS - elapsed;
        return @intCast(@divTrunc(remaining_ns, std.time.ns_per_s));
    }

    fn maybeResetWindow(self: *UsageTracker) void {
        const now = std.time.nanoTimestamp();
        if (now - self.window_start_ns >= WINDOW_NS) {
            self.claude_calls = 0;
            self.codex_calls = 0;
            self.window_start_ns = now;
        }
    }
};

// Global singleton — initialized lazily on first use.
var g_tracker: ?UsageTracker = null;
var g_init_mu: std.Thread.Mutex = .{};

pub fn global() *UsageTracker {
    g_init_mu.lock();
    defer g_init_mu.unlock();
    if (g_tracker == null) {
        g_tracker = UsageTracker.init();
    }
    return &g_tracker.?;
}

/// Reset global tracker (for testing).
pub fn resetGlobal() void {
    g_init_mu.lock();
    defer g_init_mu.unlock();
    g_tracker = null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "usage: record increments correct backend" {
    var t = UsageTracker.init();
    t.record(.claude);
    t.record(.claude);
    t.record(.codex);

    try std.testing.expectEqual(@as(u32, 2), t.callCount(.claude));
    try std.testing.expectEqual(@as(u32, 1), t.callCount(.codex));
    try std.testing.expectEqual(@as(u32, 3), t.totalCalls());
}

test "usage: nearLimit triggers at threshold" {
    var t = UsageTracker.init();
    // quota=10, warn at 80% = 8 calls
    for (0..8) |_| t.record(.claude);

    try std.testing.expect(t.nearLimit(.claude, 10, 0.8));
    try std.testing.expect(!t.nearLimit(.codex, 10, 0.8));
}

test "usage: nearLimit below threshold" {
    var t = UsageTracker.init();
    for (0..7) |_| t.record(.claude);

    try std.testing.expect(!t.nearLimit(.claude, 10, 0.8));
}

test "usage: nearLimit with zero quota" {
    var t = UsageTracker.init();
    t.record(.claude);
    try std.testing.expect(!t.nearLimit(.claude, 0, 0.8));
}

test "usage: window reset clears counts" {
    // Start window 6 hours ago (past the 5h window)
    const past_ns = std.time.nanoTimestamp() - (6 * 60 * 60 * std.time.ns_per_s);
    var t = UsageTracker.initWithStart(past_ns);
    t.claude_calls = 100;
    t.codex_calls = 50;

    // Accessing counts triggers window reset
    try std.testing.expectEqual(@as(u32, 0), t.callCount(.claude));
    try std.testing.expectEqual(@as(u32, 0), t.callCount(.codex));
}

test "usage: windowRemainingSeconds within window" {
    var t = UsageTracker.init();
    const remaining = t.windowRemainingSeconds();
    // Should be close to 5 hours (18000 seconds)
    try std.testing.expect(remaining > 17900);
    try std.testing.expect(remaining <= 18000);
}

test "usage: windowRemainingSeconds expired window" {
    const past_ns = std.time.nanoTimestamp() - (6 * 60 * 60 * std.time.ns_per_s);
    var t = UsageTracker.initWithStart(past_ns);
    try std.testing.expectEqual(@as(u32, 0), t.windowRemainingSeconds());
}

test "usage: global singleton" {
    resetGlobal();
    const a = global();
    const b = global();
    try std.testing.expect(a == b);
    a.record(.claude);
    try std.testing.expectEqual(@as(u32, 1), b.callCount(.claude));
    resetGlobal();
}

test "usage: concurrent records are safe" {
    var t = UsageTracker.init();
    const N = 100;

    const thread_fn = struct {
        fn run(tracker: *UsageTracker) void {
            for (0..N) |_| tracker.record(.claude);
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*th| {
        th.* = std.Thread.spawn(.{}, thread_fn, .{&t}) catch unreachable;
    }
    for (&threads) |*th| th.join();

    try std.testing.expectEqual(@as(u32, 4 * N), t.callCount(.claude));
}

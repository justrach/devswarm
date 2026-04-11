const std = @import("std");
const gh = @import("gh.zig");

const BootstrapLabel = struct {
    name: []const u8,
    color: []const u8,
    description: []const u8,
};

const default_labels = [_]BootstrapLabel{
    .{ .name = "status:backlog", .color = "f6f8fa", .description = "Work item has not been started" },
    .{ .name = "status:blocked", .color = "db6d28", .description = "Work item is blocked by dependency" },
    .{ .name = "status:in-progress", .color = "fbca04", .description = "Work item is actively being worked on" },
    .{ .name = "status:in-review", .color = "1d76db", .description = "Work item has an open PR" },
    .{ .name = "status:done", .color = "0e8a16", .description = "Work item is complete" },
    .{ .name = "priority:p0", .color = "b60205", .description = "Highest priority" },
    .{ .name = "priority:p1", .color = "d93f0b", .description = "High priority" },
    .{ .name = "priority:p2", .color = "fbca04", .description = "Medium priority" },
    .{ .name = "priority:p3", .color = "0e8a16", .description = "Low priority" },
};

pub const Label = struct {
    name: []const u8,
    color: []const u8,
    description: []const u8,
};

pub const Milestone = struct {
    number: u32,
    title: []const u8,
    state: []const u8,
};

pub const CacheState = struct {
    mu: std.Thread.Mutex = .{},
    ready: bool = false,
    has_data: bool = false,
    labels: std.ArrayList(Label) = .empty,
    milestones: std.ArrayList(Milestone) = .empty,
    alloc: std.mem.Allocator = undefined,

    pub fn init() CacheState {
        return .{};
    }

    pub fn deinit(self: *CacheState) void {
        self.clearCachedData();
    }

    fn clearCachedData(self: *CacheState) void {
        for (self.labels.items) |lbl| {
            self.alloc.free(lbl.name);
            self.alloc.free(lbl.color);
            self.alloc.free(lbl.description);
        }
        self.labels.clearAndFree(self.alloc);

        for (self.milestones.items) |ms| {
            self.alloc.free(ms.title);
            self.alloc.free(ms.state);
        }
        self.milestones.clearAndFree(self.alloc);
    }

    fn labelExists(self: *const CacheState, name: []const u8) bool {
        for (self.labels.items) |lbl| {
            if (std.mem.eql(u8, lbl.name, name)) return true;
        }
        return false;
    }

    fn milestoneExists(self: *const CacheState, title: []const u8) bool {
        for (self.milestones.items) |ms| {
            if (std.mem.eql(u8, ms.title, title)) return true;
        }
        return false;
    }

    fn createMissingLabels(self: *CacheState, alloc: std.mem.Allocator) void {
        for (default_labels) |label| {
            if (self.labelExists(label.name)) continue;

            const create_r = gh.run(alloc, &.{
                "gh", "label", "create", label.name,
                "--color", label.color,
                "--description", label.description,
            }) catch null;
            if (create_r == null) continue;

            defer create_r.?.deinit(alloc);
            self.appendLabel(alloc, label.name, label.color, label.description) catch continue;
        }
    }

    fn appendLabel(self: *CacheState, alloc: std.mem.Allocator, name: []const u8, color: []const u8, description: []const u8) !void {
        const name_owned = try alloc.dupe(u8, name);
        errdefer alloc.free(name_owned);

        const color_owned = try alloc.dupe(u8, color);
        errdefer alloc.free(color_owned);

        const desc_owned = try alloc.dupe(u8, description);
        errdefer alloc.free(desc_owned);

        try self.labels.append(alloc, .{
            .name = name_owned,
            .color = color_owned,
            .description = desc_owned,
        });
    }

    fn appendMilestone(self: *CacheState, alloc: std.mem.Allocator, number: u32, title: []const u8, state: []const u8) !void {
        const title_owned = try alloc.dupe(u8, title);
        errdefer alloc.free(title_owned);

        const state_owned = try alloc.dupe(u8, state);
        errdefer alloc.free(state_owned);

        try self.milestones.append(alloc, .{
            .number = number,
            .title = title_owned,
            .state = state_owned,
        });
    }

    pub fn prefetch(self: *CacheState, alloc: std.mem.Allocator) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.ready) return;
        self.alloc = alloc;

        var labels_ok = false;
        const labels_r = gh.run(alloc, &.{
            "gh", "label", "list",
            "--json", "name,color,description",
            "--limit", "100",
        }) catch null;
        if (labels_r) |r| {
            defer r.deinit(alloc);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, r.stdout, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .array) {
                    for (p.value.array.items) |item| {
                        if (item != .object) continue;

                        const name = if (item.object.get("name")) |v| if (v == .string) v.string else continue else continue;
                        const color = if (item.object.get("color")) |v| if (v == .string) v.string else "" else "";
                        const desc = if (item.object.get("description")) |v| if (v == .string) v.string else "" else "";
                        self.appendLabel(alloc, name, color, desc) catch continue;
                    }
                }
            }

            self.createMissingLabels(alloc);
            labels_ok = true;
        }

        var milestones_ok = false;
        const milestones_r = gh.run(alloc, &.{
            "gh", "milestone", "list",
            "--json", "number,title,state",
            "--state", "all",
        }) catch null;
        if (milestones_r) |r| {
            defer r.deinit(alloc);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, r.stdout, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .array) {
                    for (p.value.array.items) |item| {
                        if (item != .object) continue;

                        const number: u32 = blk: {
                            const val = item.object.get("number") orelse continue;
                            break :blk switch (val) {
                                .integer => |i| if (i <= 0) continue else @as(u32, @intCast(i)),
                                else => continue,
                            };
                        };
                        const title = blk: {
                            const val = item.object.get("title") orelse continue;
                            break :blk switch (val) {
                                .string => val.string,
                                else => continue,
                            };
                        };
                        const state = blk: {
                            const val = item.object.get("state") orelse continue;
                            break :blk switch (val) {
                                .string => val.string,
                                else => "",
                            };
                        };

                        if (self.milestoneExists(title)) continue;
                        self.appendMilestone(alloc, number, title, state) catch continue;
                    }
                }
            }
            milestones_ok = true;
        }

        if (!labels_ok or !milestones_ok) {
            self.clearCachedData();
            self.ready = false;
            self.has_data = false;
            return;
        }

        self.ready = true;
        self.has_data = true;
    }

    pub fn getLabel(self: *CacheState, name: []const u8) ?Label {
        self.mu.lock();
        defer self.mu.unlock();

        if (!self.ready) return null;
        for (self.labels.items) |lbl| {
            if (std.mem.eql(u8, lbl.name, name)) return lbl;
        }
        return null;
    }

    pub fn getMilestone(self: *CacheState, title: []const u8) ?Milestone {
        self.mu.lock();
        defer self.mu.unlock();

        if (!self.ready) return null;
        for (self.milestones.items) |ms| {
            if (std.mem.eql(u8, ms.title, title)) return ms;
        }
        return null;
    }

    pub fn isReady(self: *const CacheState) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.ready;
    }

    pub fn invalidate(self: *CacheState) void {
        self.mu.lock();
        defer self.mu.unlock();

        self.ready = false;
        if (!self.has_data) return;

        self.clearCachedData();

        self.has_data = false;
    }
};

var g_state: CacheState = .{};

pub fn prefetch(alloc: std.mem.Allocator) void {
    g_state.prefetch(alloc);
}

pub fn getLabel(name: []const u8) ?Label {
    return g_state.getLabel(name);
}

pub fn getMilestone(title: []const u8) ?Milestone {
    return g_state.getMilestone(title);
}

pub fn isReady() bool {
    return g_state.isReady();
}

pub fn invalidate() void {
    g_state.invalidate();
}

pub fn getState() *CacheState {
    return &g_state;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "cache: isReady returns false initially, getLabel/getMilestone return null" {
    var cs: CacheState = .{};
    defer cs.deinit();

    try std.testing.expect(!cs.isReady());
    try std.testing.expectEqual(@as(?Label, null), cs.getLabel("status:backlog"));
    try std.testing.expectEqual(@as(?Milestone, null), cs.getMilestone("v1.0"));
}

test "cache: invalidate on clean state is safe and idempotent" {
    var cs: CacheState = .{};
    defer cs.deinit();

    cs.invalidate();
    cs.invalidate();
    try std.testing.expect(!cs.isReady());
}

test "cache: getLabel returns entry after direct state injection" {
    var cs: CacheState = .{
        .alloc = std.testing.allocator,
    };
    defer cs.invalidate();

    try cs.appendLabel(std.testing.allocator, "status:backlog", "f6f8fa", "not started");
    cs.ready = true;
    cs.has_data = true;

    const lbl = cs.getLabel("status:backlog") orelse return error.LabelNotFound;
    try std.testing.expectEqualStrings("status:backlog", lbl.name);
    try std.testing.expectEqualStrings("f6f8fa", lbl.color);
}

test "cache: invalidate clears injected labels" {
    var cs: CacheState = .{
        .alloc = std.testing.allocator,
    };
    defer cs.deinit();

    try cs.appendLabel(std.testing.allocator, "status:done", "0e8a16", "complete");
    cs.ready = true;
    cs.has_data = true;

    cs.invalidate();

    try std.testing.expect(!cs.isReady());
    try std.testing.expectEqual(@as(?Label, null), cs.getLabel("status:done"));
}

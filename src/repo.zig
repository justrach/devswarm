const std = @import("std");
const gh = @import("gh.zig");

var g_repo_mu: std.Thread.Mutex = .{};
var g_repo_buf: [512]u8 = undefined;
var g_repo_len: usize = 0;

pub fn currentRepo() []const u8 {
    g_repo_mu.lock();
    defer g_repo_mu.unlock();
    return if (g_repo_len == 0) "" else g_repo_buf[0..g_repo_len];
}

pub fn setCurrentRepo(slug: []const u8) void {
    if (slug.len == 0 or slug.len > g_repo_buf.len) return;
    g_repo_mu.lock();
    defer g_repo_mu.unlock();
    @memcpy(g_repo_buf[0..slug.len], slug);
    g_repo_len = slug.len;
}

pub fn detectAndUpdateRepo(alloc: std.mem.Allocator) void {
    const result = gh.run(alloc, &.{ "gh", "repo", "view", "--json", "nameWithOwner" }) catch {
        detectViaGitRemote(alloc);
        return;
    };
    defer result.deinit(alloc);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{}) catch {
        detectViaGitRemote(alloc);
        return;
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("nameWithOwner")) |v| {
            if (v == .string) {
                setCurrentRepo(v.string);
                return;
            }
        }
    }
    detectViaGitRemote(alloc);
}

fn detectViaGitRemote(alloc: std.mem.Allocator) void {
    var child = std.process.Child.init(
        &.{ "git", "remote", "get-url", "origin" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.stdin_behavior = .Close;

    if (child.spawn()) |_| {
        const stdout = child.stdout orelse return;
        var buf: [4096]u8 = undefined;
        const n = stdout.read(&buf) catch return;
        _ = child.wait() catch {};
        const url = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (parseGitHubSlug(url)) |slug| {
            setCurrentRepo(slug);
        }
    } else |_| {}
}

fn parseGitHubSlug(url: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "github.com/", "github.com:" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, url, marker)) |idx| {
            var slug = url[idx + marker.len ..];
            if (std.mem.endsWith(u8, slug, ".git")) {
                slug = slug[0 .. slug.len - 4];
            }
            if (std.mem.indexOf(u8, slug, "/") != null and
                std.mem.lastIndexOf(u8, slug, "/") == std.mem.indexOf(u8, slug, "/"))
            {
                return slug;
            }
        }
    }
    return null;
}

// skills.zig — Discover and parse external skill definitions.
//
// Scans the repo for Markdown skill files in known locations:
//   1. .devswarm/skills/*.md   (native devswarm skills)
//   2. skills/*.md             (gstack-compatible layout)
//
// Each .md file is parsed for optional YAML-style frontmatter (between --- delimiters)
// and a body that becomes the system prompt. Discovered skills override built-in roles
// when the name matches, and extend the available roles when it doesn't.
//
// Frontmatter fields (all optional):
//   name:     role name (default: filename without .md)
//   writable: true/false (default: false)
//   tier:     haiku/sonnet/opus/bolt/spark (default: sonnet)
//
// The body (everything after the closing ---) is the system prompt.

const std = @import("std");
const types = @import("runtime/types.zig");
const RoleSpec = types.RoleSpec;

/// A discovered skill parsed from a Markdown file.
pub const Skill = struct {
    name: []const u8,
    system_prompt: []const u8,
    writable: bool = false,
    tier: []const u8 = "sonnet",
    /// The raw file content (owned). name, system_prompt, tier point into this.
    _backing: []const u8,
};

/// Collection of discovered skills.
pub const SkillSet = struct {
    skills: std.StringHashMap(Skill),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *SkillSet) void {
        var it = self.skills.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.value_ptr._backing);
        }
        self.skills.deinit();
    }

    /// Look up a skill by name. Returns a RoleSpec-compatible view.
    pub fn getRole(self: *const SkillSet, name: []const u8) ?RoleSpec {
        const skill = self.skills.get(name) orelse return null;
        return .{
            .name = skill.name,
            .system_prompt = skill.system_prompt,
            .writable = skill.writable,
        };
    }

    /// Return all discovered skill names (for orchestrator prompt).
    pub fn roleNames(self: *const SkillSet, alloc: std.mem.Allocator) []const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var it = self.skills.iterator();
        while (it.next()) |entry| {
            names.append(alloc, entry.key_ptr.*) catch continue;
        }
        return names.toOwnedSlice(alloc) catch &.{};
    }
};

// ── Global cached discovery ───────────────────────────────────────────────────

var g_mu: std.Thread.Mutex = .{};
var g_discovered: bool = false;
var g_skills: ?SkillSet = null;

/// Thread-safe cached skill discovery. Scans once, returns cached result.
fn getCached(alloc: std.mem.Allocator) ?*const SkillSet {
    g_mu.lock();
    defer g_mu.unlock();
    if (!g_discovered) {
        g_skills = discover(alloc);
        g_discovered = true;
    }
    if (g_skills) |*s| return s;
    return null;
}

/// Look up a discovered skill's system prompt by role name.
/// Thread-safe, cached. Returns null if no skill matches.
pub fn getSkillPrompt(name: []const u8) ?[]const u8 {
    const set = getCached(std.heap.page_allocator) orelse return null;
    const skill = set.skills.get(name) orelse return null;
    return skill.system_prompt;
}

/// Look up a discovered skill's RoleSpec by name.
/// Thread-safe, cached. Returns null if no skill matches.
pub fn getSkillRole(name: []const u8) ?types.RoleSpec {
    const set = getCached(std.heap.page_allocator) orelse return null;
    return set.getRole(name);
}

/// Force re-discovery on next access (e.g. after skill files change).
pub fn invalidate() void {
    g_mu.lock();
    defer g_mu.unlock();
    if (g_skills) |*s| s.deinit();
    g_skills = null;
    g_discovered = false;
}

/// Scan known directories for skill files and parse them.
/// Returns null if no skills are found.
pub fn discover(alloc: std.mem.Allocator) ?SkillSet {
    var set = SkillSet{
        .skills = std.StringHashMap(Skill).init(alloc),
        .alloc = alloc,
    };

    // Scan directories in priority order (lower = higher priority)
    scanDir(alloc, &set, "skills");
    scanDir(alloc, &set, ".devswarm/skills"); // higher priority — overwrites

    if (set.skills.count() == 0) {
        set.skills.deinit();
        return null;
    }
    return set;
}

fn scanDir(alloc: std.mem.Allocator, set: *SkillSet, dir_path: []const u8) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const content = dir.readFileAlloc(alloc, entry.name, 256 * 1024) catch continue;

        const name_without_ext = entry.name[0 .. entry.name.len - 3];
        if (parseSkill(content, name_without_ext)) |skill| {
            // Use the skill name as key — dupe it since entry.name is transient
            const key = alloc.dupe(u8, skill.name) catch {
                alloc.free(content);
                continue;
            };
            const result = set.skills.getOrPut(key) catch {
                alloc.free(key);
                alloc.free(content);
                continue;
            };
            if (result.found_existing) {
                // Higher priority dir overwrites — free old backing
                alloc.free(result.value_ptr._backing);
                alloc.free(key);
            }
            result.value_ptr.* = skill;
        } else {
            alloc.free(content);
        }
    }
}

/// Parse a Markdown skill file into a Skill.
/// Returns null if the file has no usable content.
fn parseSkill(content: []const u8, default_name: []const u8) ?Skill {
    var skill = Skill{
        .name = default_name,
        .system_prompt = "",
        ._backing = content,
    };

    var body_start: usize = 0;

    // Check for frontmatter (starts with ---)
    const trimmed = std.mem.trimLeft(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "---")) {
        const fm_start = @intFromPtr(trimmed.ptr) - @intFromPtr(content.ptr) + 3;
        if (std.mem.indexOf(u8, content[fm_start..], "---")) |fm_end| {
            const frontmatter = content[fm_start .. fm_start + fm_end];
            body_start = fm_start + fm_end + 3;

            // Parse frontmatter lines
            var lines = std.mem.splitScalar(u8, frontmatter, '\n');
            while (lines.next()) |line| {
                const l = std.mem.trim(u8, line, " \t\r");
                if (l.len == 0 or l[0] == '#') continue;

                const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
                const key = std.mem.trim(u8, l[0..colon], " \t");
                const val = std.mem.trim(u8, l[colon + 1 ..], " \t");

                if (std.mem.eql(u8, key, "name")) {
                    skill.name = val;
                } else if (std.mem.eql(u8, key, "writable")) {
                    skill.writable = std.mem.eql(u8, val, "true");
                } else if (std.mem.eql(u8, key, "tier")) {
                    skill.tier = val;
                }
            }
        }
    }

    // Body is everything after frontmatter, trimmed
    const body = std.mem.trim(u8, content[body_start..], " \t\r\n");
    if (body.len == 0) return null;
    skill.system_prompt = body;

    return skill;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "skills: parseSkill with frontmatter" {
    const content =
        \\---
        \\name: investigator
        \\writable: true
        \\tier: opus
        \\---
        \\
        \\You are a systematic debugger.
    ;
    const alloc = std.testing.allocator;
    const owned = try alloc.dupe(u8, content);
    defer alloc.free(owned);

    const skill = parseSkill(owned, "fallback").?;
    try std.testing.expectEqualStrings("investigator", skill.name);
    try std.testing.expect(skill.writable);
    try std.testing.expectEqualStrings("opus", skill.tier);
    try std.testing.expectEqualStrings("You are a systematic debugger.", skill.system_prompt);
}

test "skills: parseSkill without frontmatter" {
    const content = "You are a simple helper agent.";
    const alloc = std.testing.allocator;
    const owned = try alloc.dupe(u8, content);
    defer alloc.free(owned);

    const skill = parseSkill(owned, "helper").?;
    try std.testing.expectEqualStrings("helper", skill.name);
    try std.testing.expect(!skill.writable);
    try std.testing.expectEqualStrings("sonnet", skill.tier);
    try std.testing.expectEqualStrings("You are a simple helper agent.", skill.system_prompt);
}

test "skills: parseSkill empty body returns null" {
    const content =
        \\---
        \\name: empty
        \\---
    ;
    const alloc = std.testing.allocator;
    const owned = try alloc.dupe(u8, content);
    defer alloc.free(owned);

    try std.testing.expect(parseSkill(owned, "empty") == null);
}

test "skills: parseSkill defaults writable to false" {
    const content =
        \\---
        \\name: readonly
        \\---
        \\
        \\Read only agent.
    ;
    const alloc = std.testing.allocator;
    const owned = try alloc.dupe(u8, content);
    defer alloc.free(owned);

    const skill = parseSkill(owned, "x").?;
    try std.testing.expectEqualStrings("readonly", skill.name);
    try std.testing.expect(!skill.writable);
}

test "skills: discover returns null when no skill dirs exist" {
    const alloc = std.testing.allocator;
    // Running in test env — no .devswarm/skills/ or skills/ dirs
    try std.testing.expect(discover(alloc) == null);
}

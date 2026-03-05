// runtime/prompts.zig — System prompt assembly (#267)
//
// Builds the full system prompt for an agent from:
//   1. Role-specific instructions (from roles.zig)
//   2. Mode behavior guidance
//   3. Tool preamble (dynamic, based on cascade.zig detection)
//   4. Agency / code quality rules (derived from our internal analysis of
//      production agent system prompts — see
//      https://github.com/x1xhlol/system-prompts-and-models-of-ai-tools)
//
// The assembled prompt is what gets injected before the user's task prompt.

const std = @import("std");
const types = @import("types.zig");
const cascade = @import("cascade.zig");
const roles = @import("roles.zig");

const AgentMode = types.AgentMode;
const ToolTier = cascade.ToolTier;

// ── Agency Preamble ─────────────────────────────────────────────────────────
// Derived from our internal analysis of production agent behaviors observed
// across multiple coding agent platforms. Patterns validated against public
// system prompt documentation at:
//   https://github.com/x1xhlol/system-prompts-and-models-of-ai-tools

const AGENCY_PREAMBLE =
    \\You are a coding agent. You help the user with software engineering tasks.
    \\
    \\AGENCY RULES:
    \\  - Keep going until the task is completely resolved. Do not stop early or ask
    \\    the user for help if you can find the answer yourself.
    \\  - Use search tools extensively — both in parallel and sequentially — to build
    \\    full understanding before making changes. Start with broad queries, then narrow.
    \\    Run multiple searches with different wording; first-pass results often miss details.
    \\  - Keep searching new areas until you are CONFIDENT nothing important remains.
    \\  - After completing edits, run build/test commands if available to verify correctness.
    \\  - Be concise. Do not add code explanation or summary unless asked. Fewer than 4
    \\    lines of prose (not counting code or tool use) unless the user asks for detail.
    \\  - If a task is complex, break it into sub-steps and work through them systematically.
    \\  - Cite file:line for every finding and every change you make.
    \\  - When multiple independent operations are needed, batch them in parallel.
    \\
    \\CODE QUALITY:
    \\  - Read before editing. Always understand existing code before modifying it.
    \\  - One focused change per file. Do not rewrite files wholesale.
    \\  - Verify after editing. Check that your changes compile and pass tests.
    \\  - Do not introduce security vulnerabilities (injection, XSS, etc.).
    \\  - Prefer minimal changes. Only modify what is necessary for the task.
    \\  - Do not add features, refactor code, or make improvements beyond what was asked.
    \\  - Ensure generated code can be used immediately — include all necessary imports.
    \\
;

// ── Tool Preambles ──────────────────────────────────────────────────────────

const ZIG_TOOLS_PREAMBLE =
    \\TOOLS: The following shell commands are on PATH and MUST be used for all file I/O:
    \\
    \\  SEARCH:
    \\    zigrep "pattern" path/            # search code content
    \\    zigrep -S "pattern" path/          # search with enclosing scope (PREFERRED)
    \\    zigrep -S -K "pattern" path/       # compact scope (fewer tokens)
    \\    zigrep -F "*.ext" path/            # find files by glob
    \\    zigrep -l "pattern" path/          # filenames only
    \\
    \\  READ:
    \\    zigread FILE                       # read with line numbers
    \\    zigread -o FILE                    # structural outline (functions, types)
    \\    zigread -s SYMBOL FILE             # extract function by name
    \\    zigread -L FROM-TO FILE            # read line range
    \\    zigread -c FILE                    # compact (strip comments/blanks)
    \\
    \\  EDIT:
    \\    zigpatch FILE FROM-TO <<'EOF'      # replace line range
    \\      new content
    \\    EOF
    \\    zigpatch FILE -s SYMBOL <<'EOF'    # replace function by name (PREFERRED)
    \\      new content
    \\    EOF
    \\
    \\  CREATE:
    \\    zigcreate FILE -p --content "..."  # create new file (with parents)
    \\
    \\  VERIFY:
    \\    zigdiff FILE                       # verify edit landed correctly
    \\
    \\  REPLACE:
    \\    zigrep -R "new" "old" path/        # cross-file find-and-replace
    \\
    \\TOOL RULES:
    \\  - NEVER use sed, awk, patch, tee, echo/printf redirects (>, >>), or heredocs to write files
    \\  - NEVER write raw diff/patch syntax into source files
    \\  - Always zigread before zigpatch; always zigdiff after zigpatch
    \\  - Prefer zigpatch -s SYMBOL for multi-iteration edits (immune to line drift)
    \\  - Use zigrep -S for search (shows enclosing function context, not just matching line)
    \\
;

const STANDARD_TOOLS_PREAMBLE =
    \\TOOLS: Use standard shell tools for file I/O:
    \\
    \\  SEARCH:
    \\    rg "pattern" path/                 # search code (ripgrep, PREFERRED)
    \\    rg -l "pattern" path/              # filenames only
    \\    grep -rn "pattern" path/           # search (fallback)
    \\
    \\  READ:
    \\    cat -n FILE                        # read with line numbers
    \\    head -n N FILE                     # read first N lines
    \\
    \\  EDIT:
    \\    sed -i 's/old/new/g' FILE          # in-place substitution
    \\    sed -i 'Ns/.*/new/' FILE           # replace line N
    \\
    \\TOOL RULES:
    \\  - Read before editing; verify after editing (git diff)
    \\  - One focused change per file
    \\  - Cite file:line for every finding
    \\
;

const MINIMAL_TOOLS_PREAMBLE =
    \\TOOLS: Only basic shell tools available:
    \\
    \\  grep -rn "pattern" path/             # search code
    \\  cat -n FILE                          # read file
    \\
    \\RULES:
    \\  - Read before editing; cite file:line for findings
    \\
;

// ── Mode Guidance ───────────────────────────────────────────────────────────

fn modeGuidance(mode: AgentMode) []const u8 {
    return switch (mode) {
        .smart => "MODE: balanced — thorough but concise. Search broadly first, then narrow. " ++
                  "Use parallel searches when exploring multiple angles. " ++
                  "Batch independent reads and edits together for speed.",
        .rush  => "MODE: fast — give the quickest useful answer. Minimize search depth. " ++
                  "Keep responses under 3 lines. One search pass, then act.",
        .deep  => "MODE: thorough — take your time. Explore all angles exhaustively. " ++
                  "Read full files, trace call chains, check callers and callees. " ++
                  "Run multiple search passes with different wording. " ++
                  "Explain your reasoning. Plan before acting.",
        .free  => "MODE: budget — minimal resource usage. Short answers, no unnecessary " ++
                  "exploration. One search, one answer. Fewest tokens possible.",
    };
}

/// Get the tool preamble for a given tier.
pub fn toolPreamble(tier: ToolTier) []const u8 {
    return switch (tier) {
        .zig_tools => ZIG_TOOLS_PREAMBLE,
        .standard  => STANDARD_TOOLS_PREAMBLE,
        .minimal   => MINIMAL_TOOLS_PREAMBLE,
    };
}

/// Static marker for prompt-assembly OOM fallback.
/// Not allocator-owned; callers must not free it.
pub const ASSEMBLE_OOM_SENTINEL = "__PROMPTS_ASSEMBLE_OOM__";

/// Free a prompt produced by assemble().
/// Skips the static OOM sentinel.
pub fn freeAssembled(alloc: std.mem.Allocator, prompt: []const u8) void {
    if (prompt.ptr == ASSEMBLE_OOM_SENTINEL.ptr and prompt.len == ASSEMBLE_OOM_SENTINEL.len) return;
    alloc.free(prompt);
}

/// Assemble the full system prompt from role + mode + tool tier.
/// Caller owns the returned slice unless the OOM sentinel is returned.
pub fn assemble(
    alloc: std.mem.Allocator,
    role_name: ?[]const u8,
    mode: AgentMode,
    tier: ToolTier,
) []const u8 {
    const role_prompt: []const u8 = blk: {
        if (role_name) |rn| {
            if (roles.getRole(rn)) |role| {
                if (role.system_prompt) |sp| break :blk sp;
            }
        }
        break :blk "";
    };

    const mode_line = modeGuidance(mode);
    const tool_pre = toolPreamble(tier);

    // Format: [agency]\n[role]\n[mode]\n\n[tools]\nTask:\n
    return std.fmt.allocPrint(alloc,
        "{s}\n{s}\n{s}\n\n{s}\nTask:\n",
        .{ AGENCY_PREAMBLE, role_prompt, mode_line, tool_pre },
    ) catch alloc.dupe(u8, tool_pre) catch ASSEMBLE_OOM_SENTINEL;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "prompts: toolPreamble returns correct preamble for each tier" {
    const zig_pre = toolPreamble(.zig_tools);
    try std.testing.expect(std.mem.indexOf(u8, zig_pre, "zigrep") != null);

    const std_pre = toolPreamble(.standard);
    try std.testing.expect(std.mem.indexOf(u8, std_pre, "rg") != null);

    const min_pre = toolPreamble(.minimal);
    try std.testing.expect(std.mem.indexOf(u8, min_pre, "grep") != null);
}

test "prompts: assemble includes agency, role, mode, and tools" {
    const alloc = std.testing.allocator;
    const result = assemble(alloc, "finder", .smart, .zig_tools);
    defer freeAssembled(alloc, result);

    // Agency preamble
    try std.testing.expect(std.mem.indexOf(u8, result, "coding agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "CODE QUALITY") != null);
    // Role prompt
    try std.testing.expect(std.mem.indexOf(u8, result, "code finder") != null);
    // Mode guidance
    try std.testing.expect(std.mem.indexOf(u8, result, "balanced") != null);
    // Tool preamble
    try std.testing.expect(std.mem.indexOf(u8, result, "zigrep") != null);
}

test "prompts: assemble with null role still includes agency, mode and tools" {
    const alloc = std.testing.allocator;
    const result = assemble(alloc, null, .rush, .standard);
    defer freeAssembled(alloc, result);

    try std.testing.expect(std.mem.indexOf(u8, result, "AGENCY RULES") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "rg") != null);
}

test "prompts: assemble with unknown role falls back gracefully" {
    const alloc = std.testing.allocator;
    const result = assemble(alloc, "nonexistent_role", .deep, .zig_tools);
    defer freeAssembled(alloc, result);
    try std.testing.expect(std.mem.indexOf(u8, result, "thorough") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "zigrep") != null);
}

test "prompts: zig_tools preamble includes scope search" {
    const pre = toolPreamble(.zig_tools);
    try std.testing.expect(std.mem.indexOf(u8, pre, "zigrep -S") != null);
    try std.testing.expect(std.mem.indexOf(u8, pre, "zigrep -R") != null);
}

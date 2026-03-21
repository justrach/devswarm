// runtime.zig — Agent orchestration runtime
//
// Re-exports the runtime module tree so other src/ files can do:
//   const runtime = @import("runtime.zig");
//   const resolved = runtime.resolve.resolveWithProbe(alloc, req);
//   runtime.dispatch.dispatch(alloc, resolved, prompt, out);

pub const types = @import("runtime/types.zig");
pub const detect = @import("runtime/detect.zig");
pub const cascade = @import("runtime/cascade.zig");
pub const grid = @import("runtime/grid.zig");
pub const roles = @import("runtime/roles.zig");
pub const prompts = @import("runtime/prompts.zig");
pub const dispatch = @import("runtime/dispatch.zig");
pub const resolve = @import("runtime/resolve.zig");
pub const telemetry = @import("telemetry.zig");

// Re-export key types for convenience
pub const Backend = types.Backend;
pub const AgentMode = types.AgentMode;
pub const ResolvedAgent = types.ResolvedAgent;
pub const AgentRequest = types.AgentRequest;
pub const RoleSpec = types.RoleSpec;
pub const SwarmTelemetry = telemetry.SwarmTelemetry;
pub const WorkerMetrics = telemetry.WorkerMetrics;
pub const GridMetrics = telemetry.GridMetrics;

// Force test discovery — Zig only runs tests in files reachable via @import.
comptime {
    _ = types;
    _ = detect;
    _ = cascade;
    _ = grid;
    _ = roles;
    _ = prompts;
    _ = dispatch;
    _ = resolve;
    _ = telemetry;
}

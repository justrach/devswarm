const std = @import("std");
const mj = @import("mcp").json;
const graph_query = @import("graph/query.zig");
const graph_mod = @import("graph/graph.zig");
const graph_store = @import("graph/storage.zig");

const GRAPH_PATH = ".codegraph/graph.bin";

var graph_cache: ?graph_mod.CodeGraph = null;
var graph_cache_mtime: i128 = 0;

fn getFileMtime(path: []const u8) i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.mtime;
}

pub fn loadGraph(alloc: std.mem.Allocator) ?*graph_mod.CodeGraph {
    const mtime = getFileMtime(GRAPH_PATH);
    if (graph_cache != null and mtime != 0 and mtime == graph_cache_mtime) {
        return &graph_cache.?;
    }
    if (graph_cache) |*old| {
        old.deinit();
        graph_cache = null;
    }
    const g = graph_store.loadFromFile(GRAPH_PATH, alloc) catch return null;
    graph_cache = g;
    graph_cache_mtime = mtime;
    return &graph_cache.?;
}

pub fn handleSymbolAt(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file = mj.getStr(args, "file") orelse {
        writeErr(alloc, out, "missing required parameter: file");
        return;
    };
    const line_val = mj.getInt(args, "line") orelse {
        writeErr(alloc, out, "missing required parameter: line");
        return;
    };
    const line: u32 = @intCast(@max(line_val, 0));

    const g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };

    const results = graph_query.symbolAt(g, file, line, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"symbols\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        writeSymbolResultJson(alloc, out, r);
    }
    out.appendSlice(alloc, "]}") catch {};
}

pub fn handleFindCallers(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const sym_id = mj.getInt(args, "symbol_id") orelse {
        writeErr(alloc, out, "missing required parameter: symbol_id");
        return;
    };
    const id: u64 = @intCast(@max(sym_id, 0));

    const g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };

    const results = graph_query.findCallers(g, id, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"callers\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        writeCallerResultJson(alloc, out, r);
    }
    out.appendSlice(alloc, "]}") catch {};
}

pub fn handleFindCallees(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const sym_id = mj.getInt(args, "symbol_id") orelse {
        writeErr(alloc, out, "missing required parameter: symbol_id");
        return;
    };
    const id: u64 = @intCast(@max(sym_id, 0));

    const g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };

    const results = graph_query.findCallees(g, id, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"callees\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        writeCallerResultJson(alloc, out, r);
    }
    out.appendSlice(alloc, "]}") catch {};
}

pub fn handleFindDependents(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const sym_id = mj.getInt(args, "symbol_id") orelse {
        writeErr(alloc, out, "missing required parameter: symbol_id");
        return;
    };
    const id: u64 = @intCast(@max(sym_id, 0));

    const max_results_val = mj.getInt(args, "max_results");
    const max_results: usize = if (max_results_val) |v| @intCast(@max(v, 1)) else 10;

    const g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };

    const results = graph_query.findDependents(g, id, max_results, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"dependents\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "{\"id\":") catch {};
        var id_buf: [20]u8 = undefined;
        const id_s = std.fmt.bufPrint(&id_buf, "{d}", .{r.id}) catch continue;
        out.appendSlice(alloc, id_s) catch {};

        if (g.getSymbol(r.id)) |sym| {
            out.appendSlice(alloc, ",\"name\":\"") catch {};
            mj.writeEscaped(alloc, out, sym.name);
            out.appendSlice(alloc, "\"") catch {};
        }

        out.appendSlice(alloc, ",\"score\":") catch {};
        var score_buf: [32]u8 = undefined;
        const score_s = std.fmt.bufPrint(&score_buf, "{d:.6}", .{r.score}) catch continue;
        out.appendSlice(alloc, score_s) catch {};
        out.appendSlice(alloc, "}") catch {};
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn writeSymbolResultJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), r: graph_query.SymbolResult) void {
    out.appendSlice(alloc, "{\"id\":") catch return;
    var buf: [20]u8 = undefined;
    const id_s = std.fmt.bufPrint(&buf, "{d}", .{r.id}) catch return;
    out.appendSlice(alloc, id_s) catch return;
    out.appendSlice(alloc, ",\"name\":\"") catch return;
    mj.writeEscaped(alloc, out, r.name);
    out.appendSlice(alloc, "\",\"kind\":\"") catch return;
    out.appendSlice(alloc, @tagName(r.kind)) catch return;
    out.appendSlice(alloc, "\",\"file\":\"") catch return;
    mj.writeEscaped(alloc, out, r.file_path);
    out.appendSlice(alloc, "\",\"line\":") catch return;
    const line_s = std.fmt.bufPrint(&buf, "{d}", .{r.line}) catch return;
    out.appendSlice(alloc, line_s) catch return;
    out.appendSlice(alloc, ",\"col\":") catch return;
    const col_s = std.fmt.bufPrint(&buf, "{d}", .{r.col}) catch return;
    out.appendSlice(alloc, col_s) catch return;
    out.appendSlice(alloc, ",\"scope\":\"") catch return;
    mj.writeEscaped(alloc, out, r.scope);
    out.appendSlice(alloc, "\"}") catch return;
}

fn writeCallerResultJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), r: graph_query.CallerResult) void {
    writeSymbolResultJson(alloc, out, r.symbol);
    _ = out.pop();
    out.appendSlice(alloc, ",\"edge_kind\":\"") catch return;
    out.appendSlice(alloc, @tagName(r.edge_kind)) catch return;
    out.appendSlice(alloc, "\",\"weight\":") catch return;
    var buf: [32]u8 = undefined;
    const w_s = std.fmt.bufPrint(&buf, "{d:.4}", .{r.weight}) catch return;
    out.appendSlice(alloc, w_s) catch return;
    out.appendSlice(alloc, "}") catch return;
}

fn writeErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch {
        out.appendSlice(alloc, "{\"error\":\"unknown\"}") catch {};
        return;
    };
    out.appendSlice(alloc, s) catch {};
}

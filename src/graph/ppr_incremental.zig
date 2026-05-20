// CodeGraph DB — Incremental Personalized PageRank
//
// Maintains a cached PPR result and updates it incrementally when edges
// change, avoiding full recomputation. Uses local push operations to
// propagate score changes from affected nodes.
//
// On edge addition: injects residual at the source node proportional to
// its current score and the new edge weight.
//
// On edge removal: marks affected nodes dirty and redistributes their
// scores via local pushes.
//
// On file invalidation: marks all symbols in the file as dirty so that
// the next deltaUpdate recomputes their local neighbourhoods.

const std = @import("std");
const graph_mod = @import("graph.zig");
const CodeGraph = graph_mod.CodeGraph;
const Edge = graph_mod.Edge;

pub const DEFAULT_ALPHA: f32 = 0.15;
pub const DEFAULT_EPSILON: f32 = 1e-4;

pub const ScoredNode = struct {
    id: u64,
    score: f32,
};

fn totalOutWeight(g: *const CodeGraph, u: u64) f32 {
    const edges = g.outEdges(u);
    var s: f32 = 0;
    for (edges) |e| s += e.weight;
    return s;
}

pub const IncrementalPpr = struct {
    scores: std.AutoHashMap(u64, f32),
    residuals: std.AutoHashMap(u64, f32),
    dirty_nodes: std.AutoHashMap(u64, void),
    alpha: f32,
    epsilon: f32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) IncrementalPpr {
        return .{
            .scores = std.AutoHashMap(u64, f32).init(alloc),
            .residuals = std.AutoHashMap(u64, f32).init(alloc),
            .dirty_nodes = std.AutoHashMap(u64, void).init(alloc),
            .alpha = DEFAULT_ALPHA,
            .epsilon = DEFAULT_EPSILON,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *IncrementalPpr) void {
        self.scores.deinit();
        self.residuals.deinit();
        self.dirty_nodes.deinit();
    }

    /// Initialize from a previously computed full PPR result.
    /// Takes ownership-style copy of the scores map contents.
    pub fn initFromFull(
        full_scores: std.AutoHashMap(u64, f32),
        alloc: std.mem.Allocator,
    ) !IncrementalPpr {
        var result = init(alloc);
        errdefer result.deinit();

        var it = full_scores.iterator();
        while (it.next()) |entry| {
            try result.scores.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return result;
    }

    // ── Incremental update notifications ─────────────────────────────

    /// Un-absorbs src's current score back to residual so that the next
    /// deltaUpdate re-pushes it through the updated edge list (including the
    /// new edge), faithfully applying the push rule:
    ///   r[v] += (1-α)·r[u]·W(u,v)/W_out(u)
    pub fn onEdgeAdded(self: *IncrementalPpr, src: u64, dst: u64, weight: f32) !void {
        _ = dst;
        // A zero-weight edge does not change any distribution; skip injection.
        if (weight > 0) {
            // Un-absorb src's score back to residual so deltaUpdate re-pushes
            // through the updated edge list with proper W_out normalisation.
            const src_score = self.scores.get(src) orelse 0;
            if (src_score > 0) {
                const entry = try self.residuals.getOrPut(src);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += src_score;
                self.scores.putAssumeCapacity(src, 0);
            }
        }
        // Mark source dirty regardless (edge topology changed).
        try self.dirty_nodes.put(src, {});
    }

    /// Un-absorbs both src's and dst's current scores back to residual so
    /// that the next deltaUpdate re-pushes them through the updated topology,
    /// faithfully applying the push rule with no edge from src to dst.
    pub fn onEdgeRemoved(self: *IncrementalPpr, src: u64, dst: u64) !void {
        // Un-absorb src's score: deltaUpdate will re-push through remaining
        // edges only (the removed edge is gone), applying the push rule with
        // the correct updated W_out normalisation.
        const src_score = self.scores.get(src) orelse 0;
        if (src_score > 0) {
            const entry = try self.residuals.getOrPut(src);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += src_score;
            self.scores.putAssumeCapacity(src, 0);
        }

        // Un-absorb dst's score: dst was receiving flow through the removed
        // edge; returning its absorbed score to residual lets deltaUpdate
        // redistribute it through dst's own out-edges with the updated
        // topology (no arbitrary 0.5 estimate).
        const dst_score = self.scores.get(dst) orelse 0;
        if (dst_score > 0) {
            const dst_entry = try self.residuals.getOrPut(dst);
            if (!dst_entry.found_existing) dst_entry.value_ptr.* = 0;
            dst_entry.value_ptr.* += dst_score;
            self.scores.putAssumeCapacity(dst, 0);
        }

        try self.dirty_nodes.put(src, {});
        try self.dirty_nodes.put(dst, {});
    }

    /// Marks all symbols in the given file dirty and returns their absorbed
    /// scores to residual for re-pushing. Pre-ensures capacity so the loop
    /// never leaves partial state on OOM.
    pub fn onFileInvalidated(self: *IncrementalPpr, symbol_ids: []const u64) !void {
        // Pre-allocate worst-case capacity so the loop below cannot fail.
        try self.dirty_nodes.ensureUnusedCapacity(@intCast(symbol_ids.len));
        try self.residuals.ensureUnusedCapacity(@intCast(symbol_ids.len));

        for (symbol_ids) |id| {
            self.dirty_nodes.putAssumeCapacity(id, {});

            // Inject residual so scores get recomputed
            const score = self.scores.get(id) orelse 0;
            if (score > 0) {
                const entry = self.residuals.getOrPutAssumeCapacity(id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += score;
            }
        }
    }

    /// Apply all pending incremental updates using local push operations.
    /// This is much cheaper than a full PPR recomputation because it only
    /// processes nodes with significant residual, starting from dirty nodes.
    pub fn deltaUpdate(self: *IncrementalPpr, graph: *const CodeGraph) !void {
        // Guard against alpha == 0: when alpha is zero no residual is absorbed
        // into scores (p[u] += alpha * r[u] = 0), so in cyclic graphs the
        // push loop never terminates.  Clamp to a small minimum.
        const safe_alpha = @max(self.alpha, 0.001);

        // For dirty nodes that have no residual yet, seed them with a
        // small residual based on their current score to ensure they
        // get processed.
        var dirty_it = self.dirty_nodes.iterator();
        while (dirty_it.next()) |entry| {
            const node = entry.key_ptr.*;
            if (self.residuals.get(node) == null) {
                const score = self.scores.get(node) orelse 0;
                if (score > 0) {
                    try self.residuals.put(node, score * safe_alpha);
                }
            }
        }

        // Safety cap: enforce a hard iteration limit so pathological
        // inputs cannot spin forever.
        const max_iterations: u32 = 100;
        var iterations: u32 = 0;

        // Run local push operations until convergence (same algorithm as
        // full PPR but starting from residuals rather than a single seed).
        var changed = true;
        while (changed and (iterations < max_iterations)) {
            changed = false;
            iterations += 1;

            // Collect nodes that need pushing
            var to_push: std.ArrayList(u64) = .empty;
            defer to_push.deinit(self.alloc);

            var rit = self.residuals.iterator();
            while (rit.next()) |entry| {
                const u = entry.key_ptr.*;
                const r_u = entry.value_ptr.*;
                const w_out = totalOutWeight(graph, u);
                const threshold = if (w_out > 0) self.epsilon * w_out else self.epsilon;
                if (r_u > threshold) {
                    try to_push.append(self.alloc, u);
                }
            }

            for (to_push.items) |u| {
                const r_u = self.residuals.get(u) orelse continue;
                if (r_u <= 0) continue;

                changed = true;

                // p[u] += alpha * r[u]
                const p_entry = try self.scores.getOrPut(u);
                if (!p_entry.found_existing) p_entry.value_ptr.* = 0;
                p_entry.value_ptr.* += safe_alpha * r_u;

                // Zero r[u] BEFORE distributing to neighbours.
                // This is critical for correctness with self-loops: if u has
                // an edge to itself, the distributed share must accumulate on
                // top of 0, not be wiped out by a later zeroing.
                self.residuals.putAssumeCapacity(u, 0);

                // Distribute residual to out-neighbours
                const edges = graph.outEdges(u);
                if (edges.len > 0) {
                    var w_total: f32 = 0;
                    for (edges) |e| w_total += e.weight;

                    if (w_total > 0) {
                        for (edges) |e| {
                            const share = (1.0 - safe_alpha) * r_u * e.weight / w_total;
                            const r_entry = try self.residuals.getOrPut(e.dst);
                            if (!r_entry.found_existing) r_entry.value_ptr.* = 0;
                            r_entry.value_ptr.* += share;
                        }
                    }
                }
            }
        }

        // Clear dirty set after update
        self.dirty_nodes.clearAndFree();
    }

    // ── Queries ──────────────────────────────────────────────────────

    /// Get the current PPR score for a node, or 0 if not scored.
    pub fn getScore(self: *const IncrementalPpr, node_id: u64) f32 {
        return self.scores.get(node_id) orelse 0;
    }

    /// Return the top-K scored nodes in descending order of score.
    pub fn topK(self: *const IncrementalPpr, k: usize, alloc: std.mem.Allocator) ![]ScoredNode {
        var items: std.ArrayList(ScoredNode) = .empty;
        defer items.deinit(alloc);

        var it = self.scores.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                try items.append(alloc, .{
                    .id = entry.key_ptr.*,
                    .score = entry.value_ptr.*,
                });
            }
        }

        std.mem.sort(ScoredNode, items.items, {}, struct {
            fn cmp(_: void, a: ScoredNode, b: ScoredNode) bool {
                return a.score > b.score;
            }
        }.cmp);

        const n = @min(k, items.items.len);
        const result = try alloc.alloc(ScoredNode, n);
        @memcpy(result, items.items[0..n]);
        return result;
    }

    /// Returns how many nodes are currently marked dirty.
    pub fn dirtyCount(self: *const IncrementalPpr) usize {
        return self.dirty_nodes.count();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

fn makeTestGraph(alloc: std.mem.Allocator) CodeGraph {
    return CodeGraph.init(alloc);
}

test "init and deinit with no leaks" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(1));
}

test "initFromFull copies scores" {
    // Build a full PPR result
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var full_scores = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full_scores.deinit();

    var ippr = try IncrementalPpr.initFromFull(full_scores, std.testing.allocator);
    defer ippr.deinit();

    // Scores should match the full computation
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
    try std.testing.expect(ippr.getScore(3) > 0);
    try std.testing.expectApproxEqAbs(full_scores.get(1).?, ippr.getScore(1), 1e-6);
    try std.testing.expectApproxEqAbs(full_scores.get(2).?, ippr.getScore(2), 1e-6);
}

test "onEdgeAdded marks source dirty and injects residual" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Seed a score for node 1
    try ippr.scores.put(1, 0.5);

    try ippr.onEdgeAdded(1, 2, 1.0);

    try std.testing.expectEqual(@as(usize, 1), ippr.dirtyCount());
    // Residual should be injected at source
    const r = ippr.residuals.get(1) orelse 0;
    try std.testing.expect(r > 0);
}

test "onEdgeRemoved marks both nodes dirty" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);

    try ippr.onEdgeRemoved(1, 2);

    try std.testing.expectEqual(@as(usize, 2), ippr.dirtyCount());
    // Residual should exist at source
    try std.testing.expect((ippr.residuals.get(1) orelse 0) > 0);
}

test "onFileInvalidated marks all symbols dirty" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(10, 0.2);
    try ippr.scores.put(11, 0.3);
    try ippr.scores.put(12, 0.1);

    const ids = [_]u64{ 10, 11, 12 };
    try ippr.onFileInvalidated(&ids);

    try std.testing.expectEqual(@as(usize, 3), ippr.dirtyCount());
}

test "deltaUpdate propagates residuals through edges" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Inject residual at node 1 (simulating initial seed)
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});

    try ippr.deltaUpdate(&g);

    // After update, scores should propagate through the chain
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
    try std.testing.expect(ippr.getScore(3) > 0);
    // Node 1 should have highest score (closest to seed)
    try std.testing.expect(ippr.getScore(1) > ippr.getScore(2));
    try std.testing.expect(ippr.getScore(2) > ippr.getScore(3));
    // Dirty set should be cleared
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
}

test "deltaUpdate after edge addition increases downstream scores" {
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Initial graph: 1 -> 2
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    // Compute full PPR
    var full = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full.deinit();

    var ippr = try IncrementalPpr.initFromFull(full, std.testing.allocator);
    defer ippr.deinit();

    const score_2_before = ippr.getScore(2);

    // Add new edge: 1 -> 3
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });
    try ippr.onEdgeAdded(1, 3, 1.0);
    try ippr.deltaUpdate(&g);

    // Node 3 should now have a positive score
    try std.testing.expect(ippr.getScore(3) > 0);
    // Node 2's score may decrease slightly since out-weight is shared
    // but both should remain positive
    try std.testing.expect(ippr.getScore(2) > 0);
    _ = score_2_before;
}

test "deltaUpdate after edge removal adjusts scores" {
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Initial graph: 1 -> 2, 1 -> 3
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

    var full = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full.deinit();

    var ippr = try IncrementalPpr.initFromFull(full, std.testing.allocator);
    defer ippr.deinit();

    // Notify edge removal (we don't actually remove from graph for this test,
    // just check that the incremental update processes dirty nodes)
    try ippr.onEdgeRemoved(1, 3);
    try ippr.deltaUpdate(&g);

    // After update, dirty set should be cleared
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    // Scores should still be positive (push propagates)
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
}

test "topK returns correct descending order" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);
    try ippr.scores.put(3, 0.8);
    try ippr.scores.put(4, 0.1);

    const top = try ippr.topK(3, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 3), top.len);
    // Should be descending
    try std.testing.expect(top[0].score >= top[1].score);
    try std.testing.expect(top[1].score >= top[2].score);
    // Top node should be node 3 with score 0.8
    try std.testing.expectEqual(@as(u64, 3), top[0].id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), top[0].score, 1e-6);
}

test "topK with k larger than available" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);

    const top = try ippr.topK(100, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 2), top.len);
}

test "deltaUpdate on empty graph is no-op" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.deltaUpdate(&g);

    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(1));
}

test "onFileInvalidated with no prior scores is safe" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    const ids = [_]u64{ 100, 200, 300 };
    try ippr.onFileInvalidated(&ids);

    try std.testing.expectEqual(@as(usize, 3), ippr.dirtyCount());
    // No residual since scores are 0
    try std.testing.expectEqual(@as(?f32, null), ippr.residuals.get(100));
}

test "multiple deltaUpdates converge" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // First update: seed at node 1
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});
    try ippr.deltaUpdate(&g);

    const s1_first = ippr.getScore(1);

    // Second update with small perturbation
    try ippr.residuals.put(1, 0.01);
    try ippr.dirty_nodes.put(1, {});
    try ippr.deltaUpdate(&g);

    const s1_second = ippr.getScore(1);

    // Score should increase slightly but not dramatically
    try std.testing.expect(s1_second >= s1_first);
    try std.testing.expect(s1_second - s1_first < 0.1);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "deltaUpdate on empty dirty set is no-op" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Add some scores but no dirty nodes or residuals
    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);

    const s1_before = ippr.getScore(1);
    const s2_before = ippr.getScore(2);

    try ippr.deltaUpdate(&g);

    // Scores should be unchanged
    try std.testing.expectApproxEqAbs(s1_before, ippr.getScore(1), 1e-6);
    try std.testing.expectApproxEqAbs(s2_before, ippr.getScore(2), 1e-6);
}

test "onEdgeAdded with weight=0 does not inject residual" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);

    try ippr.onEdgeAdded(1, 2, 0.0);

    // weight=0 does not change any distribution; no residual injected.
    // But dirty node is still marked.
    try std.testing.expectEqual(@as(usize, 1), ippr.dirtyCount());
    // Residual should be null or 0
    const r = ippr.residuals.get(1);
    try std.testing.expect(r == null or r.? == 0);
}

test "onEdgeRemoved for nodes with no scores" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Neither node has scores
    try ippr.onEdgeRemoved(42, 43);

    // Should mark both dirty without crashing
    try std.testing.expectEqual(@as(usize, 2), ippr.dirtyCount());
    // No residuals since scores are 0
    try std.testing.expectEqual(@as(?f32, null), ippr.residuals.get(42));
    try std.testing.expectEqual(@as(?f32, null), ippr.residuals.get(43));
}

test "multiple rapid edge additions accumulate residual" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 1.0);

    // Add 5 edges rapidly from the same source.
    // The first call un-absorbs p[1]=1.0 into residual and zeros p[1].
    // Subsequent calls see p[1]=0 and inject nothing (no double-counting).
    try ippr.onEdgeAdded(1, 10, 1.0);
    try ippr.onEdgeAdded(1, 11, 1.0);
    try ippr.onEdgeAdded(1, 12, 1.0);
    try ippr.onEdgeAdded(1, 13, 1.0);
    try ippr.onEdgeAdded(1, 14, 1.0);

    // Residual equals the original score (un-absorbed once, not five times).
    const r = ippr.residuals.get(1) orelse 0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r, 1e-6);
}

test "onFileInvalidated with empty symbol list" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);

    const empty_ids = [_]u64{};
    try ippr.onFileInvalidated(&empty_ids);

    // Should be a no-op
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), ippr.getScore(1), 1e-6);
}

test "topK on empty scores returns empty" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    const top = try ippr.topK(10, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 0), top.len);
}

test "topK with k=0 returns empty" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);

    const top = try ippr.topK(0, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 0), top.len);
}

test "getScore for nonexistent node returns 0" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(999));
    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(0));
    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(std.math.maxInt(u64)));
}

test "topK excludes zero-score nodes" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.0); // zero score
    try ippr.scores.put(3, 0.3);

    const top = try ippr.topK(10, std.testing.allocator);
    defer std.testing.allocator.free(top);

    // Node 2 with score 0 should be excluded
    try std.testing.expectEqual(@as(usize, 2), top.len);
    for (top) |node| {
        try std.testing.expect(node.id != 2);
    }
}

test "deltaUpdate with disconnected node and residual" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Node 1 has no outgoing edges
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});

    try ippr.deltaUpdate(&g);

    // Score should absorb alpha * residual since no neighbours to distribute to
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
}

test "deltaUpdate with self-loop preserves residual correctly" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Node 1 points to itself (self-loop)
    try g.addEdge(.{ .src = 1, .dst = 1, .kind = .references });

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Seed with a significant residual on the self-loop node
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});

    try ippr.deltaUpdate(&g);

    // With a self-loop, score should converge to ~1.0 (all mass stays on node 1).
    // Before the fix, r[u]=0 happened AFTER distribution, wiping the self-loop
    // share and causing mass to drop to only alpha (~0.15).
    const score = ippr.getScore(1);
    try std.testing.expect(score > 0.5); // must be well above alpha
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 0.1);
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
}

// ── Regression tests: incremental vs full PPR ────────────────────────────────

test "regression: incremental from scratch matches full PPR" {
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Chain: 1 -> 2 -> 3
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    // Full batch PPR from query node 1
    var full = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full.deinit();

    // Incremental from scratch: seed residual r[1]=1.0, run deltaUpdate.
    // Both paths execute the same push algorithm, so scores must match exactly.
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});
    try ippr.deltaUpdate(&g);

    try std.testing.expectApproxEqAbs(full.get(1) orelse 0, ippr.getScore(1), 1e-3);
    try std.testing.expectApproxEqAbs(full.get(2) orelse 0, ippr.getScore(2), 1e-3);
    try std.testing.expectApproxEqAbs(full.get(3) orelse 0, ippr.getScore(3), 1e-3);
}

test "regression: edge addition - new dst scored, equal-weight neighbours get equal share" {
    const ppr_mod = @import("ppr.zig");

    // Part 1: fresh-start proportionality check.
    // Graph: 1->2, 1->3 (equal weight). Seed r[1]=1.0.
    // The push rule must distribute equally to both neighbours.
    {
        var g = makeTestGraph(std.testing.allocator);
        defer g.deinit();
        try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
        try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

        var ippr = IncrementalPpr.init(std.testing.allocator);
        defer ippr.deinit();
        try ippr.residuals.put(1, 1.0);
        try ippr.dirty_nodes.put(1, {});
        try ippr.deltaUpdate(&g);

        const s2 = ippr.getScore(2);
        const s3 = ippr.getScore(3);
        try std.testing.expect(s2 > 0);
        try std.testing.expect(s3 > 0);
        // Equal-weight edges → equal scores (push rule: W(u,v)/W_out(u) = 0.5 for both)
        try std.testing.expectApproxEqAbs(s2, s3, 1e-4);
    }

    // Part 2: incremental update causes new dst to score.
    // Node 2 keeps its accumulated history; node 3 starts from zero but must be scored.
    {
        var g = makeTestGraph(std.testing.allocator);
        defer g.deinit();
        try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

        var full0 = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
        defer full0.deinit();

        var ippr = try IncrementalPpr.initFromFull(full0, std.testing.allocator);
        defer ippr.deinit();

        try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });
        try ippr.onEdgeAdded(1, 3, 1.0);
        try ippr.deltaUpdate(&g);

        try std.testing.expect(ippr.getScore(3) > 0);
        try std.testing.expect(ippr.getScore(2) > 0);
        try std.testing.expect(ippr.getScore(1) > 0);
    }
}

test "regression: edge removal - removed dst score decreases, topology reflected" {
    const ppr_mod = @import("ppr.zig");

    // Initial graph: 1 -> 2, 1 -> 3 (symmetric)
    var g_init = makeTestGraph(std.testing.allocator);
    defer g_init.deinit();
    try g_init.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g_init.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

    var full0 = try ppr_mod.pprPush(&g_init, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full0.deinit();

    var ippr = try IncrementalPpr.initFromFull(full0, std.testing.allocator);
    defer ippr.deinit();

    const s3_before = ippr.getScore(3);

    // Build updated graph without edge 1 -> 3
    var g2 = makeTestGraph(std.testing.allocator);
    defer g2.deinit();
    try g2.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    // Notify incremental of removal and update against the new topology
    try ippr.onEdgeRemoved(1, 3);
    try ippr.deltaUpdate(&g2);

    // dst's score must decrease (no longer receives flow from src)
    const s3_after = ippr.getScore(3);
    try std.testing.expect(s3_after < s3_before);

    // src and the remaining neighbour must still score positively
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);

    // Fresh full PPR on the updated graph confirms node 3 is unreachable
    var full1 = try ppr_mod.pprPush(&g2, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full1.deinit();
    try std.testing.expectEqual(@as(?f32, null), full1.get(3));
    try std.testing.expect((full1.get(2) orelse 0) > 0);
}

test "regression: weighted threshold — high-weight edge converges like batch PPR (#110)" {
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // 1 -> 2 with weight 10.0: W_out(1) = 10, so threshold = epsilon * 10.
    // With degree-based threshold (epsilon * 1) too many micro-pushes fire.
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 10.0 });

    var full = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full.deinit();

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});
    try ippr.deltaUpdate(&g);

    try std.testing.expectApproxEqAbs(full.get(1) orelse 0, ippr.getScore(1), 1e-3);
    try std.testing.expectApproxEqAbs(full.get(2) orelse 0, ippr.getScore(2), 1e-3);
}

test "regression: incremental add then remove reflects topology (#166)" {
    const ppr_mod = @import("ppr.zig");

    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    var full0 = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full0.deinit();

    var ippr = try IncrementalPpr.initFromFull(full0, std.testing.allocator);
    defer ippr.deinit();

    // Add 1->3 then remove it — topology returns to original
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });
    try ippr.onEdgeAdded(1, 3, 1.0);
    try ippr.deltaUpdate(&g);

    const s3_after_add = ippr.getScore(3);
    try std.testing.expect(s3_after_add > 0);

    // Remove 1->3 — rebuild graph without it
    var g2 = makeTestGraph(std.testing.allocator);
    defer g2.deinit();
    try g2.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    try ippr.onEdgeRemoved(1, 3);
    try ippr.deltaUpdate(&g2);

    // Node 3 should lose most of its score (edge removed)
    try std.testing.expect(ippr.getScore(3) < s3_after_add);
    // Nodes 1 and 2 must remain positively scored
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
}

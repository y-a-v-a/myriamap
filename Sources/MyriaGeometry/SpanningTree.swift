import Foundation

/// Disjoint-set forest with path halving and union by size.
public struct UnionFind: Sendable {
    private var parent: [Int]
    private var size: [Int]
    public private(set) var componentCount: Int

    public init(count: Int) {
        parent = Array(0..<count)
        size = Array(repeating: 1, count: count)
        componentCount = count
    }

    public mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    /// Merges the sets of `a` and `b`; returns false if they were already joined.
    @discardableResult
    public mutating func union(_ a: Int, _ b: Int) -> Bool {
        var ra = find(a), rb = find(b)
        if ra == rb { return false }
        if size[ra] < size[rb] { swap(&ra, &rb) }
        parent[rb] = ra
        size[ra] += size[rb]
        componentCount -= 1
        return true
    }
}

public enum SpanningTree {
    /// Kruskal's algorithm: the spanning forest of maximum total weight.
    ///
    /// - Parameters:
    ///   - nodeCount: number of nodes (faces of the polyhedron).
    ///   - edges: node pairs (dual edges between faces).
    ///   - weights: weight per edge; heavier edges are kept first. Ties are
    ///     broken by edge index so the result is deterministic.
    /// - Returns: per edge, whether it belongs to the tree.
    public static func maximum(nodeCount: Int, edges: [(Int, Int)], weights: [Double]) -> [Bool] {
        precondition(edges.count == weights.count, "one weight per edge")
        let order = edges.indices.sorted { i, j in
            weights[i] != weights[j] ? weights[i] > weights[j] : i < j
        }
        var sets = UnionFind(count: nodeCount)
        var inTree = Array(repeating: false, count: edges.count)
        for e in order {
            if sets.union(edges[e].0, edges[e].1) {
                inTree[e] = true
                if sets.componentCount == 1 { break }
            }
        }
        return inTree
    }
}

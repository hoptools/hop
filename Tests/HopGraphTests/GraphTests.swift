// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopGraph

@Suite struct GraphTests {
    @Test func testSourceReadWrite() throws {
        let graph = Graph()
        let source = graph.makeSource(1)
        #expect(graph.read(source) == 1)
        graph.setValue(5, for: source)
        #expect(graph.read(source) == 5)
    }

    @Test func testDerivedValueIsMemoizedAndRecomputesOnWrite() throws {
        let graph = Graph()
        let source = graph.makeSource(2)
        var evaluations = 0
        let doubled = graph.makeRule { g in
            evaluations += 1
            return g.read(source) * 2
        }

        #expect(graph.read(doubled) == 4)
        #expect(evaluations == 1)

        // Re-reading without a write is served from the memoized cache.
        #expect(graph.read(doubled) == 4)
        #expect(evaluations == 1)

        // Writing the source invalidates and forces one recompute on the next read.
        graph.setValue(10, for: source)
        #expect(graph.read(doubled) == 20)
        #expect(evaluations == 2)
    }

    @Test func testUnrelatedBranchIsNotRecomputed() throws {
        let graph = Graph()
        let a = graph.makeSource(1)
        let b = graph.makeSource(100)
        var aEvaluations = 0
        var bEvaluations = 0
        let da = graph.makeRule { g in aEvaluations += 1; return g.read(a) + 1 }
        let db = graph.makeRule { g in bEvaluations += 1; return g.read(b) + 1 }

        _ = graph.read(da)
        _ = graph.read(db)
        #expect(aEvaluations == 1)
        #expect(bEvaluations == 1)

        // Mutating `a` must not recompute the `b` branch.
        graph.setValue(2, for: a)
        _ = graph.read(da)
        _ = graph.read(db)
        #expect(aEvaluations == 2)
        #expect(bEvaluations == 1)
    }

    @Test func testDependencyEdgesAreDiscoveredDynamically() throws {
        let graph = Graph()
        let useX = graph.makeSource(true)
        let x = graph.makeSource(10)
        let y = graph.makeSource(20)
        var evaluations = 0
        let selected = graph.makeRule { g -> Int in
            evaluations += 1
            return g.read(useX) ? g.read(x) : g.read(y)
        }

        #expect(graph.read(selected) == 10)
        #expect(evaluations == 1)

        // `y` is not currently read, so mutating it must not invalidate.
        graph.setValue(99, for: y)
        #expect(graph.read(selected) == 10)
        #expect(evaluations == 1)

        // Switch branches: now `y` becomes a dependency and `x` is dropped.
        graph.setValue(false, for: useX)
        #expect(graph.read(selected) == 99)
        #expect(evaluations == 2)

        // `x` is no longer read, so mutating it must not invalidate.
        graph.setValue(11, for: x)
        #expect(graph.read(selected) == 99)
        #expect(evaluations == 2)
    }
}

// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

/// Computes views on demand from an underlying collection of identified data. Mirrors SwiftUI's
/// `ForEach`. Each element's identity comes from its `id` (a key path, `Identifiable.id`, or `\.self`
/// for a range), so the reconciler keys its rows by element identity: reordering, inserting, or
/// deleting data reuses the matching rows' widgets (preserving their state) instead of rebuilding the
/// whole list positionally.
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View, AnyForEach {
    let data: Data
    let elementID: (Data.Element) -> ID
    let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.elementID = { $0[keyPath: id] }
        self.content = content
    }

    public typealias Body = Never
    public var body: Never { fatalError("ForEach has no body") }

    func forEachChildren() -> [(key: AnyHashable, view: any View)] {
        data.map { element in (key: AnyHashable(elementID(element)), view: content(element) as any View) }
    }

    var forEachCount: Int { data.count }

    func forEachChild(at index: Int) -> (key: AnyHashable, view: any View) {
        let element = data[data.index(data.startIndex, offsetBy: index)]
        return (key: AnyHashable(elementID(element)), view: content(element) as any View)
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    /// Iterates over a constant range, using each index as its own identity. Mirrors SwiftUI's
    /// `ForEach(_ data: Range<Int>, content:)`.
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.init(data, id: \.self, content: content)
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    /// Iterates over `Identifiable` data, using each element's `id`. Mirrors SwiftUI's
    /// `ForEach(_ data:, content:)`.
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}

/// Internal protocol letting the evaluator pull a `ForEach`'s keyed children without knowing its
/// generic parameters. The indexed accessors let a `LazyVStack`/`LazyHStack` materialize only a window
/// of rows without building the whole collection.
@MainActor
protocol AnyForEach {
    func forEachChildren() -> [(key: AnyHashable, view: any View)]
    var forEachCount: Int { get }
    func forEachChild(at index: Int) -> (key: AnyHashable, view: any View)
}

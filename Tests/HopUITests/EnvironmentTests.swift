// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopUI

// A custom environment value, declared exactly as in SwiftUI: an `EnvironmentKey` + an `EnvironmentValues`
// computed property reading/writing `self[Key.self]`.
private struct CustomGreetingKey: EnvironmentKey { static let defaultValue = "default" }
private struct CustomCountKey: EnvironmentKey { static let defaultValue = 0 }

private struct Badge: Equatable { var label: String; var level: Int }
private struct CustomBadgeKey: EnvironmentKey { static let defaultValue = Badge(label: "none", level: 0) }

extension EnvironmentValues {
    fileprivate var customGreeting: String {
        get { self[CustomGreetingKey.self] }
        set { self[CustomGreetingKey.self] = newValue }
    }
    fileprivate var customCount: Int {
        get { self[CustomCountKey.self] }
        set { self[CustomCountKey.self] = newValue }
    }
    fileprivate var customBadge: Badge {
        get { self[CustomBadgeKey.self] }
        set { self[CustomBadgeKey.self] = newValue }
    }
}

@MainActor private struct GreetReader: View {
    @Environment(\.customGreeting) private var greeting
    var body: some View { Text("g=\(greeting)") }
}

@MainActor private struct BadgeReader: View {
    @Environment(\.customBadge) private var badge
    var body: some View { Text("b=\(badge.label):\(badge.level)") }
}

@MainActor private struct NestHost: View {
    var body: some View {
        VStack {
            GreetReader()                                       // default (nothing injected)
            GreetReader().environment(\.customGreeting, "hi")   // injected
            VStack {
                GreetReader()                                   // inherits the ancestor's value
                GreetReader().environment(\.customGreeting, "inner")  // nearest override wins
            }
            .environment(\.customGreeting, "outer")
        }
    }
}

@MainActor private struct BadgeHost: View {
    var body: some View {
        VStack {
            BadgeReader()                                                       // default struct
            BadgeReader().environment(\.customBadge, Badge(label: "pro", level: 3))  // injected struct
        }
    }
}

@MainActor private struct GreetRoot: View {
    @State private var french = false
    var body: some View {
        VStack {
            Button("toggle") { french.toggle() }
            GreetReader()
        }
        .environment(\.customGreeting, french ? "Bonjour" : "Hello")
    }
}

@MainActor @Suite struct EnvironmentTests {
    @Test func testSubscriptReturnsDefaultThenStoredValue() {
        var env = EnvironmentValues()
        #expect(env.customGreeting == "default")   // EnvironmentKey.defaultValue when unset
        #expect(env.customCount == 0)
        env.customGreeting = "set"
        #expect(env.customGreeting == "set")
        #expect(env.customCount == 0)              // independent keys don't interfere
    }

    @Test func testCustomValueFlowsDefaultInjectedInheritedAndOverridden() {
        let toolkit = MockToolkit()
        runHopApp(NestHost(), toolkit: toolkit, title: "t")
        let labels = toolkit.liveLabels()
        #expect(labels.contains("g=default"))  // no injection → the key's default
        #expect(labels.contains("g=hi"))       // injected for that subtree
        #expect(labels.contains("g=outer"))    // inherited from an ancestor's injection
        #expect(labels.contains("g=inner"))    // a nearer injection overrides the ancestor's
    }

    @Test func testCustomStructValue() {
        let toolkit = MockToolkit()
        runHopApp(BadgeHost(), toolkit: toolkit, title: "t")
        let labels = toolkit.liveLabels()
        #expect(labels.contains("b=none:0"))   // default struct value
        #expect(labels.contains("b=pro:3"))    // injected struct value
    }

    @Test func testReaderReRendersWhenCustomValueChanges() throws {
        // Memoization/change-detection must include custom keys, or the reader would stay stale.
        let toolkit = MockToolkit()
        runHopApp(GreetRoot(), toolkit: toolkit, title: "t")
        #expect(toolkit.liveLabels().contains("g=Hello"))

        let toggle = try #require(toolkit.widgets.first { $0.kind == .button && $0.title == "toggle" })
        toggle.action?()
        toolkit.drainMainThread()
        #expect(toolkit.liveLabels().contains("g=Bonjour"))
        #expect(!toolkit.liveLabels().contains("g=Hello"))
    }
}

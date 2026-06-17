// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import HopUI

@MainActor private struct DatePickerHost: View {
    @State var date: Date
    let components: DatePickerComponents
    let style: DatePickerStyle
    init(date: Date, components: DatePickerComponents = [.date, .hourAndMinute], style: DatePickerStyle = .automatic) {
        _date = State(wrappedValue: date)
        self.components = components
        self.style = style
    }
    var body: some View {
        DatePicker("Appointment", selection: $date, displayedComponents: components)
            .datePickerStyle(style)
    }
}

@MainActor @Suite struct DatePickerTests {
    @Test func testRendersLabeledLeafCarryingSpec() throws {
        let toolkit = MockToolkit()
        let start = Date(timeIntervalSince1970: 1_000_000)
        runHopApp(DatePickerHost(date: start), toolkit: toolkit, title: "test")
        // Composed as a leading label + the native date leaf.
        #expect(toolkit.liveLabels().contains("Appointment"))
        let spec = try #require(toolkit.widgets.first { $0.kind == "datePicker" }?.datePicker)
        #expect(spec.date == start)
        #expect(spec.components.contains(.date))
        #expect(spec.components.contains(.hourAndMinute))
    }

    @Test func testChangeWritesBackToBinding() throws {
        let toolkit = MockToolkit()
        runHopApp(DatePickerHost(date: Date(timeIntervalSince1970: 0), components: .date), toolkit: toolkit, title: "test")
        let picker = try #require(toolkit.widgets.first { $0.kind == "datePicker" })
        toolkit.clearOps()
        let newDate = Date(timeIntervalSince1970: 86_400)
        picker.datePicker?.onChange(newDate)   // simulate the user picking a new date
        toolkit.drainMainThread()
        let updated = try #require(toolkit.widgets.first { $0.kind == "datePicker" })
        #expect(updated.datePicker?.date == newDate)   // binding round-tripped; spec reflects it
        #expect(toolkit.makeCount == 0)                // reconfigured in place, not rebuilt
    }

    @Test func testComponentsAndStyleFlowThrough() throws {
        let toolkit = MockToolkit()
        runHopApp(DatePickerHost(date: Date(timeIntervalSince1970: 0), components: .hourAndMinute, style: .graphical),
                  toolkit: toolkit, title: "test")
        let spec = try #require(toolkit.widgets.first { $0.kind == "datePicker" }?.datePicker)
        #expect(spec.components == .hourAndMinute)
        #expect(spec.style == .graphical)
    }
}

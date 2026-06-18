// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// Qt backing for ``ComboBox`` — a native editable QComboBox, created through this package's own C++ shim
// (CComboBoxQt). The factory returns the raw `QWidget*`; HopUI's Qt backend wraps it into its `Handle`.
// No dependency on HopQt. Call ``register()`` once at startup.

import CComboBoxQt
import HopUI
import HopUIComboBox

/// Per-widget Swift state: the text callback, the last-known text, and a re-entrancy guard, kept alive by
/// `boxes` (so the C trampoline's unretained context pointer stays valid). `text` tracks the value the
/// binding last held so we don't re-set the field (and disturb the cursor) while the user is typing.
@MainActor private final class QtComboState {
    var onText: @MainActor (String) -> Void = { _ in }
    var items: [String] = []
    var text: String?
    var suppress = false
}

@MainActor private var boxes: [UnsafeMutableRawPointer: QtComboState] = [:]

private let qtComboChanged: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { textPtr, context in
    guard let context else { return }
    let state = Unmanaged<QtComboState>.fromOpaque(context).takeUnretainedValue()
    let text = textPtr.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated {
        guard !state.suppress else { return }
        state.text = text
        state.onText(text)
    }
}

@MainActor private func apply(_ widget: UnsafeMutableRawPointer, _ state: QtComboState, _ spec: ComboBoxSpec) {
    state.suppress = true
    defer { state.suppress = false }
    state.onText = spec.onText
    hopqt_combobox_set_placeholder(widget, spec.placeholder)
    if state.items != spec.items {
        hopqt_combobox_clear(widget)
        for item in spec.items { hopqt_combobox_add_item(widget, item) }
        state.items = spec.items
    }
    if state.text != spec.text {
        hopqt_combobox_set_text(widget, spec.text)
        state.text = spec.text
    }
}

public enum HopUIComboBoxQt {
    /// Register the Qt combo-box factory. Call once before launching the app on the Qt toolkit.
    @MainActor public static func register() {
        ComboBoxBackends.register(
            .qt,
            make: { spec in
                let widget = hopqt_combobox_new()!
                let state = QtComboState()
                boxes[widget] = state
                apply(widget, state, spec)
                hopqt_combobox_connect(widget, qtComboChanged, Unmanaged.passUnretained(state).toOpaque())
                return widget
            },
            update: { native, spec in
                guard let widget = native as? UnsafeMutableRawPointer, let state = boxes[widget] else { return }
                apply(widget, state, spec)
            }
        )
    }
}

// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// GTK4 backing for ``ComboBox`` — a native GtkComboBoxText created *with an entry*, through this package's
// own small C shim (CComboBoxGTK). The factory returns the raw `GtkWidget*`; HopUI's GTK backend wraps it
// into its `Handle`. No dependency on HopGTK4. Call ``register()`` once at startup.

import CComboBoxGTK
import HopUI
import HopUIComboBox

/// Per-widget Swift state: the current text callback, the last-known text, and a re-entrancy guard, kept
/// alive by `boxes` (so the C trampoline's unretained context pointer stays valid). `text` tracks the value
/// the binding last held so we don't re-set the entry (and jump the cursor) while the user is typing.
@MainActor private final class GTKComboState {
    var onText: @MainActor (String) -> Void = { _ in }
    var items: [String] = []
    var text: String?
    var suppress = false
}

@MainActor private var boxes: [UnsafeMutableRawPointer: GTKComboState] = [:]

// C trampoline target: recover the per-widget state and forward the new text (unless we set it ourselves).
private let gtkComboChanged: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { textPtr, context in
    guard let context else { return }
    let state = Unmanaged<GTKComboState>.fromOpaque(context).takeUnretainedValue()
    let text = textPtr.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated {
        guard !state.suppress else { return }
        state.text = text
        state.onText(text)
    }
}

@MainActor private func apply(_ widget: UnsafeMutableRawPointer, _ state: GTKComboState, _ spec: ComboBoxSpec) {
    state.suppress = true
    defer { state.suppress = false }
    state.onText = spec.onText
    if state.items != spec.items {
        hop_combobox_clear(widget)
        for item in spec.items { hop_combobox_append(widget, item) }
        state.items = spec.items
    }
    // Push the binding's text into the entry only when it differs from what the binding last reported, so
    // re-applying mid-edit doesn't reset the cursor to the typed value's start.
    if state.text != spec.text {
        hop_combobox_set_text(widget, spec.text)
        state.text = spec.text
    }
}

public enum HopUIComboBoxGTK4 {
    /// Register the GTK4 combo-box factory. Call once before launching the app on the GTK4 toolkit.
    @MainActor public static func register() {
        ComboBoxBackends.register(
            .gtk4,
            make: { spec in
                let widget = hop_combobox_new()!
                let state = GTKComboState()
                boxes[widget] = state
                apply(widget, state, spec)
                hop_combobox_connect_changed(widget, gtkComboChanged, Unmanaged.passUnretained(state).toOpaque())
                return widget
            },
            update: { native, spec in
                guard let widget = native as? UnsafeMutableRawPointer, let state = boxes[widget] else { return }
                apply(widget, state, spec)
            }
        )
    }
}

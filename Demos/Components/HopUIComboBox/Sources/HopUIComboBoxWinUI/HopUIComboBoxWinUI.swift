// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// WinUI backing for ``ComboBox`` — a native editable Microsoft.UI.Xaml.Controls.ComboBox, created through
// this package's own C++/WinRT shim (CComboBoxWinUI). The factory returns the raw WinUI handle; HopUI's
// WinUI backend wraps it. No dependency on HopWinUI. Call ``register()`` once at startup. Windows-only.

#if os(Windows)
import CComboBoxWinUI
import HopUI
import HopUIComboBox

/// Per-widget Swift state: the text callback, the last-known text, and a re-entrancy guard, kept alive by
/// `boxes` (so the C trampoline's unretained context pointer stays valid).
@MainActor private final class WinUIComboState {
    var onText: @MainActor (String) -> Void = { _ in }
    var items: [String] = []
    var text: String?
    var suppress = false
}

@MainActor private var boxes: [UnsafeMutableRawPointer: WinUIComboState] = [:]

private let winuiComboChanged: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { textPtr, context in
    guard let context else { return }
    let state = Unmanaged<WinUIComboState>.fromOpaque(context).takeUnretainedValue()
    let text = textPtr.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated {
        guard !state.suppress else { return }
        state.text = text
        state.onText(text)
    }
}

@MainActor private func apply(_ widget: UnsafeMutableRawPointer, _ state: WinUIComboState, _ spec: ComboBoxSpec) {
    state.suppress = true
    defer { state.suppress = false }
    state.onText = spec.onText
    hopwinui_combo_set_placeholder(widget, spec.placeholder)
    if state.items != spec.items {
        hopwinui_combo_clear(widget)
        for item in spec.items { hopwinui_combo_add_item(widget, item) }
        state.items = spec.items
    }
    if state.text != spec.text {
        hopwinui_combo_set_text(widget, spec.text)
        state.text = spec.text
    }
}

public enum HopUIComboBoxWinUI {
    /// Register the WinUI combo-box factory. Call once before launching the app on the WinUI toolkit.
    @MainActor public static func register() {
        ComboBoxBackends.register(
            .winUI,
            make: { spec in
                let widget = hopwinui_combo_new()!
                let state = WinUIComboState()
                boxes[widget] = state
                apply(widget, state, spec)
                hopwinui_combo_connect(widget, winuiComboChanged, Unmanaged.passUnretained(state).toOpaque())
                return widget
            },
            update: { native, spec in
                guard let widget = native as? UnsafeMutableRawPointer, let state = boxes[widget] else { return }
                apply(widget, state, spec)
            }
        )
    }
}
#endif

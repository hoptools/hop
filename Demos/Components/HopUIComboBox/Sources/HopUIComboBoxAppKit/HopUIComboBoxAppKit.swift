// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// AppKit backing for ``ComboBox`` — a native `NSComboBox`. No C shim (Cocoa is Swift) and no dependency
// on HopAppKit: the factory returns the raw `NSComboBox` (an `NSView`), and HopUI's AppKit backend wraps
// it into its `Handle` via the component's `makeNative` path. Call ``register()`` once at startup.

#if canImport(AppKit)
import AppKit
import HopUI
import HopUIComboBox

/// An editable `NSComboBox` that owns the HopUI text callback (so it lives as long as the widget) and
/// guards against re-entrancy when the text is set programmatically. `NSComboBox` is already a combo of a
/// text field + dropdown; `isEditable = true` lets the user type freeform text in addition to picking a
/// menu item.
final class HopNSComboBox: NSComboBox, NSComboBoxDelegate {
    private var onText: @MainActor (String) -> Void = { _ in }
    private var suppress = false

    init() {
        super.init(frame: .zero)
        isEditable = true           // editable: freeform typing AND menu selection
        completes = false
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    func apply(_ spec: ComboBoxSpec) {
        onText = spec.onText
        if (objectValues as? [String]) != spec.items {
            suppress = true
            removeAllItems()
            addItems(withObjectValues: spec.items)
            suppress = false
        }
        // Only push the binding's text into the field when it differs from what's shown, so re-applying
        // mid-edit doesn't fight the user's cursor.
        if stringValue != spec.text {
            suppress = true
            stringValue = spec.text
            suppress = false
        }
    }

    // Freeform typing in the editable field (NSControlTextEditingDelegate, via NSComboBoxDelegate).
    func controlTextDidChange(_ obj: Notification) {
        guard !suppress else { return }
        onText(stringValue)
    }

    // Picking an item from the dropdown sets the text to that item.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !suppress, indexOfSelectedItem >= 0 else { return }
        onText((objectValueOfSelectedItem as? String) ?? stringValue)
    }
}

public enum HopUIComboBoxAppKit {
    /// Register the AppKit combo-box factory. Call once before launching the app on the AppKit toolkit.
    @MainActor public static func register() {
        ComboBoxBackends.register(
            .appKit,
            make: { spec in let box = HopNSComboBox(); box.apply(spec); return box },
            update: { native, spec in (native as? HopNSComboBox)?.apply(spec) }
        )
    }
}
#endif

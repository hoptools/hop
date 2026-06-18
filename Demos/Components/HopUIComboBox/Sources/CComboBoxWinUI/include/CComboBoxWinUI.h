// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Pure-C surface over a WinUI 3 (Microsoft.UI.Xaml.Controls.ComboBox) for HopUIComboBox's WinUI backing.
// WinUI/WinRT has no C ABI, so — exactly like `hop`'s own CWinUI shim — Swift imports only this header and
// the C++/WinRT implementation in shim.cpp does the real work.
//
// The ComboBox is created editable (`IsEditable(true)`) so the user can type freeform text in addition to
// choosing a menu item. The value is the ComboBox's `Text`; both TextSubmitted (typing) and
// SelectionChanged (menu) report it.

#ifndef HOP_COMBOBOX_WINUI_H
#define HOP_COMBOBOX_WINUI_H

#ifdef __cplusplus
extern "C" {
#endif

// Swift callback for a text change: (newText, context).
typedef void (*hop_combo_text_fn)(const char *text, void *context);

void *hopwinui_combo_new(void);
void hopwinui_combo_clear(void *combo);
void hopwinui_combo_add_item(void *combo, const char *text);
void hopwinui_combo_set_text(void *combo, const char *text);
void hopwinui_combo_connect(void *combo, hop_combo_text_fn fn, void *context);

#ifdef __cplusplus
}
#endif

#endif

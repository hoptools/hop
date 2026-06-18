// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Pure-C surface over QComboBox for HopUIComboBox's Qt backing. Qt is C++ (no C ABI), so — exactly like
// `hop`'s own CQt shim — Swift imports only this header and the implementation in shim.cpp does the C++.
//
// The combo is created editable (`setEditable(true)`) so the user can type freeform text in addition to
// picking a menu item. The value is the current text; `currentTextChanged` fires for both typing and
// selection.

#ifndef HOP_COMBOBOX_QT_H
#define HOP_COMBOBOX_QT_H

#ifdef __cplusplus
extern "C" {
#endif

// Swift callback for a text change: (newText, context).
typedef void (*hopqt_combo_text_fn)(const char *text, void *context);

void *hopqt_combobox_new(void);
void hopqt_combobox_clear(void *combo);
void hopqt_combobox_add_item(void *combo, const char *text);
void hopqt_combobox_set_text(void *combo, const char *text);
void hopqt_combobox_connect(void *combo, hopqt_combo_text_fn fn, void *context);

#ifdef __cplusplus
}
#endif

#endif

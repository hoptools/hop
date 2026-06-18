// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// A small C shim over GtkComboBoxText for HopUIComboBox's GTK backing. GTK is a C library, so this needs
// no C++ wrapper — just thin `static inline` helpers (the GTK_* cast macros and signal plumbing are
// awkward straight from Swift) plus a trampoline that turns the entry's "changed" signal into a Swift
// callback. Resolved via pkg-config gtk4 (declared in this package's Package.swift), like `hop`'s CGTK4.
//
// The combo is created *with an entry* (`gtk_combo_box_text_new_with_entry`) so the user can type freeform
// text in addition to picking a menu item. The combo's child is a GtkEntry; its text is the value, and its
// "changed" signal fires for BOTH typing and menu selection (picking an item sets the entry text).

#ifndef HOP_COMBOBOX_GTK_SHIM_H
#define HOP_COMBOBOX_GTK_SHIM_H

#include <gtk/gtk.h>

// Swift callback for a text change: (newText, context).
typedef void (*hop_combo_text_fn)(const char *text, void *context);

// Create an empty *editable* drop-down (entry + menu). ref_sink takes a strong ref (the parent adds its
// own when it's inserted), matching how `hop` owns its widgets.
static inline void *hop_combobox_new(void) {
    GtkWidget *combo = gtk_combo_box_text_new_with_entry();
    g_object_ref_sink(combo);
    return combo;
}

// The combo's editable child (a GtkEntry), where the freeform text lives.
static inline GtkEditable *hop_combobox_entry(void *combo) {
    return GTK_EDITABLE(gtk_combo_box_get_child(GTK_COMBO_BOX(combo)));
}

static inline void hop_combobox_clear(void *combo) {
    gtk_combo_box_text_remove_all(GTK_COMBO_BOX_TEXT(combo));
}

static inline void hop_combobox_append(void *combo, const char *text) {
    gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(combo), text);
}

static inline void hop_combobox_set_text(void *combo, const char *text) {
    gtk_editable_set_text(hop_combobox_entry(combo), text);
}

static inline const char *hop_combobox_get_text(void *combo) {
    return gtk_editable_get_text(hop_combobox_entry(combo));
}

// Prompt text shown in the entry while it's empty (the combo's child is a GtkEntry; placeholder is a
// GtkEntry property, not on GtkEditable, so cast to GtkEntry).
static inline void hop_combobox_set_placeholder(void *combo, const char *text) {
    GtkWidget *entry = gtk_combo_box_get_child(GTK_COMBO_BOX(combo));
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), text);
}

// Packs the Swift callback + its context; freed by GTK when the signal connection is destroyed.
typedef struct { hop_combo_text_fn fn; void *context; } hop_combo_cb;

static void hop_combo_trampoline(GtkEditable *entry, gpointer data) {
    hop_combo_cb *cb = (hop_combo_cb *)data;
    cb->fn(gtk_editable_get_text(entry), cb->context);
}

// Connect the entry's "changed" signal (fires on typing AND menu selection) to `fn(text, context)`.
static inline void hop_combobox_connect_changed(void *combo, hop_combo_text_fn fn, void *context) {
    hop_combo_cb *cb = (hop_combo_cb *)g_malloc(sizeof(hop_combo_cb));
    cb->fn = fn;
    cb->context = context;
    g_signal_connect_data(hop_combobox_entry(combo), "changed", G_CALLBACK(hop_combo_trampoline), cb, (GClosureNotify)g_free, (GConnectFlags)0);
}

#endif

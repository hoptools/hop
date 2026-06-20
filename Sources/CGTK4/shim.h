// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Hand-rolled C shim over the GTK4 C ABI. GTK widget pointers are opaque, so we expose a thin
// `void *`-based surface to Swift and keep all the GTK_*() cast macros and signal-connection
// plumbing on the C side. Include paths and linker flags come from `pkg-config gtk4` (declared in
// Package.swift), so this resolves uniformly on macOS (brew), Linux (apt), and Windows (MSYS2).

#ifndef HOP_CGTK4_SHIM_H
#define HOP_CGTK4_SHIM_H

#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

typedef void (*hop_activate_fn)(void *app, void *user_data);
typedef void (*hop_clicked_fn)(void *button, void *user_data);

// --- Application & window ---------------------------------------------------

static inline void *hop_app_new(const char *app_id) {
    return gtk_application_new(app_id, G_APPLICATION_DEFAULT_FLAGS);
}

static inline unsigned long hop_connect_activate(void *app, hop_activate_fn cb, void *data) {
    return g_signal_connect_data(app, "activate", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

static inline int hop_app_run(void *app) {
    return g_application_run(G_APPLICATION(app), 0, NULL);
}

static inline void hop_app_quit(void *app) {
    g_application_quit(G_APPLICATION(app));
}

static inline void *hop_window_new(void *app) {
    return gtk_application_window_new(GTK_APPLICATION(app));
}

static inline void hop_window_set_title(void *win, const char *title) {
    gtk_window_set_title(GTK_WINDOW(win), title);
}

static inline void hop_window_set_default_size(void *win, int w, int h) {
    gtk_window_set_default_size(GTK_WINDOW(win), w, h);
}

static inline void hop_window_set_child(void *win, void *child) {
    gtk_window_set_child(GTK_WINDOW(win), child);
}

static inline void hop_window_present(void *win) {
    gtk_window_present(GTK_WINDOW(win));
}

// --- Widgets ---------------------------------------------------------------

static inline void *hop_box_new(int horizontal, int spacing) {
    return gtk_box_new(horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL, spacing);
}

static inline void hop_box_set_spacing(void *box, int spacing) {
    gtk_box_set_spacing(GTK_BOX(box), spacing);
}

static inline void hop_box_append(void *box, void *child) {
    GtkWidget *w = GTK_WIDGET(child);
    // Expanding children (split view, list) fill the box; others sit at their natural size,
    // centered on the cross axis (so buttons/labels don't stretch full-width).
    if (gtk_widget_get_hexpand(w) || gtk_widget_get_vexpand(w)) {
        gtk_widget_set_halign(w, GTK_ALIGN_FILL);
        gtk_widget_set_valign(w, GTK_ALIGN_FILL);
    } else if (gtk_orientable_get_orientation(GTK_ORIENTABLE(box)) == GTK_ORIENTATION_VERTICAL) {
        gtk_widget_set_halign(w, GTK_ALIGN_CENTER);
    } else {
        gtk_widget_set_valign(w, GTK_ALIGN_CENTER);
    }
    gtk_box_append(GTK_BOX(box), w);
}

// --- Paned (split view) ----------------------------------------------------

static inline void *hop_paned_new(void) {
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_hexpand(paned, TRUE);
    gtk_widget_set_vexpand(paned, TRUE);
    gtk_paned_set_wide_handle(GTK_PANED(paned), TRUE);
    return paned;
}

static inline void hop_paned_set_start(void *paned, void *child) {
    gtk_paned_set_start_child(GTK_PANED(paned), GTK_WIDGET(child));
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);  // sidebar keeps its width when the window resizes
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
}

static inline void hop_paned_set_end(void *paned, void *child) {
    gtk_paned_set_end_child(GTK_PANED(paned), GTK_WIDGET(child));
    gtk_paned_set_resize_end_child(GTK_PANED(paned), TRUE);   // detail takes the remaining width …
    gtk_paned_set_shrink_end_child(GTK_PANED(paned), TRUE);   // … and may shrink below its content's request
}                                                            //     (HopUI's engine pins that request), so the
                                                             //     paned — and thus the window — can shrink.

static inline void hop_paned_set_position(void *paned, int position) {
    gtk_paned_set_position(GTK_PANED(paned), position);
}

// --- Header bar (top toolbar) ----------------------------------------------

static inline void *hop_header_bar_new(void) {
    return gtk_header_bar_new();
}

static inline void hop_window_set_titlebar(void *win, void *bar) {
    gtk_window_set_titlebar(GTK_WINDOW(win), GTK_WIDGET(bar));
}

static inline void hop_header_bar_pack_start(void *bar, void *child) {
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), GTK_WIDGET(child));
}

// --- Menu bar (GMenu model + GActions) -------------------------------------

typedef void (*hop_action_fn)(void *action, void *param, void *user_data);

static inline void *hop_menu_new(void) {
    return g_menu_new();
}

static inline void hop_menu_append_item(void *menu, const char *label, const char *detailed_action) {
    g_menu_append(G_MENU(menu), label, detailed_action);
}

static inline void hop_menu_append_section(void *menu, void *section) {
    g_menu_append_section(G_MENU(menu), NULL, G_MENU_MODEL(section));
}

static inline void hop_menu_append_submenu(void *menu, const char *label, void *submenu) {
    g_menu_append_submenu(G_MENU(menu), label, G_MENU_MODEL(submenu));
}

static inline void hop_app_set_menubar(void *app, void *menu) {
    gtk_application_set_menubar(GTK_APPLICATION(app), G_MENU_MODEL(menu));
}

static inline void hop_window_show_menubar(void *window) {
    gtk_application_window_set_show_menubar(GTK_APPLICATION_WINDOW(window), TRUE);
}

static inline void *hop_simple_action_new(const char *name) {
    return g_simple_action_new(name, NULL);
}

// --- Drop-down menu button (GtkMenuButton + GMenu + a local action group) ---

static inline void *hop_menu_button_new(void) {
    return gtk_menu_button_new();
}

static inline void hop_menu_button_set_label(void *button, const char *label) {
    gtk_menu_button_set_label(GTK_MENU_BUTTON(button), label);
}

static inline void hop_menu_button_set_menu_model(void *button, void *model) {
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(button), G_MENU_MODEL(model));
}

// A per-widget action group (prefix scopes the GMenu's "prefix.name" detailed actions). Inserting a
// fresh group with the same prefix replaces (and unrefs) the previous one — no global accumulation.
static inline void *hop_simple_action_group_new(void) {
    return g_simple_action_group_new();
}

static inline void hop_action_group_add_action(void *group, void *action) {
    g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
}

static inline void hop_widget_insert_action_group(void *widget, const char *prefix, void *group) {
    gtk_widget_insert_action_group(GTK_WIDGET(widget), prefix, G_ACTION_GROUP(group));
}

// --- Separator (Divider) ---------------------------------------------------

static inline void *hop_separator_new(int horizontal) {
    return gtk_separator_new(horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL);
}

static inline void hop_widget_set_hexpand(void *w, int expand) {
    gtk_widget_set_hexpand(GTK_WIDGET(w), expand ? TRUE : FALSE);
}

static inline unsigned long hop_action_connect_activate(void *action, hop_action_fn cb, void *data) {
    return g_signal_connect_data(action, "activate", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

static inline void hop_app_add_action(void *app, void *action) {
    g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action));
}

// Run a standard editing action (clipboard.cut/copy/paste, selection.select-all, text.undo/redo)
// against the window's currently-focused widget.
static inline void hop_window_activate_clipboard(void *window, const char *action_name) {
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(window));
    if (focus) gtk_widget_activate_action(focus, action_name, NULL);
}

static inline void hop_box_remove(void *box, void *child) {
    gtk_box_remove(GTK_BOX(box), child);
}

// Move `child` (already in the box) so that exactly `index` other children precede it. Used for both
// keyed reordering and index-honoring insertion (GtkBox itself only appends/prepends).
static inline void hop_box_reorder(void *box, void *child, int index) {
    GtkBox *b = GTK_BOX(box);
    GtkWidget *c = GTK_WIDGET(child);
    GtkWidget *sibling = NULL;  // NULL → move to the first position
    GtkWidget *cur = gtk_widget_get_first_child(GTK_WIDGET(b));
    int seen = 0;
    while (cur) {
        if (cur != c) {
            if (seen == index) break;  // `index` non-child widgets already precede the slot
            sibling = cur;
            seen++;
        }
        cur = gtk_widget_get_next_sibling(cur);
    }
    gtk_box_reorder_child_after(b, c, sibling);
}

static inline void *hop_label_new(const char *text) {
    return gtk_label_new(text);
}

// Make a label wrap like SwiftUI's `Text`: multi-line, word/char wrapping, top-leading aligned. Applied
// ONLY to HopUI `Text` leaves (the layout engine sizes those itself) — NOT to chrome labels such as
// header-bar toolbar items, which must keep their natural single-line size or GTK squeezes a wrapping
// label down to one character per line (e.g. a "GTK4" toolbar title wrapping to "G/T/K4").
static inline void hop_label_set_wrapping(void *label) {
    GtkLabel *l = GTK_LABEL(label);
    gtk_label_set_wrap(l, TRUE);
    gtk_label_set_wrap_mode(l, PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(l, 0.0f);
    gtk_widget_set_halign(GTK_WIDGET(l), GTK_ALIGN_START);
}

// Measure a wrapping label: when the proposed width is narrower than the natural (single-line) width,
// constrain to it and report the wrapped height; otherwise the natural single-line size. Unlike
// hop_widget_measure (which always returns the natural width), this returns the CONSTRAINED width so the
// engine doesn't grow the row to the unwrapped text width.
static inline void hop_label_measure(void *w, int for_width, int *out_w, int *out_h) {
    GtkWidget *widget = GTK_WIDGET(w);
    gtk_widget_set_size_request(widget, -1, -1);
    int minw = 0, natw = 0, minh = 0, nath = 0;
    gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minw, &natw, NULL, NULL);
    int width = natw, hw = natw;
    if (for_width > 0 && for_width < natw) { width = (for_width < minw) ? minw : for_width; hw = width; }
    gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, hw, &minh, &nath, NULL, NULL);
    *out_w = width;
    *out_h = nath;
}

static inline void hop_label_set_text(void *label, const char *text) {
    gtk_label_set_text(GTK_LABEL(label), text);
}

static inline void *hop_button_new(const char *text) {
    return gtk_button_new_with_label(text);
}

static inline void hop_button_set_label(void *button, const char *text) {
    gtk_button_set_label(GTK_BUTTON(button), text);
}

static inline unsigned long hop_connect_clicked(void *button, hop_clicked_fn cb, void *data) {
    return g_signal_connect_data(button, "clicked", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

// `.onTapGesture`: attach a GtkGestureClick to any widget. The callback gets the press count (1, 2, …)
// so a count-N gesture fires only on the Nth release. Returns the controller (pass to remove below).
typedef void (*hop_tap_fn)(void *gesture, int n_press, double x, double y, void *data);
static inline void *hop_tap_gesture_new(void *widget, hop_tap_fn cb, void *data) {
    GtkGesture *gesture = gtk_gesture_click_new();
    g_signal_connect_data(gesture, "released", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
    gtk_widget_add_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(gesture));
    return gesture;
}
static inline void hop_tap_gesture_remove(void *widget, void *gesture) {
    if (gesture) gtk_widget_remove_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(gesture));
}
// Remove any event controller added below (long-press / hover / drag / zoom / rotate).
static inline void hop_controller_remove(void *widget, void *controller) {
    if (controller) gtk_widget_remove_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(controller));
}

// `.onLongPressGesture`: GtkGestureLongPress, "pressed" fires once the press is held. `delay_factor`
// scales GTK's default long-press time (range ~0.5–4.0) to approximate the requested duration.
typedef void (*hop_longpress_fn)(void *gesture, double x, double y, void *data);
static inline void *hop_longpress_gesture_new(void *widget, double delay_factor, hop_longpress_fn cb, void *data) {
    GtkGesture *gesture = gtk_gesture_long_press_new();
    gtk_gesture_long_press_set_delay_factor(GTK_GESTURE_LONG_PRESS(gesture), delay_factor);
    g_signal_connect_data(gesture, "pressed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
    gtk_widget_add_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(gesture));
    return gesture;
}

// `.onHover`: GtkEventControllerMotion. "enter" carries (x, y); "leave" carries nothing → two callbacks.
typedef void (*hop_enter_fn)(void *controller, double x, double y, void *data);
typedef void (*hop_leave_fn)(void *controller, void *data);
static inline void *hop_hover_controller_new(void *widget, hop_enter_fn enter_cb, hop_leave_fn leave_cb, void *data) {
    GtkEventController *controller = gtk_event_controller_motion_new();
    g_signal_connect_data(controller, "enter", G_CALLBACK(enter_cb), data, NULL, (GConnectFlags)0);
    g_signal_connect_data(controller, "leave", G_CALLBACK(leave_cb), data, NULL, (GConnectFlags)0);
    gtk_widget_add_controller((GtkWidget *)widget, controller);
    return controller;
}

// `.gesture(DragGesture())`: GtkGestureDrag. "drag-update"/"drag-end" carry the offset from the start; the
// Swift side reads the start point via hop_drag_get_start to reconstruct the SwiftUI drag value.
typedef void (*hop_drag_fn)(void *gesture, double offset_x, double offset_y, void *data);
static inline void *hop_drag_gesture_new(void *widget, hop_drag_fn update_cb, hop_drag_fn end_cb, void *data) {
    GtkGesture *gesture = gtk_gesture_drag_new();
    g_signal_connect_data(gesture, "drag-update", G_CALLBACK(update_cb), data, NULL, (GConnectFlags)0);
    g_signal_connect_data(gesture, "drag-end", G_CALLBACK(end_cb), data, NULL, (GConnectFlags)0);
    gtk_widget_add_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(gesture));
    return gesture;
}
static inline void hop_drag_get_start(void *gesture, double *sx, double *sy) {
    gtk_gesture_drag_get_start_point(GTK_GESTURE_DRAG(gesture), sx, sy);
}

// `.gesture(MagnifyGesture())`: GtkGestureZoom, "scale-changed" gives the scale relative to the start (1.0).
typedef void (*hop_zoom_fn)(void *gesture, double scale, void *data);
static inline void *hop_zoom_gesture_new(void *widget, hop_zoom_fn cb, void *data) {
    GtkGesture *gesture = gtk_gesture_zoom_new();
    g_signal_connect_data(gesture, "scale-changed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
    gtk_widget_add_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(gesture));
    return gesture;
}

// `.gesture(RotateGesture())`: GtkGestureRotate, "angle-changed" gives (absolute angle, delta-since-start).
typedef void (*hop_rotate_fn)(void *gesture, double angle, double angle_delta, void *data);
static inline void *hop_rotate_gesture_new(void *widget, hop_rotate_fn cb, void *data) {
    GtkGesture *gesture = gtk_gesture_rotate_new();
    g_signal_connect_data(gesture, "angle-changed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
    gtk_widget_add_controller((GtkWidget *)widget, GTK_EVENT_CONTROLLER(gesture));
    return gesture;
}

static inline void *hop_entry_new(void) {
    return gtk_entry_new();
}

static inline void hop_entry_set_placeholder(void *entry, const char *text) {
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), text);
}

// Hide/show typed characters — a GtkEntry with visibility off is GTK's password field (SecureField).
static inline void hop_entry_set_visibility(void *entry, int visible) {
    gtk_entry_set_visibility(GTK_ENTRY(entry), visible ? TRUE : FALSE);
}

static inline const char *hop_editable_get_text(void *editable) {
    return gtk_editable_get_text(GTK_EDITABLE(editable));
}

static inline void hop_editable_set_text(void *editable, const char *text) {
    gtk_editable_set_text(GTK_EDITABLE(editable), text);
}

static inline unsigned long hop_connect_changed(void *editable, hop_clicked_fn cb, void *data) {
    return g_signal_connect_data(editable, "changed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

static inline void *hop_scale_new(double min, double max) {
    GtkWidget *s = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, min, max, 1.0);
    gtk_widget_set_size_request(s, 200, -1);
    return s;
}

static inline void hop_scale_set_range(void *scale, double min, double max) {
    gtk_range_set_range(GTK_RANGE(scale), min, max);
}

static inline void hop_scale_set_value(void *scale, double value) {
    gtk_range_set_value(GTK_RANGE(scale), value);
}

static inline double hop_scale_get_value(void *scale) {
    return gtk_range_get_value(GTK_RANGE(scale));
}

// The "value-changed" signal passes the range and user_data; read the value with hop_scale_get_value.
static inline unsigned long hop_connect_value_changed(void *scale, hop_clicked_fn cb, void *data) {
    return g_signal_connect_data(scale, "value-changed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

// --- Date picker (composite: GtkCalendar + an hour:minute GtkSpinButton row) -----------------------
//
// GTK4 has no single date/time control, so we compose one: a GtkCalendar (date) plus two GtkSpinButtons
// (time) in a vertical box. The value is exchanged as a Unix timestamp (seconds, local time) so the Swift
// side converts to/from a Foundation Date. Sub-widgets are stashed on the box via g_object_set_data so
// set/get/visibility can find them; `hop_datepicker_set_components` shows only the requested parts.
static inline void *hop_datepicker_new(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    GtkWidget *cal = gtk_calendar_new();
    g_object_set_data(G_OBJECT(box), "hop-cal", cal);
    gtk_box_append(GTK_BOX(box), cal);

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    GtkWidget *hour = gtk_spin_button_new_with_range(0, 23, 1);
    GtkWidget *minute = gtk_spin_button_new_with_range(0, 59, 1);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(hour), 0);
    gtk_spin_button_set_digits(GTK_SPIN_BUTTON(minute), 0);
    g_object_set_data(G_OBJECT(box), "hop-hour", hour);
    g_object_set_data(G_OBJECT(box), "hop-min", minute);
    g_object_set_data(G_OBJECT(box), "hop-timerow", row);
    gtk_box_append(GTK_BOX(row), gtk_label_new("Time"));
    gtk_box_append(GTK_BOX(row), hour);
    gtk_box_append(GTK_BOX(row), gtk_label_new(":"));
    gtk_box_append(GTK_BOX(row), minute);
    gtk_box_append(GTK_BOX(box), row);
    return box;
}

static inline void hop_datepicker_set_components(void *box, int want_date, int want_time) {
    GtkWidget *cal = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-cal");
    GtkWidget *row = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-timerow");
    if (cal) gtk_widget_set_visible(cal, want_date ? TRUE : FALSE);
    if (row) gtk_widget_set_visible(row, want_time ? TRUE : FALSE);
}

static inline void hop_datepicker_set(void *box, double unix_seconds) {
    GtkWidget *cal = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-cal");
    GtkWidget *hour = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-hour");
    GtkWidget *minute = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-min");
    GDateTime *dt = g_date_time_new_from_unix_local((gint64)unix_seconds);
    if (!dt) return;
    if (cal) gtk_calendar_select_day(GTK_CALENDAR(cal), dt);
    if (hour) gtk_spin_button_set_value(GTK_SPIN_BUTTON(hour), g_date_time_get_hour(dt));
    if (minute) gtk_spin_button_set_value(GTK_SPIN_BUTTON(minute), g_date_time_get_minute(dt));
    g_date_time_unref(dt);
}

static inline double hop_datepicker_get(void *box) {
    GtkWidget *cal = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-cal");
    GtkWidget *hour = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-hour");
    GtkWidget *minute = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-min");
    int y = 2000, mo = 1, d = 1;
    if (cal) {
        GDateTime *cd = gtk_calendar_get_date(GTK_CALENDAR(cal));
        if (cd) {
            y = g_date_time_get_year(cd);
            mo = g_date_time_get_month(cd);
            d = g_date_time_get_day_of_month(cd);
            g_date_time_unref(cd);
        }
    }
    int h = hour ? gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(hour)) : 0;
    int mi = minute ? gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(minute)) : 0;
    GDateTime *dt = g_date_time_new_local(y, mo, d, h, mi, 0);
    double secs = dt ? (double)g_date_time_to_unix(dt) : 0;
    if (dt) g_date_time_unref(dt);
    return secs;
}

// Connect the calendar's "day-selected" and both spin buttons' "value-changed" to one callback. The
// callback receives the emitting sub-widget (ignored) and user_data; recover the value via the stored
// box pointer + hop_datepicker_get.
static inline void hop_datepicker_connect(void *box, hop_clicked_fn cb, void *data) {
    GtkWidget *cal = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-cal");
    GtkWidget *hour = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-hour");
    GtkWidget *minute = (GtkWidget *)g_object_get_data(G_OBJECT(box), "hop-min");
    if (cal) g_signal_connect_data(cal, "day-selected", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
    if (hour) g_signal_connect_data(hour, "value-changed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
    if (minute) g_signal_connect_data(minute, "value-changed", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

// --- Color button (GtkColorButton: a swatch that opens the system color chooser) -------------------
// Components are exchanged as four 0..1 doubles. GtkColorButton/GtkColorChooser are deprecated in
// GTK 4.10 but remain available across the GTK4 versions we target (the modern replacement,
// GtkColorDialogButton, needs 4.10+, which our oldest CI runner may not have).
static inline void *hop_colorbutton_new(void) {
    return gtk_color_button_new();
}

static inline void hop_colorbutton_set(void *btn, double r, double g, double b, double a) {
    GdkRGBA rgba = { (float)r, (float)g, (float)b, (float)a };
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(btn), &rgba);
}

static inline void hop_colorbutton_set_alpha(void *btn, int use_alpha) {
    gtk_color_chooser_set_use_alpha(GTK_COLOR_CHOOSER(btn), use_alpha ? TRUE : FALSE);
}

static inline double hop_colorbutton_red(void *btn)   { GdkRGBA c; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(btn), &c); return c.red; }
static inline double hop_colorbutton_green(void *btn) { GdkRGBA c; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(btn), &c); return c.green; }
static inline double hop_colorbutton_blue(void *btn)  { GdkRGBA c; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(btn), &c); return c.blue; }
static inline double hop_colorbutton_alpha(void *btn) { GdkRGBA c; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(btn), &c); return c.alpha; }

// "color-set" fires on a user pick (not on programmatic set_rgba); the handler reads the emitting button.
static inline unsigned long hop_colorbutton_connect(void *btn, hop_clicked_fn cb, void *data) {
    return g_signal_connect_data(btn, "color-set", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

// --- Native file chooser (GtkFileChooserNative) ----------------------------------------------------
// Async: shows the OS file dialog, then invokes `cb` with newline-joined absolute paths (open; possibly
// several) or the single chosen path (save), or NULL on cancel. `patterns` is a ';'-separated glob list
// ("*.txt;*.json"); empty/NULL means "all files". GtkFileChooserNative/GtkFileChooser are deprecated in
// GTK 4.10 but work across the GTK4 versions we target (the modern GtkFileDialog needs 4.10+).
typedef void (*hop_files_cb)(const char *paths, void *user_data);

typedef struct { hop_files_cb cb; void *data; } HopFileCtx;

static inline GtkWindow *hop_widget_window(void *widget) {
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(widget));
    return GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL;
}

static inline void hop_file_apply_filter(GtkFileChooser *chooser, const char *name, const char *patterns) {
    if (!patterns || !patterns[0]) return;
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, (name && name[0]) ? name : "Files");
    char *copy = g_strdup(patterns);
    for (char *tok = strtok(copy, ";"); tok; tok = strtok(NULL, ";")) gtk_file_filter_add_pattern(filter, tok);
    g_free(copy);
    gtk_file_chooser_add_filter(chooser, filter);
}

// Shared "response" handler for both open and save (save returns a single file).
static inline void hop_file_response(GtkNativeDialog *native, int response, gpointer user_data) {
    HopFileCtx *ctx = (HopFileCtx *)user_data;
    if (response == GTK_RESPONSE_ACCEPT) {
        GListModel *files = gtk_file_chooser_get_files(GTK_FILE_CHOOSER(native));
        GString *s = g_string_new(NULL);
        guint n = files ? g_list_model_get_n_items(files) : 0;
        for (guint i = 0; i < n; i++) {
            GFile *f = (GFile *)g_list_model_get_item(files, i);
            char *p = f ? g_file_get_path(f) : NULL;
            if (p) { if (s->len) g_string_append_c(s, '\n'); g_string_append(s, p); g_free(p); }
            if (f) g_object_unref(f);
        }
        if (files) g_object_unref(files);
        if (ctx->cb) ctx->cb(s->str, ctx->data);
        g_string_free(s, TRUE);
    } else if (ctx->cb) {
        ctx->cb(NULL, ctx->data);
    }
    g_free(ctx);
    g_object_unref(native);
}

static inline void hop_file_open(void *widget, int multiple, const char *filter_name, const char *patterns,
                                 hop_files_cb cb, void *data) {
    GtkFileChooserNative *native = gtk_file_chooser_native_new("Open", hop_widget_window(widget),
                                                               GTK_FILE_CHOOSER_ACTION_OPEN, "_Open", "_Cancel");
    gtk_file_chooser_set_select_multiple(GTK_FILE_CHOOSER(native), multiple ? TRUE : FALSE);
    hop_file_apply_filter(GTK_FILE_CHOOSER(native), filter_name, patterns);
    HopFileCtx *ctx = (HopFileCtx *)malloc(sizeof(HopFileCtx));
    ctx->cb = cb; ctx->data = data;
    g_signal_connect(native, "response", G_CALLBACK(hop_file_response), ctx);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(native));
}

static inline void hop_file_save(void *widget, const char *default_name, const char *filter_name,
                                 const char *patterns, hop_files_cb cb, void *data) {
    GtkFileChooserNative *native = gtk_file_chooser_native_new("Save", hop_widget_window(widget),
                                                               GTK_FILE_CHOOSER_ACTION_SAVE, "_Save", "_Cancel");
    if (default_name && default_name[0]) gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(native), default_name);
    hop_file_apply_filter(GTK_FILE_CHOOSER(native), filter_name, patterns);
    HopFileCtx *ctx = (HopFileCtx *)malloc(sizeof(HopFileCtx));
    ctx->cb = cb; ctx->data = data;
    g_signal_connect(native, "response", G_CALLBACK(hop_file_response), ctx);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(native));
}

// --- Lazy list (GtkListView + GtkStringList + GtkSingleSelection) -----------
//
// `rowText` returns a malloc'd C string the shim frees. GtkListView only realizes widgets for
// visible rows (widget-lazy); GtkStringList holds the lightweight string data.

typedef char *(*hop_row_fn)(unsigned position, void *user_data);
typedef void (*hop_notify_fn)(void *object, void *pspec, void *user_data);

static inline void hop_list_item_setup(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *label = gtk_label_new("");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_margin_start(label, 6);
    gtk_widget_set_margin_end(label, 6);
    gtk_list_item_set_child(GTK_LIST_ITEM(object), label);
}

static inline void hop_list_item_bind(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkListItem *item = GTK_LIST_ITEM(object);
    GtkWidget *label = gtk_list_item_get_child(item);
    GtkStringObject *strobj = GTK_STRING_OBJECT(gtk_list_item_get_item(item));
    gtk_label_set_text(GTK_LABEL(label), gtk_string_object_get_string(strobj));
}

static inline void *hop_list_new(void) {
    GtkWidget *sw = gtk_scrolled_window_new();
    gtk_widget_set_size_request(sw, 180, 300);  // minimum; fills its split pane
    gtk_widget_set_hexpand(sw, TRUE);
    gtk_widget_set_vexpand(sw, TRUE);
    GtkWidget *lv = gtk_list_view_new(NULL, NULL);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(hop_list_item_setup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(hop_list_item_bind), NULL);
    gtk_list_view_set_factory(GTK_LIST_VIEW(lv), factory);
    g_object_unref(factory);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), lv);
    return sw;
}

// Style the list as a navigation sidebar (GTK's `.navigation-sidebar` style class — inset rows, sidebar
// selection), and drop the scrolled-window frame so it blends with the window like a source list.
static inline void hop_list_set_sidebar(void *sw, int sidebar) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    if (!lv) return;
    if (sidebar) {
        gtk_widget_add_css_class(lv, "navigation-sidebar");
        gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(sw), FALSE);
    } else {
        gtk_widget_remove_css_class(lv, "navigation-sidebar");
        gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(sw), TRUE);
    }
}

static inline void hop_list_set_strings(void *sw, unsigned count, hop_row_fn cb, void *user_data) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkStringList *list = gtk_string_list_new(NULL);
    for (unsigned i = 0; i < count; i++) {
        char *s = cb ? cb(i, user_data) : NULL;
        gtk_string_list_append(list, s ? s : "");
        if (s) free(s);
    }
    GtkSingleSelection *sel = gtk_single_selection_new(G_LIST_MODEL(list));
    gtk_single_selection_set_autoselect(sel, FALSE);
    gtk_single_selection_set_can_unselect(sel, TRUE);
    gtk_single_selection_set_selected(sel, GTK_INVALID_LIST_POSITION);
    gtk_list_view_set_model(GTK_LIST_VIEW(lv), GTK_SELECTION_MODEL(sel));
    g_object_unref(sel);
}

static inline unsigned long hop_list_connect_selection(void *sw, hop_notify_fn cb, void *user_data) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkSelectionModel *sel = gtk_list_view_get_model(GTK_LIST_VIEW(lv));
    return g_signal_connect_data(sel, "notify::selected", G_CALLBACK(cb), user_data, NULL, (GConnectFlags)0);
}

static inline unsigned hop_selection_model_get_selected(void *model) {
    return gtk_single_selection_get_selected(GTK_SINGLE_SELECTION(model));
}

static inline unsigned hop_list_get_selected(void *sw) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkSelectionModel *sel = gtk_list_view_get_model(GTK_LIST_VIEW(lv));
    return gtk_single_selection_get_selected(GTK_SINGLE_SELECTION(sel));
}

static inline void hop_list_set_selected(void *sw, unsigned position) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkSelectionModel *sel = gtk_list_view_get_model(GTK_LIST_VIEW(lv));
    gtk_single_selection_set_selected(GTK_SINGLE_SELECTION(sel), position);
}

static inline unsigned hop_list_invalid(void) { return GTK_INVALID_LIST_POSITION; }

// --- Switch (Toggle: GtkSwitch) --------------------------------------------
// Declared after the list section so the `hop_notify_fn` typedef is in scope.

static inline void *hop_switch_new(void) {
    GtkWidget *sw = gtk_switch_new();
    gtk_widget_set_halign(sw, GTK_ALIGN_START);
    gtk_widget_set_valign(sw, GTK_ALIGN_CENTER);
    return sw;
}

static inline void hop_switch_set_active(void *sw, int active) {
    gtk_switch_set_active(GTK_SWITCH(sw), active ? TRUE : FALSE);
}

static inline int hop_switch_get_active(void *sw) {
    return gtk_switch_get_active(GTK_SWITCH(sw)) ? 1 : 0;
}

// notify::active fires (object, pspec, user_data) when the switch flips; read state with hop_switch_get_active.
static inline unsigned long hop_switch_connect(void *sw, hop_notify_fn cb, void *data) {
    return g_signal_connect_data(sw, "notify::active", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

// --- Notebook (TabView: GtkNotebook) ---------------------------------------

// "switch-page" signature: (notebook, page_widget, page_num, user_data).
typedef void (*hop_switch_page_fn)(void *nb, void *page, unsigned page_num, void *data);

static inline void *hop_notebook_new(void) {
    GtkWidget *nb = gtk_notebook_new();
    gtk_widget_set_hexpand(nb, TRUE);
    gtk_widget_set_vexpand(nb, TRUE);
    return nb;
}

static inline void hop_notebook_insert(void *nb, void *child, const char *label, int pos) {
    gtk_widget_set_hexpand(GTK_WIDGET(child), TRUE);
    gtk_widget_set_vexpand(GTK_WIDGET(child), TRUE);
    gtk_notebook_insert_page(GTK_NOTEBOOK(nb), GTK_WIDGET(child), gtk_label_new(label ? label : ""), pos);
}

static inline void hop_notebook_set_tab_label_index(void *nb, int index, const char *label) {
    GtkWidget *page = gtk_notebook_get_nth_page(GTK_NOTEBOOK(nb), index);
    if (page) gtk_notebook_set_tab_label_text(GTK_NOTEBOOK(nb), page, label);
}

static inline void hop_notebook_set_current(void *nb, int index) {
    gtk_notebook_set_current_page(GTK_NOTEBOOK(nb), index);
}

static inline int hop_notebook_get_current(void *nb) {
    return gtk_notebook_get_current_page(GTK_NOTEBOOK(nb));
}

static inline unsigned long hop_notebook_connect_switch(void *nb, hop_switch_page_fn cb, void *data) {
    return g_signal_connect_data(nb, "switch-page", G_CALLBACK(cb), data, NULL, (GConnectFlags)0);
}

static inline void hop_notebook_remove(void *nb, void *child) {
    int n = gtk_notebook_page_num(GTK_NOTEBOOK(nb), GTK_WIDGET(child));
    if (n >= 0) gtk_notebook_remove_page(GTK_NOTEBOOK(nb), n);
}

// --- Tree (OutlineGroup: GtkListView + GtkTreeListModel + GtkTreeExpander) ---
//
// The tree is described by Swift as a pre-order flattened list of (title, key, depth) rows. The shim
// reconstructs the nested `GListStore` tree from `depth` (each row's children are appended into a child
// store attached to it), wraps it in a `GtkTreeListModel` (autoexpanded) behind a `GtkSingleSelection`,
// and binds each row with a `GtkTreeExpander` (the native disclosure triangle) over a label. Each item
// is a `GtkStringObject` carrying its title; its key and child store ride along as object data.

typedef int (*hop_depth_fn)(unsigned position, void *user_data);

static inline void hop_tree_item_setup(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *expander = gtk_tree_expander_new();
    GtkWidget *label = gtk_label_new("");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_tree_expander_set_child(GTK_TREE_EXPANDER(expander), label);
    gtk_list_item_set_child(GTK_LIST_ITEM(object), expander);
}

static inline void hop_tree_item_bind(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkListItem *item = GTK_LIST_ITEM(object);
    GtkTreeExpander *expander = GTK_TREE_EXPANDER(gtk_list_item_get_child(item));
    GtkTreeListRow *row = GTK_TREE_LIST_ROW(gtk_list_item_get_item(item));
    gtk_tree_expander_set_list_row(expander, row);
    GObject *node = gtk_tree_list_row_get_item(row);  // transfer full
    GtkWidget *label = gtk_tree_expander_get_child(expander);
    if (node) {
        gtk_label_set_text(GTK_LABEL(label), gtk_string_object_get_string(GTK_STRING_OBJECT(node)));
        // Non-selectable rows are section headers: drop the disclosure triangle and dim the text so the
        // list reads as a sectioned list (matching SwiftUI) rather than a collapsible tree.
        gboolean header = g_object_get_data(node, "hop-header") != NULL;
        gtk_tree_expander_set_hide_expander(expander, header);
        if (header) gtk_widget_add_css_class(label, "dim-label");
        else gtk_widget_remove_css_class(label, "dim-label");
        g_object_unref(node);
    }
}

// GtkTreeListModelCreateModelFunc: return the (owned) child model for an expandable item, or NULL for a
// leaf (an empty child store also counts as a leaf, so no empty disclosure triangle is shown).
static inline GListModel *hop_tree_create_child(gpointer item, gpointer user_data) {
    (void)user_data;
    GListStore *children = g_object_get_data(G_OBJECT(item), "hop-children");
    if (!children || g_list_model_get_n_items(G_LIST_MODEL(children)) == 0) return NULL;
    return G_LIST_MODEL(g_object_ref(children));
}

static inline void *hop_tree_new(void) {
    GtkWidget *sw = gtk_scrolled_window_new();
    gtk_widget_set_size_request(sw, 180, 300);
    gtk_widget_set_hexpand(sw, TRUE);
    gtk_widget_set_vexpand(sw, TRUE);
    GtkWidget *lv = gtk_list_view_new(NULL, NULL);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(hop_tree_item_setup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(hop_tree_item_bind), NULL);
    gtk_list_view_set_factory(GTK_LIST_VIEW(lv), factory);
    g_object_unref(factory);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), lv);
    return sw;
}

static inline void hop_tree_set_sidebar(void *sw, int sidebar) {
    hop_list_set_sidebar(sw, sidebar);  // same `.navigation-sidebar` styling + frameless scroll as a list
}

static inline void hop_tree_set_rows(void *sw, unsigned count, hop_row_fn title_cb, hop_row_fn key_cb,
                                     hop_depth_fn depth_cb, hop_depth_fn selectable_cb, void *user_data) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GListStore *root = g_list_store_new(GTK_TYPE_STRING_OBJECT);
    // stack[d] = the GListStore that a node of depth d is appended into; stack[d+1] is the child store
    // we attach to the most recently appended depth-d node, so its deeper descendants land there.
    GListStore *stack[64];
    stack[0] = root;
    for (unsigned i = 0; i < count; i++) {
        int depth = depth_cb ? depth_cb(i, user_data) : 0;
        if (depth < 0) depth = 0;
        if (depth > 62) depth = 62;
        char *title = title_cb ? title_cb(i, user_data) : NULL;
        char *key = key_cb ? key_cb(i, user_data) : NULL;
        int selectable = selectable_cb ? selectable_cb(i, user_data) : 1;
        GtkStringObject *obj = gtk_string_object_new(title ? title : "");
        if (key) g_object_set_data_full(G_OBJECT(obj), "hop-key", g_strdup(key), g_free);
        if (!selectable) g_object_set_data(G_OBJECT(obj), "hop-header", GINT_TO_POINTER(1));  // section header
        GListStore *child_store = g_list_store_new(GTK_TYPE_STRING_OBJECT);
        g_object_set_data_full(G_OBJECT(obj), "hop-children", child_store, g_object_unref);
        g_list_store_append(stack[depth], G_OBJECT(obj));
        g_object_unref(obj);  // the store holds its own ref
        stack[depth + 1] = child_store;
        if (title) free(title);
        if (key) free(key);
    }
    GtkTreeListModel *tlm = gtk_tree_list_model_new(G_LIST_MODEL(root), FALSE, TRUE,
                                                    hop_tree_create_child, NULL, NULL);
    GtkSingleSelection *sel = gtk_single_selection_new(G_LIST_MODEL(tlm));  // takes ownership of tlm
    gtk_single_selection_set_autoselect(sel, FALSE);
    gtk_single_selection_set_can_unselect(sel, TRUE);
    gtk_single_selection_set_selected(sel, GTK_INVALID_LIST_POSITION);
    gtk_list_view_set_model(GTK_LIST_VIEW(lv), GTK_SELECTION_MODEL(sel));
    g_object_unref(sel);
}

static inline unsigned long hop_tree_connect_selection(void *sw, hop_notify_fn cb, void *user_data) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkSelectionModel *sel = gtk_list_view_get_model(GTK_LIST_VIEW(lv));
    return g_signal_connect_data(sel, "notify::selected", G_CALLBACK(cb), user_data, NULL, (GConnectFlags)0);
}

// The selected row's key (malloc'd; Swift frees with free()), or NULL when nothing is selected.
static inline char *hop_tree_get_selected_key(void *sw) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkSelectionModel *sel = gtk_list_view_get_model(GTK_LIST_VIEW(lv));
    if (!sel) return NULL;
    gpointer rowitem = gtk_single_selection_get_selected_item(GTK_SINGLE_SELECTION(sel));  // transfer none
    if (!rowitem) return NULL;
    GObject *node = gtk_tree_list_row_get_item(GTK_TREE_LIST_ROW(rowitem));  // transfer full
    if (!node) return NULL;
    const char *key = g_object_get_data(node, "hop-key");
    char *result = key ? strdup(key) : NULL;
    g_object_unref(node);
    return result;
}

// Select the row whose key matches (the tree is autoexpanded, so every row is present); NULL clears.
static inline void hop_tree_select_key(void *sw, const char *key) {
    GtkWidget *lv = gtk_scrolled_window_get_child(GTK_SCROLLED_WINDOW(sw));
    GtkSelectionModel *sel = gtk_list_view_get_model(GTK_LIST_VIEW(lv));
    if (!sel) return;
    if (!key) { gtk_single_selection_set_selected(GTK_SINGLE_SELECTION(sel), GTK_INVALID_LIST_POSITION); return; }
    GListModel *model = G_LIST_MODEL(sel);
    guint n = g_list_model_get_n_items(model);
    for (guint i = 0; i < n; i++) {
        GtkTreeListRow *row = g_list_model_get_item(model, i);  // transfer full
        GObject *node = gtk_tree_list_row_get_item(row);  // transfer full
        const char *k = node ? g_object_get_data(node, "hop-key") : NULL;
        int match = (k && strcmp(k, key) == 0);
        if (node) g_object_unref(node);
        g_object_unref(row);
        if (match) { gtk_single_selection_set_selected(GTK_SINGLE_SELECTION(sel), i); return; }
    }
    gtk_single_selection_set_selected(GTK_SINGLE_SELECTION(sel), GTK_INVALID_LIST_POSITION);
}

// --- Image (GtkPicture: a scalable GdkPaintable from a file / bytes / icon) ---
//
// A single GtkPicture handles every source: a file or raw bytes become a GdkTexture; a `systemName`
// becomes the theme's GtkIconPaintable (with a built-in fallback when the name isn't found). The
// content-fit maps SwiftUI's resizable/contentMode directly.

static inline void *hop_picture_new(void) {
    GtkWidget *pic = gtk_picture_new();
    gtk_widget_set_hexpand(pic, FALSE);
    gtk_widget_set_vexpand(pic, FALSE);
    gtk_picture_set_can_shrink(GTK_PICTURE(pic), TRUE);
    return pic;
}

static inline void hop_picture_set_file(void *pic, const char *path) {
    GError *err = NULL;
    GdkTexture *tex = gdk_texture_new_from_filename(path, &err);
    if (tex) {
        gtk_picture_set_paintable(GTK_PICTURE(pic), GDK_PAINTABLE(tex));
        g_object_unref(tex);
    } else {
        if (err) g_error_free(err);
        gtk_picture_set_paintable(GTK_PICTURE(pic), NULL);
    }
}

static inline void hop_picture_set_bytes(void *pic, const unsigned char *data, int len) {
    GBytes *bytes = g_bytes_new(data, (gsize)len);
    GError *err = NULL;
    GdkTexture *tex = gdk_texture_new_from_bytes(bytes, &err);
    g_bytes_unref(bytes);
    if (tex) {
        gtk_picture_set_paintable(GTK_PICTURE(pic), GDK_PAINTABLE(tex));
        g_object_unref(tex);
    } else {
        if (err) g_error_free(err);
        gtk_picture_set_paintable(GTK_PICTURE(pic), NULL);
    }
}

// `systemName` has no real GTK equivalent: look the name up in the icon theme (which always returns a
// paintable, falling back to a generic "missing" glyph when unmatched).
static inline void hop_picture_set_icon(void *pic, const char *name, int size) {
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    GtkIconPaintable *icon = gtk_icon_theme_lookup_icon(theme, name, NULL, size > 0 ? size : 64, 1,
                                                        GTK_TEXT_DIR_NONE, (GtkIconLookupFlags)0);
    gtk_picture_set_paintable(GTK_PICTURE(pic), GDK_PAINTABLE(icon));
    if (icon) g_object_unref(icon);
}

// fit: 0=FILL (stretch), 1=CONTAIN (aspect-fit), 2=COVER (aspect-fill), 3=SCALE_DOWN.
static inline void hop_picture_set_content_fit(void *pic, int fit) {
    gtk_picture_set_content_fit(GTK_PICTURE(pic), (GtkContentFit)fit);
}

static inline void hop_picture_natural_size(void *pic, int *out_w, int *out_h) {
    GdkPaintable *p = gtk_picture_get_paintable(GTK_PICTURE(pic));
    int w = p ? gdk_paintable_get_intrinsic_width(p) : 0;
    int h = p ? gdk_paintable_get_intrinsic_height(p) : 0;
    *out_w = w > 0 ? w : 24;
    *out_h = h > 0 ? h : 24;
}

// --- Drop-down (Picker: GtkDropDown + GtkStringList) ------------------------
// Declared after the list section so the `hop_row_fn` / `hop_notify_fn` typedefs are in scope.

static inline void *hop_dropdown_new(void) {
    return gtk_drop_down_new(NULL, NULL);
}

static inline void hop_dropdown_set_strings(void *dd, unsigned count, hop_row_fn cb, void *user_data) {
    GtkStringList *list = gtk_string_list_new(NULL);
    for (unsigned i = 0; i < count; i++) {
        char *s = cb ? cb(i, user_data) : NULL;
        gtk_string_list_append(list, s ? s : "");
        if (s) free(s);
    }
    gtk_drop_down_set_model(GTK_DROP_DOWN(dd), G_LIST_MODEL(list));
    g_object_unref(list);
}

static inline unsigned hop_dropdown_get_selected(void *dd) {
    return gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
}

static inline void hop_dropdown_set_selected(void *dd, unsigned position) {
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), position);
}

static inline unsigned long hop_dropdown_connect_selection(void *dd, hop_notify_fn cb, void *user_data) {
    return g_signal_connect_data(dd, "notify::selected", G_CALLBACK(cb), user_data, NULL, (GConnectFlags)0);
}

// --- Button group (Picker .segmented = linked toggle buttons; .radioGroup = grouped check buttons) ---
// A GtkBox holds mutually-exclusive buttons. Segmented uses GtkToggleButtons in a horizontal `.linked`
// box (the idiomatic GTK segmented look); radioGroup uses GtkCheckButtons (rendered as radios) stacked
// vertically. Each button carries its index + the Swift callback; a "hop-building" flag on the box
// suppresses the signal while we (re)populate or set the selection programmatically.
typedef void (*hop_index_fn)(int index, void *user_data);

static inline void hop_buttongroup_toggled(GtkWidget *btn, gpointer data) {
    (void)data;
    gboolean active = GTK_IS_CHECK_BUTTON(btn) ? gtk_check_button_get_active(GTK_CHECK_BUTTON(btn))
                                               : gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(btn));
    if (!active) return;  // report only the button that turned ON
    GtkWidget *box = gtk_widget_get_parent(btn);
    if (box && g_object_get_data(G_OBJECT(box), "hop-building")) return;  // programmatic change
    hop_index_fn cb = (hop_index_fn)g_object_get_data(G_OBJECT(btn), "hop-cb");
    void *ud = g_object_get_data(G_OBJECT(btn), "hop-ud");
    int idx = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(btn), "hop-idx"));
    if (cb) cb(idx, ud);
}

// horizontal=1 → segmented (linked, equal-width); horizontal=0 → vertical radio group.
static inline void *hop_buttongroup_new(int horizontal) {
    GtkWidget *box = gtk_box_new(horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL,
                                 horizontal ? 0 : 4);
    if (horizontal) gtk_widget_add_css_class(box, "linked");
    return box;
}

// (Re)populate the group: clear children, add `count` buttons (toggle=1 → GtkToggleButton, else
// GtkCheckButton), group them mutually-exclusive, activate `selected`, and wire `cb` on each.
static inline void hop_buttongroup_set_items(void *boxp, unsigned count, hop_row_fn label_cb,
                                             int selected, int toggle, hop_index_fn cb, void *user_data) {
    GtkWidget *box = GTK_WIDGET(boxp);
    int horizontal = gtk_orientable_get_orientation(GTK_ORIENTABLE(box)) == GTK_ORIENTATION_HORIZONTAL;
    g_object_set_data(G_OBJECT(box), "hop-building", GINT_TO_POINTER(1));
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child) { GtkWidget *next = gtk_widget_get_next_sibling(child); gtk_box_remove(GTK_BOX(box), child); child = next; }
    GtkWidget *leader = NULL;
    for (unsigned i = 0; i < count; i++) {
        char *label = label_cb ? label_cb(i, user_data) : NULL;
        GtkWidget *btn = toggle ? gtk_toggle_button_new_with_label(label ? label : "")
                                : gtk_check_button_new_with_label(label ? label : "");
        if (label) free(label);
        if (toggle) {
            if (leader) gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(btn), GTK_TOGGLE_BUTTON(leader));
            else leader = btn;
            if (horizontal) gtk_widget_set_hexpand(btn, TRUE);  // segments share the width equally
        } else {
            if (leader) gtk_check_button_set_group(GTK_CHECK_BUTTON(btn), GTK_CHECK_BUTTON(leader));
            else leader = btn;
        }
        g_object_set_data(G_OBJECT(btn), "hop-cb", (gpointer)cb);
        g_object_set_data(G_OBJECT(btn), "hop-ud", user_data);
        g_object_set_data(G_OBJECT(btn), "hop-idx", GINT_TO_POINTER((int)i));
        g_signal_connect(btn, "toggled", G_CALLBACK(hop_buttongroup_toggled), NULL);
        gtk_box_append(GTK_BOX(box), btn);  // append before set_active so the "building" guard is reachable
        if ((int)i == selected) {
            if (toggle) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(btn), TRUE);
            else gtk_check_button_set_active(GTK_CHECK_BUTTON(btn), TRUE);
        }
    }
    g_object_set_data(G_OBJECT(box), "hop-building", NULL);
}

// Reflect the bound selection without re-firing the callback.
static inline void hop_buttongroup_set_selected(void *boxp, int index) {
    GtkWidget *box = GTK_WIDGET(boxp);
    g_object_set_data(G_OBJECT(box), "hop-building", GINT_TO_POINTER(1));
    int i = 0;
    for (GtkWidget *c = gtk_widget_get_first_child(box); c; c = gtk_widget_get_next_sibling(c), i++) {
        gboolean on = (i == index);
        if (GTK_IS_CHECK_BUTTON(c)) gtk_check_button_set_active(GTK_CHECK_BUTTON(c), on);
        else gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(c), on);
    }
    g_object_set_data(G_OBJECT(box), "hop-building", NULL);
}

// --- Custom drawing (GtkDrawingArea + Cairo) -------------------------------
//
// A GtkDrawingArea is the idiomatic GTK4 surface for arbitrary vector graphics: it calls a draw
// function with a cairo_t the app paints into. Swift drives Cairo directly (cairo.h comes in via
// gtk/gtk.h), so no per-op shims are needed — only this factory + draw-func registration.

typedef void (*hop_draw_fn)(void *area, cairo_t *cr, int width, int height, void *user_data);

static inline void *hop_drawing_area_new(void) {
    return gtk_drawing_area_new();
}

static inline void hop_drawing_area_set_draw_func(void *area, hop_draw_fn cb, void *data) {
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), (GtkDrawingAreaDrawFunc)cb, data, NULL);
}

static inline void hop_widget_queue_draw(void *w) {
    gtk_widget_queue_draw(GTK_WIDGET(w));
}

static inline void hop_widget_set_size_request(void *w, int width, int height) {
    gtk_widget_set_size_request(GTK_WIDGET(w), width, height);
}

// --- Framework-owned layout (GtkFixed absolute positioning) ----------------

// A plain absolute-positioning container; HopUI's layout engine sets every child's frame. GtkFixed
// neither lays out nor (with a non-clip default) clips its children — exactly what we want.
static inline void *hop_fixed_new(void) {
    return gtk_fixed_new();
}

// --- Root container: a GtkFixed driven by a custom GtkLayoutManager ----------------------------------
//
// The window's content is mounted into a GtkFixed whose layout manager is replaced with HopRootLayout —
// the idiomatic GTK4 way to drive a foreign layout system. Using a real GtkFixed (rather than a bare
// GtkWidget subclass) keeps the window fully functional on every backend — accessibility, snapshotting
// and window sizing all behave normally — while the layout manager:
//   • reports a ZERO minimum & natural, so GtkWindow imposes no minimum and honors its default/​user size
//     (the window never ratchets to the content size, and resizes freely both ways);
//   • on allocate (GTK's natural "the content area changed" hook, fired for every resize) re-runs HopUI's
//     layout engine for the new size, then allocates its single child to fill.
typedef void (*hop_relayout_fn)(void *user_data);

static void hop_root_layout_measure(GtkLayoutManager *mgr, GtkWidget *widget, GtkOrientation orientation,
                                    int for_size, int *minimum, int *natural,
                                    int *minimum_baseline, int *natural_baseline) {
    (void)mgr; (void)widget; (void)orientation; (void)for_size;
    // No size preference of our own: the window size comes from gtk_window_set_default_size and the user,
    // not the content (reporting the content's natural makes the window snap to it). Zero minimum lets the
    // window shrink freely; the engine reflows the content to whatever size it is given.
    *minimum = 0;
    *natural = 0;
    if (minimum_baseline) *minimum_baseline = -1;
    if (natural_baseline) *natural_baseline = -1;
}

static void hop_root_layout_allocate(GtkLayoutManager *mgr, GtkWidget *widget,
                                     int width, int height, int baseline) {
    (void)mgr;
    // GTK calls this for every resize. Ask the Swift side to re-run the layout engine for the new size
    // (it defers to an idle tick — running the engine inline would set child size-requests during allocate
    // and make GTK renegotiate the window to the content size), then allocate the single child to fill.
    hop_relayout_fn fn = (hop_relayout_fn)g_object_get_data(G_OBJECT(widget), "hop-relayout-fn");
    void *data = g_object_get_data(G_OBJECT(widget), "hop-relayout-data");
    if (fn) fn(data);
    GtkWidget *child = gtk_widget_get_first_child(widget);
    if (child && gtk_widget_should_layout(child)) {
        GtkAllocation alloc = { 0, 0, width, height };
        gtk_widget_size_allocate(child, &alloc, baseline);
    }
}

static void hop_root_layout_class_init(void *klass, void *data) {
    (void)data;
    GtkLayoutManagerClass *lc = GTK_LAYOUT_MANAGER_CLASS(klass);
    lc->measure = hop_root_layout_measure;
    lc->allocate = hop_root_layout_allocate;
}

static inline GType hop_root_layout_get_type(void) {
    static gsize type_id = 0;
    if (g_once_init_enter(&type_id)) {
        GType t = g_type_from_name("HopRootLayout");  // idempotent across translation units in a process
        if (t == 0) {
            GTypeQuery q;
            g_type_query(GTK_TYPE_LAYOUT_MANAGER, &q);
            GTypeInfo info = { 0 };
            info.class_size = (guint16)q.class_size;
            info.instance_size = (guint16)q.instance_size;
            info.class_init = (GClassInitFunc)hop_root_layout_class_init;
            t = g_type_register_static(GTK_TYPE_LAYOUT_MANAGER, "HopRootLayout", &info, (GTypeFlags)0);
        }
        g_once_init_leave(&type_id, t);
    }
    return (GType)type_id;
}

// A GtkFixed whose layout manager is HopRootLayout. (We don't gtk_fixed_put into it — its single child is
// set via hop_root_container_set_child; the engine's nested GtkFixeds remain ordinary.)
static inline void *hop_root_container_new(void) {
    GtkWidget *w = gtk_fixed_new();
    gtk_widget_set_layout_manager(w, GTK_LAYOUT_MANAGER(g_object_new(hop_root_layout_get_type(), NULL)));
    return w;
}

static inline void hop_root_container_set_child(void *container, void *child) {
    gtk_widget_set_parent(GTK_WIDGET(child), GTK_WIDGET(container));
}

// Register the Swift callback HopRootLayout runs (deferred) when the container is allocated a new size.
static inline void hop_root_container_set_relayout(void *container, hop_relayout_fn fn, void *data) {
    g_object_set_data(G_OBJECT(container), "hop-relayout-fn", (void *)fn);
    g_object_set_data(G_OBJECT(container), "hop-relayout-data", data);
}

static inline int hop_is_fixed(void *w) {
    return GTK_IS_FIXED(GTK_WIDGET(w)) ? 1 : 0;
}

static inline void hop_fixed_put(void *fixed, void *child) {
    gtk_fixed_put(GTK_FIXED(fixed), GTK_WIDGET(child), 0, 0);  // engine repositions via hop_widget_set_frame
}

static inline void hop_fixed_remove(void *fixed, void *child) {
    gtk_fixed_remove(GTK_FIXED(fixed), GTK_WIDGET(child));
}

// Position + size a child (in its GtkFixed parent's coordinate space). size_request forces the exact
// allocation; FILL alignment makes the child occupy it; gtk_fixed_move sets the top-left origin.
static inline void hop_widget_set_frame(void *w, int x, int y, int width, int height) {
    GtkWidget *widget = GTK_WIDGET(w);
    gtk_widget_set_size_request(widget, width, height);
    gtk_widget_set_halign(widget, GTK_ALIGN_FILL);
    gtk_widget_set_valign(widget, GTK_ALIGN_FILL);
    GtkWidget *parent = gtk_widget_get_parent(widget);
    if (parent && GTK_IS_FIXED(parent)) {
        gtk_fixed_move(GTK_FIXED(parent), widget, x, y);
    }
}

// The widget's natural (intrinsic) size for a width constraint (-1 = unconstrained). Clears any prior
// frame size_request first so this reflects content, not the last laid-out size.
static inline void hop_widget_measure(void *w, int for_width, int *out_w, int *out_h) {
    GtkWidget *widget = GTK_WIDGET(w);
    gtk_widget_set_size_request(widget, -1, -1);
    int minw = 0, natw = 0, minh = 0, nath = 0;
    gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minw, &natw, NULL, NULL);
    // Measure height at a width no smaller than the minimum (the MVP doesn't width-wrap, so the natural
    // width is the right basis); measuring below the minimum makes GTK log "measure ... for width of 0".
    int hw = (for_width > minw) ? for_width : natw;
    gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, hw, &minh, &nath, NULL, NULL);
    *out_w = natw;
    *out_h = nath;
}

// The widget's current allocated size (the layout engine's root proposal comes from the window content).
static inline void hop_widget_get_size(void *w, int *out_w, int *out_h) {
    *out_w = gtk_widget_get_width(GTK_WIDGET(w));
    *out_h = gtk_widget_get_height(GTK_WIDGET(w));
}

// Fire `cb` when the window's size changes (GTK4 updates default-width/height on resize), so the
// runtime can re-run the layout pass.
static inline void hop_window_connect_resize(void *win, hop_notify_fn cb, void *data) {
    g_signal_connect_data(win, "notify::default-width", G_CALLBACK(cb), data, NULL, 0);
    g_signal_connect_data(win, "notify::default-height", G_CALLBACK(cb), data, NULL, 0);
}

// --- Scrolled window (a real clipping/scrolling viewport for ScrollView) --------------------------

static inline void *hop_scrolled_window_new(void) {
    GtkWidget *sw = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
    return sw;
}

static inline int hop_is_scrolled_window(void *w) {
    return GTK_IS_SCROLLED_WINDOW(GTK_WIDGET(w)) ? 1 : 0;
}

// The scrollable content (a GtkFixed sized to the full content by the engine); GtkScrolledWindow wraps a
// non-scrollable child in a GtkViewport automatically, so it clips and scrolls without growing the window.
static inline void hop_scrolled_window_set_child(void *sw, void *child) {
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sw), GTK_WIDGET(child));
}

static inline void hop_scrolled_window_get_offset(void *sw, double *x, double *y) {
    GtkAdjustment *ha = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(sw));
    GtkAdjustment *va = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(sw));
    *x = ha ? gtk_adjustment_get_value(ha) : 0;
    *y = va ? gtk_adjustment_get_value(va) : 0;
}

// Notify on scroll (either adjustment's value changes). hop_clicked_fn matches the (object, user_data)
// shape of a GtkAdjustment "value-changed" handler.
static inline void hop_scrolled_window_connect_scroll(void *sw, hop_clicked_fn cb, void *data) {
    GtkAdjustment *ha = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(sw));
    GtkAdjustment *va = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(sw));
    if (ha) g_signal_connect_data(ha, "value-changed", G_CALLBACK(cb), data, NULL, 0);
    if (va) g_signal_connect_data(va, "value-changed", G_CALLBACK(cb), data, NULL, 0);
}

// --- Layout helpers --------------------------------------------------------

static inline void hop_widget_set_margins(void *w, int m) {
    gtk_widget_set_margin_top(GTK_WIDGET(w), m);
    gtk_widget_set_margin_bottom(GTK_WIDGET(w), m);
    gtk_widget_set_margin_start(GTK_WIDGET(w), m);
    gtk_widget_set_margin_end(GTK_WIDGET(w), m);
}

static inline void hop_widget_center(void *w) {
    gtk_widget_set_halign(GTK_WIDGET(w), GTK_ALIGN_CENTER);
    gtk_widget_set_valign(GTK_WIDGET(w), GTK_ALIGN_CENTER);
}

// --- Main-loop scheduling --------------------------------------------------

typedef int (*hop_idle_fn)(void *user_data);

// Run `cb` once on the GLib main loop (idle priority); `cb` returns G_SOURCE_REMOVE to not repeat.
static inline void hop_idle_add(hop_idle_fn cb, void *data) {
    g_idle_add((GSourceFunc)cb, data);
}

// Run `cb` after `ms` milliseconds (returns G_SOURCE_REMOVE to not repeat).
static inline void hop_timeout_add(unsigned ms, hop_idle_fn cb, void *data) {
    g_timeout_add(ms, (GSourceFunc)cb, data);
}

// Like hop_timeout_add but returns the source id so a repeating timer can be removed.
static inline unsigned hop_timeout_add_id(unsigned ms, hop_idle_fn cb, void *data) {
    return g_timeout_add(ms, (GSourceFunc)cb, data);
}
static inline void hop_source_remove(unsigned id) { g_source_remove(id); }

// --- Progress bar (ProgressView) -------------------------------------------

static inline void *hop_progress_bar_new(void) {
    GtkWidget *pb = gtk_progress_bar_new();
    gtk_widget_set_size_request(pb, 240, -1);
    return pb;
}
static inline void hop_progress_set_fraction(void *pb, double fraction) {
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(pb), fraction);
}
static inline void hop_progress_pulse(void *pb) {
    gtk_progress_bar_pulse(GTK_PROGRESS_BAR(pb));
}

// A bare GLib main loop on the default context — used by the headless executor check (no GTK window).
static inline void *hop_main_loop_new(void) { return g_main_loop_new(NULL, FALSE); }
static inline void hop_main_loop_run(void *loop) { g_main_loop_run((GMainLoop *)loop); }
static inline void hop_main_loop_quit(void *loop) { g_main_loop_quit((GMainLoop *)loop); }
static inline void hop_main_loop_unref(void *loop) { g_main_loop_unref((GMainLoop *)loop); }

// --- Styling (color / font / background via inline CSS) --------------------

// Apply inline CSS (e.g. "* { color: rgba(...); font-size: 18px; }") to a single widget by attaching
// a dedicated CSS provider to its style context.
// Add a CSS style class (e.g. Adwaita's built-in ".card" for a rounded, bordered, filled box).
static inline void hop_widget_add_css_class(void *widget, const char *cls) {
    gtk_widget_add_css_class(GTK_WIDGET(widget), cls);
}

static inline void hop_widget_set_css(void *widget, const char *css) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, css);
    gtk_style_context_add_provider(gtk_widget_get_style_context(GTK_WIDGET(widget)),
                                   GTK_STYLE_PROVIDER(provider),
                                   GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    g_object_unref(provider);
}

// --- Appearance (light/dark) -----------------------------------------------

// Toggle the GTK application's dark-theme preference (affects all windows).
static inline void hop_set_prefer_dark(int dark) {
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_set(settings, "gtk-application-prefer-dark-theme", dark ? TRUE : FALSE, NULL);
}

// --- Accessibility (GtkAccessible properties/state) ------------------------

static inline void hop_a11y_label(void *w, const char *s) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_LABEL, s, -1);
}
static inline void hop_a11y_description(void *w, const char *s) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, s, -1);
}
static inline void hop_a11y_hidden(void *w, int hidden) {
    gtk_accessible_update_state(GTK_ACCESSIBLE(w), GTK_ACCESSIBLE_STATE_HIDDEN, hidden ? TRUE : FALSE, -1);
}
// `.accessibilityIdentifier`: GTK's stable, programmatic widget id is the widget *name* — visible in
// GtkInspector and surfaced to AT-SPI tooling (the analog of Qt's objectName / AppKit's
// accessibilityIdentifier / WinUI's AutomationId). GTK has no dedicated AT-SPI "id" property to set.
static inline void hop_a11y_identifier(void *w, const char *s) {
    gtk_widget_set_name(GTK_WIDGET(w), s);
}

// --- GObject lifetime ------------------------------------------------------

static inline void hop_object_ref_sink(void *o) { g_object_ref_sink(o); }
static inline void hop_object_unref(void *o) { g_object_unref(o); }

#endif /* HOP_CGTK4_SHIM_H */

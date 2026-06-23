// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Pure-C surface over WinUI 3 (Microsoft.UI.Xaml), implemented in C++/WinRT in shim.cpp. HopWinUI imports
// only this header — no WinRT/C++ types leak into Swift — exactly like HopQt imports CQt. Handles are
// opaque `void*` pointers to heap-held `FrameworkElement`s (one strong reference each); free with
// hopwinui_release. Strings cross as UTF-8. Colors cross as four 0…1 doubles (r,g,b,a). Callbacks carry an
// opaque `user_data` (the Swift toolkit recovers its widget via Unmanaged), and fire on the UI thread.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*hopwinui_ready_cb)(void* root, void* user_data);
typedef void (*hopwinui_void_cb)(void* user_data);
typedef void (*hopwinui_double_cb)(double value, void* user_data);
typedef void (*hopwinui_bool_cb)(int32_t on, void* user_data);
typedef void (*hopwinui_int_cb)(int32_t value, void* user_data);
typedef void (*hopwinui_string_cb)(const char* utf8, void* user_data);
typedef void (*hopwinui_size_cb)(double width, double height, void* user_data);
typedef void (*hopwinui_color_cb)(double r, double g, double b, double a, void* user_data);
typedef void (*hopwinui_files_cb)(const char* const* paths_utf8, int32_t count, void* user_data);  // count 0 = cancelled
typedef void (*hopwinui_file_cb)(const char* path_utf8, void* user_data);                          // NULL = cancelled

// MARK: app / run loop
// Bootstrap the Windows App Runtime, start the XAML Application, create the main Window + root Canvas,
// invoke on_ready(rootCanvas, ud), activate, and run the message loop (blocks until the app exits).
void hopwinui_run(const char* title_utf8, hopwinui_ready_cb on_ready, void* user_data);
void hopwinui_open_window(const char* title_utf8, hopwinui_ready_cb on_ready, void* user_data);
void hopwinui_set_relayout(hopwinui_void_cb handler, void* user_data);
void hopwinui_content_size(double* out_w, double* out_h);
void hopwinui_schedule_on_main(hopwinui_void_cb work, void* user_data);
void hopwinui_set_color_scheme(int32_t scheme);  // 0 = follow system, 1 = light, 2 = dark

// MARK: handle lifetime
void hopwinui_release(void* handle);

// MARK: element creation
void* hopwinui_canvas_new(void);
void* hopwinui_stackpanel_new(int32_t vertical);
void* hopwinui_border_new(void);
void* hopwinui_scrollviewer_new(void);
void* hopwinui_textblock_new(void);
void* hopwinui_button_new(void);
void* hopwinui_textbox_new(void);
void* hopwinui_passwordbox_new(void);
void* hopwinui_toggleswitch_new(void);   // switch toggle
void* hopwinui_checkbox_new(void);       // .toggleStyle(.checkbox)
void* hopwinui_togglebutton_new(void);   // .toggleStyle(.button)
void* hopwinui_slider_new(void);
void* hopwinui_listview_new(void);
void* hopwinui_combobox_new(void);
void* hopwinui_progressbar_new(void);
void* hopwinui_image_new(void);
void* hopwinui_path_new(void);
void* hopwinui_calendardatepicker_new(void);
void* hopwinui_timepicker_new(void);
void* hopwinui_colorpicker_new(void);

// MARK: framework-element layout / common
void hopwinui_set_frame(void* h, double x, double y, double w, double height);  // Canvas.Left/Top + Width/Height
void hopwinui_set_size(void* h, double w, double height);                       // Width/Height only
void hopwinui_canvas_setpos(void* h, double x, double y);                       // Canvas.Left/Top only
void hopwinui_measure(void* h, double avail_w, double avail_h, double* out_w, double* out_h);
void hopwinui_actual_size(void* h, double* out_w, double* out_h);
void hopwinui_set_visible(void* h, int32_t visible);
void hopwinui_set_opacity(void* h, double opacity);
void hopwinui_set_enabled(void* h, int32_t enabled);
void hopwinui_set_min_width(void* h, double w);
void hopwinui_set_background(void* h, double r, double g, double b, double a);
void hopwinui_set_automation_name(void* h, const char* utf8);
void hopwinui_set_automation_id(void* h, const char* utf8);

// MARK: containers
void hopwinui_panel_insert(void* panel, void* child, int32_t index);
void hopwinui_panel_remove(void* panel, void* child);
void hopwinui_panel_move(void* panel, void* child, int32_t index);
void hopwinui_scrollviewer_set_content(void* sv, void* child);
void hopwinui_scrollviewer_connect(void* sv, hopwinui_size_cb cb, void* user_data);
void hopwinui_scrollviewer_offset(void* sv, double* out_x, double* out_y);

// MARK: TextBlock
void hopwinui_textblock_set_text(void* h, const char* utf8);
void hopwinui_textblock_set_foreground(void* h, double r, double g, double b, double a);
void hopwinui_textblock_set_font(void* h, double size, const char* family_or_null, int32_t weight, int32_t is_italic);
void hopwinui_textblock_set_alignment(void* h, int32_t alignment);  // 0=left, 1=center, 2=right

// MARK: Button
void hopwinui_button_set_text(void* h, const char* utf8);
void hopwinui_button_connect(void* h, hopwinui_void_cb cb, void* user_data);

// `.onTapGesture`: wire any UIElement's Tapped (count==1) or DoubleTapped (count>=2) event to `cb`.
void hopwinui_tap_connect(void* h, int32_t count, hopwinui_void_cb cb, void* user_data);

// `.onLongPressGesture`: wire the Holding event (fires when HoldingState becomes Started).
void hopwinui_longpress_connect(void* h, hopwinui_void_cb cb, void* user_data);
// `.onHover`: wire PointerEntered (entered=1) / PointerExited (entered=0).
typedef void (*hopwinui_hover_cb)(void* user_data, int entered);
void hopwinui_hover_connect(void* h, hopwinui_hover_cb cb, void* user_data);
// `.gesture(DragGesture())`: wire PointerPressed/Moved/Released; cb gets start + current point + ended flag.
typedef void (*hopwinui_drag_cb)(void* user_data, double sx, double sy, double cx, double cy, int ended);
void hopwinui_drag_connect(void* h, hopwinui_drag_cb cb, void* user_data);
// `.gesture(MagnifyGesture()/RotateGesture())`: ManipulationMode(Scale|Rotate|Translate) + ManipulationDelta.
// cb gets CUMULATIVE scale (1.0 = no change) + rotation in DEGREES; ended: 0 = ongoing, 1 = completed.
typedef void (*hopwinui_manip_cb)(void* user_data, double cum_scale, double cum_rotation_degrees, int ended);
void hopwinui_manip_connect(void* h, hopwinui_manip_cb cb, void* user_data);

// MARK: TextBox / PasswordBox
char* hopwinui_textbox_text(void* h);  // malloc'd UTF-8; caller frees
void hopwinui_textbox_set_text(void* h, const char* utf8);
void hopwinui_textbox_set_placeholder(void* h, const char* utf8);
void hopwinui_textbox_set_multiline(void* h, int32_t enabled);   // TextEditor: AcceptsReturn + Wrap + scroll + stretch
void hopwinui_textbox_connect(void* h, hopwinui_string_cb cb, void* user_data);
void hopwinui_textbox_connect_submit(void* h, hopwinui_void_cb cb, void* user_data);
char* hopwinui_passwordbox_text(void* h);
void hopwinui_passwordbox_set_text(void* h, const char* utf8);
void hopwinui_passwordbox_set_placeholder(void* h, const char* utf8);
void hopwinui_passwordbox_connect(void* h, hopwinui_string_cb cb, void* user_data);

// MARK: ToggleSwitch
int32_t hopwinui_toggle_is_on(void* h);
void hopwinui_toggle_set_on(void* h, int32_t on);
void hopwinui_toggle_connect(void* h, hopwinui_bool_cb cb, void* user_data);
void hopwinui_toggle_set_label(void* h, const char* utf8);  // checkbox/button content label (no-op for switch)

// MARK: Slider
void hopwinui_slider_set_range(void* h, double minimum, double maximum);
double hopwinui_slider_value(void* h);
void hopwinui_slider_set_value(void* h, double v);
void hopwinui_slider_connect(void* h, hopwinui_double_cb cb, void* user_data);

// MARK: ProgressBar
void hopwinui_progress_set_value(void* h, double fraction);
void hopwinui_progress_set_indeterminate(void* h);

// MARK: ListView (also used for the flattened outline)
void hopwinui_listview_set_items(void* h, const char* const* items_utf8, int32_t count);
int32_t hopwinui_listview_selected(void* h);
void hopwinui_listview_set_selected(void* h, int32_t index);
void hopwinui_listview_connect(void* h, hopwinui_int_cb cb, void* user_data);

// MARK: ComboBox (Picker)
void hopwinui_combobox_set_items(void* h, const char* const* items_utf8, int32_t count);
int32_t hopwinui_combobox_selected(void* h);
void hopwinui_combobox_set_selected(void* h, int32_t index);
void hopwinui_combobox_connect(void* h, hopwinui_int_cb cb, void* user_data);

// Modals. Alert: a ContentDialog (buttons '\n'-joined, up to 3); `cb` reports the clicked index (-1 if none).
void hopwinui_alert_show(const char* title, const char* message, const char* buttons_nl, hopwinui_int_cb cb, void* user_data);
// Sheet: a ContentDialog hosting a Canvas (HopUI content is mounted into it). `cb` fires when it closes.
void* hopwinui_sheet_new(void);
void* hopwinui_sheet_canvas(void* dialog);
void hopwinui_sheet_show(void* dialog, hopwinui_void_cb on_dismiss, void* user_data);
void hopwinui_sheet_close(void* dialog);

// Button group (Picker .segmented / .radioGroup). horizontal=1 → segmented row; toggle=1 → ToggleButtons
// (segmented), toggle=0 → RadioButtons. `cb` reports the checked button's index.
void* hopwinui_buttongroup_new(int32_t horizontal);
void hopwinui_buttongroup_set_items(void* h, const char* const* items_utf8, int32_t count, int32_t selected,
                                    int32_t toggle, hopwinui_int_cb cb, void* user_data);
void hopwinui_buttongroup_set_selected(void* h, int32_t index);

// MARK: Image
void hopwinui_image_set_file(void* h, const char* path_utf8);
void hopwinui_image_set_stretch(void* h, int32_t mode);  // 0 none, 1 uniform, 2 uniformToFill, 3 fill

// MARK: Shapes.Path — build a geometry (begin → segments/primitives → commit), style, and transform
void hopwinui_path_begin(void* h);
void hopwinui_path_move(void* h, double x, double y);
void hopwinui_path_line(void* h, double x, double y);
void hopwinui_path_quad(void* h, double cx, double cy, double x, double y);
void hopwinui_path_cubic(void* h, double c1x, double c1y, double c2x, double c2y, double x, double y);
void hopwinui_path_arc(void* h, double x, double y, double radius, int32_t clockwise, int32_t large_arc);
void hopwinui_path_close_figure(void* h, int32_t closed);
void hopwinui_path_add_rect(void* h, double x, double y, double w, double height);
void hopwinui_path_add_round_rect(void* h, double x, double y, double w, double height, double rx, double ry);
void hopwinui_path_add_ellipse(void* h, double cx, double cy, double rx, double ry);
void hopwinui_path_commit(void* h);
void hopwinui_path_set_fill(void* h, double r, double g, double b, double a);
void hopwinui_path_set_stroke(void* h, double r, double g, double b, double a, double thickness);
// Gradient fills (absolute coordinates). `stops` is `stopCount` packed 5-tuples (offset, r, g, b, a).
// WinUI XAML has LinearGradientBrush + RadialGradientBrush but no conic brush — angular gradients are
// approximated with the radial brush by the Swift side.
void hopwinui_path_set_fill_linear(void* h, double x0, double y0, double x1, double y1, const double* stops, int stopCount);
void hopwinui_path_set_fill_radial(void* h, double cx, double cy, double rx, double ry, const double* stops, int stopCount);
void hopwinui_path_clear_fill(void* h);
void hopwinui_path_clear_stroke(void* h);
void hopwinui_path_set_transform(void* h, double cx, double cy, double tx, double ty, double rotation_deg, double sx, double sy);

// MARK: CalendarDatePicker / TimePicker (dates as seconds-since-1970 UTC; times as seconds-of-day)
void hopwinui_datepicker_set_date(void* h, double secs1970);
double hopwinui_datepicker_date(void* h);  // NaN when unset
void hopwinui_datepicker_connect(void* h, hopwinui_double_cb cb, void* user_data);
void hopwinui_timepicker_set_time(void* h, double secs_of_day);
double hopwinui_timepicker_time(void* h);
void hopwinui_timepicker_connect(void* h, hopwinui_double_cb cb, void* user_data);

// MARK: ColorPicker
void hopwinui_colorpicker_set_color(void* h, double r, double g, double b, double a);
void hopwinui_colorpicker_set_alpha_enabled(void* h, int32_t enabled);
void hopwinui_colorpicker_connect(void* h, hopwinui_color_cb cb, void* user_data);

// MARK: Menu (Button + MenuFlyout). A "menu container" handle is the MenuFlyout or a submenu's item list.
void* hopwinui_menubutton_new(void);
void hopwinui_menubutton_set_label(void* h, const char* utf8);
void* hopwinui_menubutton_flyout(void* h);             // the MenuFlyout container handle
void hopwinui_menu_clear(void* container);
void hopwinui_menu_add_item(void* container, const char* title_utf8, hopwinui_void_cb cb, void* user_data);
void hopwinui_menu_add_separator(void* container);
void* hopwinui_menu_add_submenu(void* container, const char* title_utf8);  // returns a child container handle

// MARK: File pickers (native FileOpenPicker / FileSavePicker; results arrive on the UI thread)
void hopwinui_open_file_picker(const char* const* extensions, int32_t ext_count, int32_t multiple, hopwinui_files_cb cb, void* user_data);
void hopwinui_save_file_picker(const char* default_name, const char* extension, const char* type_name, hopwinui_file_cb cb, void* user_data);

#ifdef __cplusplus
}
#endif

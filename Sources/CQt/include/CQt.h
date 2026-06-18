// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Pure-C surface over the C++ Qt6 toolkit. Swift imports only this header (no Qt/C++ types cross
// the boundary); the implementation in shim.cpp includes QtWidgets and does the real work. This
// mirrors the GTK4 shim approach, but here the shim is C++ because Qt has no C ABI.

#ifndef HOP_CQT_H
#define HOP_CQT_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*hopqt_void_cb)(void *user_data);
typedef void (*hopqt_text_cb)(const char *text, void *user_data);
typedef void (*hopqt_double_cb)(double value, void *user_data);
// Returns a malloc'd C string for the row; the shim frees it after copying into a QString.
typedef char *(*hopqt_row_cb)(int position, void *user_data);
typedef void (*hopqt_int_cb)(int value, void *user_data);
// Returns an integer (e.g. an outline row's depth) for the given flattened position.
typedef int (*hopqt_intret_cb)(int position, void *user_data);
// Reports a string value (e.g. the selected outline row's key); NULL means "no value / cleared".
typedef void (*hopqt_str_cb)(const char *value, void *user_data);
// Called during a shape widget's paintEvent with an opaque QPainter and the widget's pixel size.
typedef void (*hopqt_paint_cb)(void *painter, int width, int height, void *user_data);
// Runs a single main-actor job pointer (used by the custom main-actor executor).
typedef void (*hop_job_main_fn)(void *job);

// Application & window
void *hopqt_app_new(void);
int hopqt_app_exec(void *app);
// Run a one-shot callback on the main (GUI) thread's event loop (a zero-delay single-shot timer).
void hopqt_post(hopqt_void_cb cb, void *user_data);
// Thread-safe: post `fn(job)` to run on the main (GUI) thread, callable from any thread (used by the
// custom main-actor executor, whose enqueue may happen on a background thread).
void hopqt_run_on_main(void *job, hop_job_main_fn fn);
// Set the application's light/dark color scheme (Qt 6.8+ QStyleHints).
void hopqt_set_color_scheme(int dark);

// Accessibility (QAccessible name/description + objectName as the test identifier).
void hopqt_set_accessible_name(void *widget, const char *name);
void hopqt_set_accessible_description(void *widget, const char *desc);
void hopqt_set_object_name(void *widget, const char *name);
void *hopqt_window_new(const char *title);
void hopqt_window_set_central(void *window, void *child);
void hopqt_window_show(void *window);

// Layout containers (a QWidget owning a QVBoxLayout / QHBoxLayout)
void *hopqt_vbox_new(int spacing);
void *hopqt_hbox_new(int spacing);
void hopqt_box_add(void *box, void *child);
void hopqt_box_insert(void *box, void *child, int index);
void hopqt_box_reorder(void *box, void *child, int index);
void hopqt_box_remove(void *box, void *child);
void hopqt_box_set_spacing(void *box, int spacing);

// Framework-owned layout: a plain QWidget (no layout manager) whose children HopUI positions absolutely.
typedef void (*hopqt_resize_cb)(int width, int height, void *user_data);
void *hopqt_fixed_new(void);
void hopqt_fixed_add(void *parent, void *child);     // reparent + show; engine positions via set_geometry
void hopqt_fixed_remove(void *child);                // detach (setParent(nullptr))
void hopqt_fixed_connect_resize(void *fixed, hopqt_resize_cb cb, void *user_data);
void hopqt_widget_set_geometry(void *widget, int x, int y, int width, int height);
void hopqt_widget_resize(void *widget, int width, int height);     // size only (scroll content; QScrollArea owns the position)
void hopqt_widget_size_hint(void *widget, int *out_w, int *out_h);  // intrinsic size
void hopqt_widget_size(void *widget, int *out_w, int *out_h);       // current allocated size

// Scroll viewport (a real clipping/scrolling QScrollArea for ScrollView)
void *hopqt_scrollarea_new(void);
void hopqt_scrollarea_set_content(void *area, void *widget);                       // the single scrollable content
void hopqt_scrollarea_offset(void *area, int *out_x, int *out_y);                  // current scroll offset
void hopqt_scrollarea_connect_scroll(void *area, hopqt_resize_cb cb, void *user_data);  // cb(xOffset, yOffset, user_data)

// Apply an inline stylesheet (e.g. "color: rgba(...); font-size: 18px;") to a widget.
void hopqt_widget_set_style(void *widget, const char *css);
void hopqt_widget_make_card(void *widget);  // rounded/bordered/filled card chrome (GroupBox/Section)

// Label
void *hopqt_label_new(const char *text);
void hopqt_label_set_text(void *label, const char *text);
// Wrapping-aware measure: constrained width + wrapped height when for_width < the single-line width.
void hopqt_label_measure(void *label, int for_width, int *out_w, int *out_h);

// Button
void *hopqt_button_new(const char *text);
void hopqt_button_set_text(void *button, const char *text);
void hopqt_button_connect(void *button, hopqt_void_cb cb, void *user_data);

// `.onTapGesture`: install an event filter on any widget that fires `cb` on a (count==1) mouse release
// or (count>=2) double-click. Returns the filter object; pass it to hopqt_tap_remove to detach.
void *hopqt_tap_install(void *widget, int count, hopqt_void_cb cb, void *user_data);
void hopqt_tap_remove(void *widget, void *filter);

// Text field
void *hopqt_lineedit_new(const char *placeholder);
void hopqt_lineedit_set_text(void *edit, const char *text);
void hopqt_lineedit_set_placeholder(void *edit, const char *text);
const char *hopqt_lineedit_text(void *edit);
void hopqt_lineedit_connect(void *edit, hopqt_text_cb cb, void *user_data);

// Slider
void *hopqt_slider_new(double min, double max);
void hopqt_slider_set_range(void *slider, double min, double max);
void hopqt_slider_set_value(void *slider, double value);
double hopqt_slider_value(void *slider);
void hopqt_slider_connect(void *slider, hopqt_double_cb cb, void *user_data);

// Date/time picker (QDateTimeEdit with a calendar popup). The value is exchanged as a Unix timestamp
// (seconds since the epoch) so the Swift side converts to/from a Foundation Date.
void *hopqt_datetime_new(void);
void hopqt_datetime_set_components(void *edit, int want_date, int want_time);
void hopqt_datetime_set(void *edit, double unix_seconds);
double hopqt_datetime_get(void *edit);
void hopqt_datetime_set_range(void *edit, int has_min, double min_unix, int has_max, double max_unix);
void hopqt_datetime_connect(void *edit, hopqt_double_cb cb, void *user_data);

// Color well: a swatch QPushButton that opens a QColorDialog. Components are four 0..1 doubles.
typedef void (*hopqt_color_cb)(double r, double g, double b, double a, void *user_data);
void *hopqt_colorwell_new(void);
void hopqt_colorwell_set(void *btn, double r, double g, double b, double a);
void hopqt_colorwell_set_alpha(void *btn, int support_alpha);
double hopqt_colorwell_red(void *btn);
double hopqt_colorwell_green(void *btn);
double hopqt_colorwell_blue(void *btn);
double hopqt_colorwell_alpha(void *btn);
void hopqt_colorwell_connect(void *btn, hopqt_color_cb cb, void *user_data);

// Modal file dialogs. Return newline-joined absolute paths (open; possibly several) / the single chosen
// path (save), malloc'd (free with free()), or NULL on cancel. `filter` is a Qt filter string, e.g.
// "JSON (*.json);;All Files (*)".
char *hopqt_file_open(void *widget, int multiple, const char *filter);
char *hopqt_file_save(void *widget, const char *default_name, const char *filter);

// Menu bar (QMenuBar on the QMainWindow). `command` codes: 0 cut, 1 copy, 2 paste, 3 undo,
// 4 redo, 5 select-all.
void *hopqt_menu_bar(void *window);
void *hopqt_menu_add(void *menubar, const char *title);
void hopqt_menu_add_button(void *menu, const char *title, hopqt_void_cb cb, void *user_data);
void hopqt_menu_add_command(void *menu, const char *title, int command);
void hopqt_menu_add_separator(void *menu);

// Top toolbar (QToolBar on the QMainWindow)
void *hopqt_toolbar_add(void *window);
void hopqt_toolbar_add_button(void *toolbar, const char *title, hopqt_void_cb cb, void *user_data);
void hopqt_toolbar_add_label(void *toolbar, const char *text);
void hopqt_toolbar_clear(void *toolbar);

// Split view (QSplitter)
void *hopqt_splitter_new(void);
void hopqt_splitter_add(void *splitter, void *child);
void hopqt_splitter_set_sizes(void *splitter, int first, int second);

// Custom shapes (a QWidget whose paintEvent calls back into Swift to drive QPainter — the idiomatic
// Qt way to render arbitrary vector graphics).
void *hopqt_shape_new(hopqt_paint_cb cb, void *user_data);
void hopqt_shape_update(void *widget);
// Fixed size from `.frame(width:height:)` (pass -1 for an axis to leave it unconstrained).
void hopqt_widget_set_fixed_size(void *widget, int width, int height);

// QPainter transform/paint operations (called from within a paint callback).
void hopqt_painter_save(void *painter);
void hopqt_painter_restore(void *painter);
void hopqt_painter_translate(void *painter, double dx, double dy);
void hopqt_painter_rotate(void *painter, double degrees);
void hopqt_painter_scale(void *painter, double sx, double sy);
void hopqt_painter_fill_path(void *painter, void *path, double r, double g, double b, double a);
void hopqt_painter_stroke_path(void *painter, void *path, double r, double g, double b, double a, double width);

// QPainterPath construction (built by Swift, then filled/stroked, then freed).
void *hopqt_path_new(void);
void hopqt_path_free(void *path);
void hopqt_path_move_to(void *path, double x, double y);
void hopqt_path_line_to(void *path, double x, double y);
void hopqt_path_cubic_to(void *path, double c1x, double c1y, double c2x, double c2y, double x, double y);
void hopqt_path_quad_to(void *path, double cx, double cy, double x, double y);
void hopqt_path_close(void *path);
void hopqt_path_add_rect(void *path, double x, double y, double w, double h);
void hopqt_path_add_rounded_rect(void *path, double x, double y, double w, double h, double rx, double ry);
void hopqt_path_add_ellipse(void *path, double x, double y, double w, double h);
void hopqt_path_add_arc(void *path, double cx, double cy, double r, double start_rad, double end_rad, int clockwise);

// Drop-down menu button (QPushButton with an attached QMenu) — for the `Menu` view.
void *hopqt_menubutton_new(const char *label);
void *hopqt_menubutton_menu(void *button);              // the button's QMenu, to (re)build items into
void *hopqt_menu_add_submenu(void *menu, const char *title);  // returns the child QMenu
void hopqt_menu_clear(void *menu);

// Separator line (Divider).
void *hopqt_separator_new(void);

// Offscreen raster rendering (QImage + QPainter) — for headless shape pixel tests; no display or
// QApplication needed (the raster paint engine is self-contained). Pixels are read as 0xAARRGGBB.
void *hopqt_image_new(int width, int height);   // ARGB32, filled opaque white
void hopqt_image_free(void *image);
void *hopqt_image_begin(void *image);           // returns an antialiased QPainter on the image
void hopqt_image_end(void *painter);            // QPainter::end + delete
unsigned hopqt_image_pixel(void *image, int x, int y);
int hopqt_image_save_png(void *image, const char *path);

// Progress bar (ProgressView): a fraction is determinate; indeterminate shows Qt's busy animation.
void *hopqt_progress_new(void);
void hopqt_progress_set_fraction(void *bar, double fraction);
void hopqt_progress_set_indeterminate(void *bar);

// Selection drop-down (QComboBox) — for the `Picker` view.
void *hopqt_combo_new(void);
void hopqt_combo_set_items(void *combo, int count, hopqt_row_cb row_cb, void *user_data);
int hopqt_combo_selected(void *combo);
void hopqt_combo_set_selected(void *combo, int index);
void hopqt_combo_connect(void *combo, hopqt_int_cb cb, void *user_data);

// Button group (Picker .segmented / .radioGroup). horizontal=1 → segmented; toggle=1 → checkable
// push buttons (segmented), toggle=0 → radio buttons. `cb` reports the clicked button's index.
void *hopqt_buttongroup_new(int horizontal);
void hopqt_buttongroup_set_items(void *widget, int count, hopqt_row_cb row_cb, int selected, int toggle,
                                 hopqt_int_cb cb, void *user_data);
void hopqt_buttongroup_set_selected(void *widget, int index);

// Lazy list (QListView + a custom QAbstractListModel that fetches rows on demand)
void *hopqt_list_new(void);
void hopqt_list_set_model(void *list, int count, hopqt_row_cb row_cb, void *user_data);
void hopqt_list_connect_selection(void *list, hopqt_int_cb cb, void *user_data);
int hopqt_list_selected(void *list);
void hopqt_list_set_selected(void *list, int index);
void hopqt_list_set_sidebar(void *list, int sidebar);  // source-list/sidebar styling (frameless, inset selection)

// Hierarchical tree (QTreeWidget): an OutlineGroup. Rows are a pre-order flattened (title, key, depth)
// sequence; the shim reconstructs the nested QTreeWidgetItems from depth and reports selection by key.
void *hopqt_tree_new(void);
void hopqt_tree_set_sidebar(void *tree, int sidebar);
void hopqt_tree_set_rows(void *tree, int count, hopqt_row_cb title_cb, hopqt_row_cb key_cb,
                         hopqt_intret_cb depth_cb, hopqt_intret_cb selectable_cb, void *user_data);
void hopqt_tree_connect_selection(void *tree, hopqt_str_cb cb, void *user_data);
char *hopqt_tree_selected_key(void *tree);  // malloc'd; Swift frees with free(). NULL if nothing selected.
void hopqt_tree_select_key(void *tree, const char *key);  // NULL clears the selection

// Image (a QWidget that paints a QPixmap with the right aspect mode). systemName has no Qt equivalent,
// so it falls back to QIcon::fromTheme (then a generic icon).
void *hopqt_imageview_new(void);
void hopqt_imageview_set_file(void *view, const char *path);
void hopqt_imageview_set_data(void *view, const unsigned char *data, int len);
void hopqt_imageview_set_icon(void *view, const char *name);
void hopqt_imageview_set_mode(void *view, int resizable, int mode);  // mode: 0=stretch 1=fit 2=fill
void hopqt_image_natural_size(void *view, int *out_w, int *out_h);

// Switch (Toggle: QCheckBox) and password mode for a line edit (SecureField).
void *hopqt_switch_new(void);
void hopqt_switch_set_checked(void *box, int on);
int hopqt_switch_checked(void *box);
void hopqt_switch_connect(void *box, hopqt_int_cb cb, void *user_data);  // reports 0/1
void hopqt_lineedit_set_password(void *lineedit, int on);

// Tabbed container (TabView: QTabWidget). Pages are added as child widgets; titles/selection set after.
void *hopqt_tabwidget_new(void);
void hopqt_tabwidget_add(void *tabs, void *page, const char *label);
void hopqt_tabwidget_set_tab_text(void *tabs, int index, const char *label);
void hopqt_tabwidget_set_current(void *tabs, int index);
int hopqt_tabwidget_current(void *tabs);
void hopqt_tabwidget_connect(void *tabs, hopqt_int_cb cb, void *user_data);  // currentChanged(index)
void hopqt_tabwidget_remove(void *tabs, void *page);

#ifdef __cplusplus
}
#endif

#endif /* HOP_CQT_H */

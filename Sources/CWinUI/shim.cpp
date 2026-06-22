// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// C++/WinRT implementation of the pure-C ``CWinUI.h`` surface. This is the WinUI 3 analogue of CQt's
// shim.cpp: it owns all the winrt types and exposes only C functions, so HopWinUI (Swift) never touches a
// WinRT/C++ type. Handles are heap-held `FrameworkElement`s (one strong ref each); callbacks fire on the UI
// thread and carry the Swift toolkit's `user_data` back across the boundary.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <unknwn.h>
#undef GetCurrentTime
#include <MddBootstrap.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Windows.System.h>
// Full (not just consuming) Input header: defines the TappedEventHandler / DoubleTappedEventHandler
// delegate constructor templates used by hopwinui_tap_connect. Without it only the `.2.h` forward-decl is
// pulled in, so the constructor is declared-but-not-defined and Clang rejects instantiating it with a
// no-linkage local lambda ("used but not defined in this translation unit").
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Input.h>  // HoldingState, PointerPoint (for the long-press / drag gestures)
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Pickers.h>
#include <microsoft.ui.xaml.window.h>  // IWindowNative (the picker needs the window's HWND when unpackaged)
#include <shobjidl_core.h>             // IInitializeWithWindow

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <array>
#include <memory>
#include <vector>
#include <limits>

#include "CWinUI.h"

using namespace winrt;
namespace mux = winrt::Microsoft::UI::Xaml;
namespace muxc = winrt::Microsoft::UI::Xaml::Controls;
namespace muxm = winrt::Microsoft::UI::Xaml::Media;
namespace muxs = winrt::Microsoft::UI::Xaml::Shapes;
namespace wf = winrt::Windows::Foundation;
namespace wui = winrt::Windows::UI;

// ---------------------------------------------------------------------------------------------------
// Handles + small conversions
// ---------------------------------------------------------------------------------------------------
using Element = mux::FrameworkElement;
// winrt projection types delete `operator new`, so a handle is a heap struct holding one (a strong ref).
namespace { struct Handle { Element e; }; }
static Element elem(void* h) { return reinterpret_cast<Handle*>(h)->e; }
static void* mk(Element const& e) { return new Handle{e}; }
template <typename T> static T as(void* h) { return elem(h).try_as<T>(); }

static hstring hs(const char* u) { return u ? winrt::to_hstring(std::string_view(u)) : hstring{}; }
static char* dup(hstring const& h) {
    std::string s = winrt::to_string(h);
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}
static wui::Color col(double r, double g, double b, double a) {
    auto ch = [](double v) { return static_cast<uint8_t>(std::clamp(static_cast<int>(std::lround(v * 255.0)), 0, 255)); };
    wui::Color c; c.A = ch(a); c.R = ch(r); c.G = ch(g); c.B = ch(b); return c;
}
static muxm::SolidColorBrush brush(double r, double g, double b, double a) { return muxm::SolidColorBrush(col(r, g, b, a)); }
static float favail(double v) { return std::isfinite(v) ? static_cast<float>(v) : std::numeric_limits<float>::infinity(); }

// ---------------------------------------------------------------------------------------------------
// Application + run loop
// ---------------------------------------------------------------------------------------------------
namespace {
struct AppState {
    std::string title;
    hopwinui_ready_cb on_ready{nullptr};
    void* ready_ud{nullptr};
    mux::Window window{nullptr};
    muxc::Canvas root{nullptr};
    winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher{nullptr};
    hopwinui_void_cb relayout{nullptr};
    void* relayout_ud{nullptr};
    std::vector<mux::Window> secondary;
} g;

struct App : mux::ApplicationT<App, mux::Markup::IXamlMetadataProvider> {
    void OnLaunched(mux::LaunchActivatedEventArgs const&) {
        Resources().MergedDictionaries().Append(muxc::XamlControlsResources());
        mux::Window window;
        window.Title(winrt::to_hstring(std::string_view(g.title)));
        muxc::Canvas root;
        window.Content(root);
        g.window = window;
        g.root = root;
        g.dispatcher = window.DispatcherQueue();
        root.SizeChanged([](auto&&, auto&&) { if (g.relayout) g.relayout(g.relayout_ud); });
        if (g.on_ready) g.on_ready(mk(root), g.ready_ud);
        window.Activate();
    }
    mux::Markup::IXamlType GetXamlType(winrt::Windows::UI::Xaml::Interop::TypeName const& t) { return _p.GetXamlType(t); }
    mux::Markup::IXamlType GetXamlType(hstring const& n) { return _p.GetXamlType(n); }
    com_array<mux::Markup::XmlnsDefinition> GetXmlnsDefinitions() { return _p.GetXmlnsDefinitions(); }
private:
    mux::XamlTypeInfo::XamlControlsXamlMetaDataProvider _p;
};
} // namespace

void hopwinui_run(const char* title, hopwinui_ready_cb on_ready, void* ud) {
    g.title = title ? title : "";
    g.on_ready = on_ready;
    g.ready_ud = ud;
    PACKAGE_VERSION minVersion{};
    if (FAILED(MddBootstrapInitialize2(0x00010006u, L"", minVersion, MddBootstrapInitializeOptions_OnNoMatch_ShowUI))) return;
    init_apartment(apartment_type::single_threaded);
    mux::Application::Start([](auto&&) { winrt::make<App>(); });
    MddBootstrapShutdown();
}

void hopwinui_open_window(const char* title, hopwinui_ready_cb on_ready, void* ud) {
    mux::Window window;
    if (title) window.Title(winrt::to_hstring(std::string_view(title)));
    muxc::Canvas root;
    window.Content(root);
    if (on_ready) on_ready(mk(root), ud);
    window.Activate();
    g.secondary.push_back(window);
}

void hopwinui_set_relayout(hopwinui_void_cb handler, void* ud) { g.relayout = handler; g.relayout_ud = ud; }

void hopwinui_content_size(double* w, double* h) {
    if (g.root && g.root.ActualWidth() > 0 && g.root.ActualHeight() > 0) {
        *w = g.root.ActualWidth(); *h = g.root.ActualHeight(); return;
    }
    *w = 820; *h = 760;
}

void hopwinui_schedule_on_main(hopwinui_void_cb work, void* ud) {
    if (!g.dispatcher) { if (work) work(ud); return; }
    g.dispatcher.TryEnqueue([work, ud] { if (work) work(ud); });
}

void hopwinui_set_color_scheme(int32_t scheme) {
    if (!g.root) return;
    g.root.RequestedTheme(scheme == 1 ? mux::ElementTheme::Light : scheme == 2 ? mux::ElementTheme::Dark : mux::ElementTheme::Default);
}

void hopwinui_release(void* h) { delete reinterpret_cast<Handle*>(h); }

// ---------------------------------------------------------------------------------------------------
// Element creation
// ---------------------------------------------------------------------------------------------------
void* hopwinui_canvas_new(void) { return mk(muxc::Canvas()); }
void* hopwinui_stackpanel_new(int32_t vertical) {
    muxc::StackPanel p; p.Orientation(vertical ? muxc::Orientation::Vertical : muxc::Orientation::Horizontal); return mk(p);
}
void* hopwinui_border_new(void) { return mk(muxc::Border()); }
void* hopwinui_scrollviewer_new(void) {
    muxc::ScrollViewer s;
    s.HorizontalScrollMode(muxc::ScrollMode::Disabled);
    s.VerticalScrollMode(muxc::ScrollMode::Auto);
    s.HorizontalScrollBarVisibility(muxc::ScrollBarVisibility::Disabled);
    s.VerticalScrollBarVisibility(muxc::ScrollBarVisibility::Auto);
    return mk(s);
}
void* hopwinui_textblock_new(void) { muxc::TextBlock t; t.TextWrapping(mux::TextWrapping::Wrap); return mk(t); }
void* hopwinui_button_new(void) { return mk(muxc::Button()); }
void* hopwinui_textbox_new(void) { return mk(muxc::TextBox()); }
void* hopwinui_passwordbox_new(void) { return mk(muxc::PasswordBox()); }
void* hopwinui_toggleswitch_new(void) { return mk(muxc::ToggleSwitch()); }
void* hopwinui_checkbox_new(void) { return mk(muxc::CheckBox()); }                       // .toggleStyle(.checkbox)
void* hopwinui_togglebutton_new(void) { return mk(muxc::Primitives::ToggleButton()); }   // .toggleStyle(.button)
void* hopwinui_slider_new(void) {
    muxc::Slider s; s.Minimum(0); s.Maximum(1); s.StepFrequency(0.0001); return mk(s);
}
void* hopwinui_listview_new(void) { return mk(muxc::ListView()); }
void* hopwinui_combobox_new(void) { return mk(muxc::ComboBox()); }
void* hopwinui_progressbar_new(void) { muxc::ProgressBar b; b.Minimum(0); b.Maximum(1); return mk(b); }
void* hopwinui_image_new(void) { return mk(muxc::Image()); }
void* hopwinui_path_new(void) { muxs::Path p; p.Stretch(muxm::Stretch::None); return mk(p); }
void* hopwinui_calendardatepicker_new(void) { return mk(muxc::CalendarDatePicker()); }
void* hopwinui_timepicker_new(void) { return mk(muxc::TimePicker()); }
void* hopwinui_colorpicker_new(void) { return mk(muxc::ColorPicker()); }

// ---------------------------------------------------------------------------------------------------
// Framework-element common
// ---------------------------------------------------------------------------------------------------
void hopwinui_set_frame(void* h, double x, double y, double w, double height) {
    auto e = elem(h);
    muxc::Canvas::SetLeft(e, x); muxc::Canvas::SetTop(e, y);
    e.Width(w); e.Height(height);
}
void hopwinui_set_size(void* h, double w, double height) { auto e = elem(h); e.Width(w); e.Height(height); }
void hopwinui_canvas_setpos(void* h, double x, double y) { auto e = elem(h); muxc::Canvas::SetLeft(e, x); muxc::Canvas::SetTop(e, y); }
void hopwinui_measure(void* h, double aw, double ah, double* ow, double* oh) {
    auto e = elem(h);
    e.Measure(wf::Size{favail(aw), favail(ah)});
    auto d = e.DesiredSize();
    *ow = d.Width; *oh = d.Height;
}
void hopwinui_actual_size(void* h, double* ow, double* oh) { auto e = elem(h); *ow = e.ActualWidth(); *oh = e.ActualHeight(); }
void hopwinui_set_visible(void* h, int32_t v) { elem(h).Visibility(v ? mux::Visibility::Visible : mux::Visibility::Collapsed); }
// `.opacity` — UIElement.Opacity composites the element and its subtree.
void hopwinui_set_opacity(void* h, double o) { elem(h).Opacity(o); }
// `.disabled` — Control.IsEnabled. A Panel container (HopUI lays everything out in Canvases) isn't a
// Control, so setting IsEnabled on it does nothing and doesn't cascade. To match SwiftUI's subtree
// semantics — and AppKit/GTK/Qt, where disabling a container dims the controls within — recurse the visual
// tree and toggle IsEnabled on every descendant Control (WinUI then cascades it through that control's own
// template). Stops at each Control, mirroring AppKit's `applyEnabled`.
static void apply_enabled(Element const& e, bool enabled) {
    if (auto c = e.try_as<muxc::Control>()) { c.IsEnabled(enabled); return; }
    if (auto p = e.try_as<muxc::Panel>()) {
        for (auto const& child : p.Children())
            if (auto fe = child.try_as<Element>()) apply_enabled(fe, enabled);
    }
}
void hopwinui_set_enabled(void* h, int32_t enabled) { apply_enabled(elem(h), enabled != 0); }
void hopwinui_set_min_width(void* h, double w) { elem(h).MinWidth(w); }
void hopwinui_set_background(void* h, double r, double g2, double b, double a) {
    auto e = elem(h);
    if (auto p = e.try_as<muxc::Panel>()) { p.Background(brush(r, g2, b, a)); return; }
    if (auto bd = e.try_as<muxc::Border>()) { bd.Background(brush(r, g2, b, a)); return; }
    if (auto c = e.try_as<muxc::Control>()) { c.Background(brush(r, g2, b, a)); }
}
void hopwinui_set_automation_name(void* h, const char* u) { mux::Automation::AutomationProperties::SetName(elem(h), hs(u)); }
void hopwinui_set_automation_id(void* h, const char* u) { mux::Automation::AutomationProperties::SetAutomationId(elem(h), hs(u)); }

// ---------------------------------------------------------------------------------------------------
// Containers
// ---------------------------------------------------------------------------------------------------
void hopwinui_panel_insert(void* panel, void* child, int32_t index) {
    auto p = as<muxc::Panel>(panel); if (!p) return;
    auto kids = p.Children();
    uint32_t i = static_cast<uint32_t>(std::clamp<int32_t>(index, 0, static_cast<int32_t>(kids.Size())));
    kids.InsertAt(i, elem(child));
}
void hopwinui_panel_remove(void* panel, void* child) {
    auto p = as<muxc::Panel>(panel); if (!p) return;
    auto kids = p.Children(); uint32_t idx;
    if (kids.IndexOf(elem(child), idx)) kids.RemoveAt(idx);
}
void hopwinui_panel_move(void* panel, void* child, int32_t index) {
    auto p = as<muxc::Panel>(panel); if (!p) return;
    auto kids = p.Children(); uint32_t idx;
    if (kids.IndexOf(elem(child), idx)) {
        kids.RemoveAt(idx);
        kids.InsertAt(static_cast<uint32_t>(std::clamp<int32_t>(index, 0, static_cast<int32_t>(kids.Size()))), elem(child));
    }
}
void hopwinui_scrollviewer_set_content(void* sv, void* child) { if (auto s = as<muxc::ScrollViewer>(sv)) s.Content(elem(child)); }
void hopwinui_scrollviewer_connect(void* sv, hopwinui_size_cb cb, void* ud) {
    auto s = as<muxc::ScrollViewer>(sv); if (!s) return;
    s.ViewChanged([cb, ud](wf::IInspectable const& sender, auto&&) {
        auto sc = sender.as<muxc::ScrollViewer>();
        if (cb) cb(sc.HorizontalOffset(), sc.VerticalOffset(), ud);
    });
}
void hopwinui_scrollviewer_offset(void* sv, double* x, double* y) {
    if (auto s = as<muxc::ScrollViewer>(sv)) { *x = s.HorizontalOffset(); *y = s.VerticalOffset(); } else { *x = 0; *y = 0; }
}

// ---------------------------------------------------------------------------------------------------
// TextBlock
// ---------------------------------------------------------------------------------------------------
void hopwinui_textblock_set_text(void* h, const char* u) { if (auto t = as<muxc::TextBlock>(h)) t.Text(hs(u)); }
void hopwinui_textblock_set_foreground(void* h, double r, double g2, double b, double a) {
    if (auto t = as<muxc::TextBlock>(h)) t.Foreground(brush(r, g2, b, a));
}
void hopwinui_textblock_set_font(void* h, double size, const char* family, int32_t weight, int32_t is_italic) {
    auto t = as<muxc::TextBlock>(h); if (!t) return;
    if (size > 0) t.FontSize(size);
    if (family && *family) t.FontFamily(muxm::FontFamily(hs(family)));
    if (weight > 0) { winrt::Windows::UI::Text::FontWeight w; w.Weight = static_cast<uint16_t>(weight); t.FontWeight(w); }
    t.FontStyle(is_italic ? winrt::Windows::UI::Text::FontStyle::Italic : winrt::Windows::UI::Text::FontStyle::Normal);
}

// `.multilineTextAlignment` — 0=left, 1=center, 2=right.
void hopwinui_textblock_set_alignment(void* h, int32_t alignment) {
    auto t = as<muxc::TextBlock>(h); if (!t) return;
    t.TextAlignment(alignment == 1 ? mux::TextAlignment::Center
                  : alignment == 2 ? mux::TextAlignment::Right
                                   : mux::TextAlignment::Left);
}

// ---------------------------------------------------------------------------------------------------
// Button
// ---------------------------------------------------------------------------------------------------
void hopwinui_button_set_text(void* h, const char* u) { if (auto b = as<muxc::Button>(h)) b.Content(box_value(hs(u))); }
void hopwinui_button_connect(void* h, hopwinui_void_cb cb, void* ud) {
    auto b = as<muxc::Button>(h); if (!b) return;
    b.Click([cb, ud](auto&&, auto&&) { if (cb) cb(ud); });
}

void hopwinui_tap_connect(void* h, int32_t count, hopwinui_void_cb cb, void* ud) {
    auto e = elem(h);
    if (count >= 2) {
        e.DoubleTapped([cb, ud](auto&&, auto&&) { if (cb) cb(ud); });
    } else {
        e.Tapped([cb, ud](auto&&, auto&&) { if (cb) cb(ud); });
    }
}

void hopwinui_longpress_connect(void* h, hopwinui_void_cb cb, void* ud) {
    elem(h).Holding([cb, ud](winrt::Windows::Foundation::IInspectable const&,
                             mux::Input::HoldingRoutedEventArgs const& args) {
        if (cb && args.HoldingState() == winrt::Microsoft::UI::Input::HoldingState::Started) cb(ud);
    });
}

void hopwinui_hover_connect(void* h, hopwinui_hover_cb cb, void* ud) {
    auto e = elem(h);
    e.PointerEntered([cb, ud](auto&&, auto&&) { if (cb) cb(ud, 1); });
    e.PointerExited([cb, ud](auto&&, auto&&) { if (cb) cb(ud, 0); });
}

void hopwinui_drag_connect(void* h, hopwinui_drag_cb cb, void* ud) {
    auto e = elem(h);
    // Shared press state captured by all three pointer lambdas (start point + whether a drag is active).
    auto state = std::make_shared<std::array<double, 3>>();  // [0]=pressed, [1]=startX, [2]=startY
    e.PointerPressed([cb, ud, state, e](winrt::Windows::Foundation::IInspectable const&,
                                        mux::Input::PointerRoutedEventArgs const& args) {
        auto p = args.GetCurrentPoint(e).Position();
        (*state)[0] = 1; (*state)[1] = p.X; (*state)[2] = p.Y;
        e.CapturePointer(args.Pointer());
    });
    e.PointerMoved([cb, ud, state, e](winrt::Windows::Foundation::IInspectable const&,
                                      mux::Input::PointerRoutedEventArgs const& args) {
        if ((*state)[0] == 0) return;
        auto p = args.GetCurrentPoint(e).Position();
        if (cb) cb(ud, (*state)[1], (*state)[2], p.X, p.Y, 0);
    });
    e.PointerReleased([cb, ud, state, e](winrt::Windows::Foundation::IInspectable const&,
                                         mux::Input::PointerRoutedEventArgs const& args) {
        if ((*state)[0] == 0) return;
        auto p = args.GetCurrentPoint(e).Position();
        (*state)[0] = 0;
        if (cb) cb(ud, (*state)[1], (*state)[2], p.X, p.Y, 1);
        e.ReleasePointerCapture(args.Pointer());
    });
}

void hopwinui_manip_connect(void* h, hopwinui_manip_cb cb, void* ud) {
    auto e = elem(h);
    // ManipulationMode must be set before the events fire. Scale + Rotate cover magnify/rotate; TranslateX/Y
    // let the manipulation engine recognize the two-finger gesture even when the fingers also pan slightly.
    e.ManipulationMode(mux::Input::ManipulationModes::Scale | mux::Input::ManipulationModes::Rotate |
                       mux::Input::ManipulationModes::TranslateX | mux::Input::ManipulationModes::TranslateY);
    // ManipulationDelta.Cumulative is already cumulative-since-start (Scale 1.0 = none; Rotation in degrees).
    e.ManipulationDelta([cb, ud](winrt::Windows::Foundation::IInspectable const&,
                                 mux::Input::ManipulationDeltaRoutedEventArgs const& args) {
        auto c = args.Cumulative();
        if (cb) cb(ud, c.Scale, c.Rotation, 0);
    });
    e.ManipulationCompleted([cb, ud](winrt::Windows::Foundation::IInspectable const&,
                                     mux::Input::ManipulationCompletedRoutedEventArgs const& args) {
        auto c = args.Cumulative();
        if (cb) cb(ud, c.Scale, c.Rotation, 1);
    });
}

// ---------------------------------------------------------------------------------------------------
// TextBox / PasswordBox
// ---------------------------------------------------------------------------------------------------
char* hopwinui_textbox_text(void* h) { auto t = as<muxc::TextBox>(h); return dup(t ? t.Text() : hstring{}); }
void hopwinui_textbox_set_text(void* h, const char* u) { if (auto t = as<muxc::TextBox>(h)) t.Text(hs(u)); }
void hopwinui_textbox_set_placeholder(void* h, const char* u) { if (auto t = as<muxc::TextBox>(h)) t.PlaceholderText(hs(u)); }
void hopwinui_textbox_connect(void* h, hopwinui_string_cb cb, void* ud) {
    auto t = as<muxc::TextBox>(h); if (!t) return;
    t.TextChanged([cb, ud](wf::IInspectable const& s, auto&&) {
        auto tb = s.as<muxc::TextBox>(); if (cb) { auto p = dup(tb.Text()); cb(p, ud); std::free(p); }
    });
}

// `.onSubmit` — fire when the user presses Enter in the TextBox/PasswordBox (KeyDown is a UIElement event).
void hopwinui_textbox_connect_submit(void* h, hopwinui_void_cb cb, void* ud) {
    elem(h).KeyDown([cb, ud](wf::IInspectable const&, mux::Input::KeyRoutedEventArgs const& e) {
        if (e.Key() == winrt::Windows::System::VirtualKey::Enter && cb) cb(ud);
    });
}
char* hopwinui_passwordbox_text(void* h) { auto t = as<muxc::PasswordBox>(h); return dup(t ? t.Password() : hstring{}); }
void hopwinui_passwordbox_set_text(void* h, const char* u) { if (auto t = as<muxc::PasswordBox>(h)) t.Password(hs(u)); }
void hopwinui_passwordbox_set_placeholder(void* h, const char* u) { if (auto t = as<muxc::PasswordBox>(h)) t.PlaceholderText(hs(u)); }
void hopwinui_passwordbox_connect(void* h, hopwinui_string_cb cb, void* ud) {
    auto t = as<muxc::PasswordBox>(h); if (!t) return;
    t.PasswordChanged([cb, ud](wf::IInspectable const& s, auto&&) {
        auto pb = s.as<muxc::PasswordBox>(); if (cb) { auto p = dup(pb.Password()); cb(p, ud); std::free(p); }
    });
}

// ---------------------------------------------------------------------------------------------------
// ToggleSwitch / Slider / ProgressBar
// ---------------------------------------------------------------------------------------------------
// State accessors span all three toggle controls: ToggleSwitch (IsOn) and the ToggleButton family —
// CheckBox derives from Primitives::ToggleButton, so one `as<ToggleButton>` covers both (IsChecked is a
// nullable bool; treat null as off).
int32_t hopwinui_toggle_is_on(void* h) {
    if (auto t = as<muxc::ToggleSwitch>(h)) return t.IsOn() ? 1 : 0;
    if (auto b = as<muxc::Primitives::ToggleButton>(h)) { auto v = b.IsChecked(); return (v && v.Value()) ? 1 : 0; }
    return 0;
}
void hopwinui_toggle_set_on(void* h, int32_t on) {
    if (auto t = as<muxc::ToggleSwitch>(h)) { t.IsOn(on != 0); return; }
    if (auto b = as<muxc::Primitives::ToggleButton>(h)) b.IsChecked(on != 0);
}
void hopwinui_toggle_connect(void* h, hopwinui_bool_cb cb, void* ud) {
    if (auto t = as<muxc::ToggleSwitch>(h)) {
        t.Toggled([cb, ud](wf::IInspectable const& s, auto&&) { if (cb) cb(s.as<muxc::ToggleSwitch>().IsOn() ? 1 : 0, ud); });
        return;
    }
    if (auto b = as<muxc::Primitives::ToggleButton>(h)) {
        auto handler = [cb, ud](wf::IInspectable const& s, auto&&) {
            auto v = s.as<muxc::Primitives::ToggleButton>().IsChecked();
            if (cb) cb((v && v.Value()) ? 1 : 0, ud);
        };
        b.Checked(handler);    // Checked / Unchecked both report the new state via IsChecked
        b.Unchecked(handler);
    }
}
// Checkbox/button carry their own label as ContentControl.Content; ToggleSwitch is not a ContentControl
// (its label sits beside it via an HStack), so this is a no-op for the switch style.
void hopwinui_toggle_set_label(void* h, const char* u) { if (auto c = as<muxc::ContentControl>(h)) c.Content(box_value(hs(u))); }
void hopwinui_slider_set_range(void* h, double mn, double mx) { if (auto s = as<muxc::Slider>(h)) { s.Minimum(mn); s.Maximum(mx); } }
double hopwinui_slider_value(void* h) { auto s = as<muxc::Slider>(h); return s ? s.Value() : 0; }
void hopwinui_slider_set_value(void* h, double v) { if (auto s = as<muxc::Slider>(h)) s.Value(v); }
void hopwinui_slider_connect(void* h, hopwinui_double_cb cb, void* ud) {
    auto s = as<muxc::Slider>(h); if (!s) return;
    s.ValueChanged([cb, ud](wf::IInspectable const& sn, auto&&) { if (cb) cb(sn.as<muxc::Slider>().Value(), ud); });
}
void hopwinui_progress_set_value(void* h, double f) { if (auto b = as<muxc::ProgressBar>(h)) { b.IsIndeterminate(false); b.Value(f); } }
void hopwinui_progress_set_indeterminate(void* h) { if (auto b = as<muxc::ProgressBar>(h)) b.IsIndeterminate(true); }

// ---------------------------------------------------------------------------------------------------
// ListView / ComboBox
// ---------------------------------------------------------------------------------------------------
static void fill_items(muxc::ItemsControl const& ic, const char* const* items, int32_t count) {
    ic.Items().Clear();
    for (int32_t i = 0; i < count; ++i) ic.Items().Append(box_value(hs(items[i])));
}
void hopwinui_listview_set_items(void* h, const char* const* items, int32_t count) { if (auto l = as<muxc::ListView>(h)) fill_items(l, items, count); }
int32_t hopwinui_listview_selected(void* h) { auto l = as<muxc::ListView>(h); return l ? l.SelectedIndex() : -1; }
void hopwinui_listview_set_selected(void* h, int32_t i) { if (auto l = as<muxc::ListView>(h)) l.SelectedIndex(i); }
void hopwinui_listview_connect(void* h, hopwinui_int_cb cb, void* ud) {
    auto l = as<muxc::ListView>(h); if (!l) return;
    l.SelectionChanged([cb, ud](wf::IInspectable const& s, auto&&) { if (cb) cb(s.as<muxc::ListView>().SelectedIndex(), ud); });
}
void hopwinui_combobox_set_items(void* h, const char* const* items, int32_t count) { if (auto c = as<muxc::ComboBox>(h)) fill_items(c, items, count); }
int32_t hopwinui_combobox_selected(void* h) { auto c = as<muxc::ComboBox>(h); return c ? c.SelectedIndex() : -1; }
void hopwinui_combobox_set_selected(void* h, int32_t i) { if (auto c = as<muxc::ComboBox>(h)) c.SelectedIndex(i); }
void hopwinui_combobox_connect(void* h, hopwinui_int_cb cb, void* ud) {
    auto c = as<muxc::ComboBox>(h); if (!c) return;
    c.SelectionChanged([cb, ud](wf::IInspectable const& s, auto&&) { if (cb) cb(s.as<muxc::ComboBox>().SelectedIndex(), ud); });
}

// --- Button group (Picker .segmented = ToggleButtons in a row; .radioGroup = RadioButtons in a column) ---
// A StackPanel of mutually-exclusive buttons; each button's Checked handler reports its index (the toolkit
// suppresses the callback during programmatic changes). RadioButtons share a GroupName for exclusivity;
// segmented ToggleButtons uncheck their siblings manually and re-check to keep exactly one selected.
void* hopwinui_buttongroup_new(int32_t horizontal) {
    muxc::StackPanel p;
    p.Orientation(horizontal ? muxc::Orientation::Horizontal : muxc::Orientation::Vertical);
    p.Spacing(horizontal ? 0 : 4);
    return mk(p);
}

void hopwinui_buttongroup_set_items(void* h, const char* const* items, int32_t count, int32_t selected,
                                    int32_t toggle, hopwinui_int_cb cb, void* ud) {
    auto panel = as<muxc::StackPanel>(h); if (!panel) return;
    panel.Children().Clear();
    static int groupCounter = 0;
    hstring groupName{ L"hopgrp" + std::to_wstring(groupCounter++) };  // unique per group → no cross-interference
    for (int32_t i = 0; i < count; i++) {
        hstring label = hs(items && items[i] ? items[i] : "");
        if (toggle) {
            muxc::Primitives::ToggleButton btn;
            btn.Content(box_value(label));
            btn.IsChecked(i == selected);
            btn.Checked([cb, ud, i, panel](wf::IInspectable const& sender, auto&&) {
                auto self = sender.as<muxc::Primitives::ToggleButton>();
                for (auto const& child : panel.Children()) {
                    auto other = child.try_as<muxc::Primitives::ToggleButton>();
                    if (other && other != self) other.IsChecked(false);
                }
                if (cb) cb(i, ud);
            });
            btn.Unchecked([panel](wf::IInspectable const& sender, auto&&) {
                bool any = false;
                for (auto const& child : panel.Children()) {
                    if (auto o = child.try_as<muxc::Primitives::ToggleButton>()) {
                        auto v = o.IsChecked();
                        if (v && v.Value()) { any = true; break; }
                    }
                }
                if (!any) sender.as<muxc::Primitives::ToggleButton>().IsChecked(true);  // keep one selected
            });
            panel.Children().Append(btn);
        } else {
            muxc::RadioButton btn;
            btn.Content(box_value(label));
            btn.GroupName(groupName);
            btn.IsChecked(i == selected);
            btn.Checked([cb, ud, i](wf::IInspectable const&, auto&&) { if (cb) cb(i, ud); });
            panel.Children().Append(btn);
        }
    }
}

void hopwinui_buttongroup_set_selected(void* h, int32_t index) {
    auto panel = as<muxc::StackPanel>(h); if (!panel) return;
    int32_t i = 0;
    for (auto const& child : panel.Children()) {
        if (auto tb = child.try_as<muxc::Primitives::ToggleButton>()) tb.IsChecked(i == index);
        i++;
    }
}

// ---------------------------------------------------------------------------------------------------
// Image
// ---------------------------------------------------------------------------------------------------
void hopwinui_image_set_file(void* h, const char* path) {
    auto im = as<muxc::Image>(h); if (!im || !path) return;
    try {
        wf::Uri uri(hs(path));
        im.Source(muxm::Imaging::BitmapImage(uri));
    } catch (...) {}
}
void hopwinui_image_set_stretch(void* h, int32_t mode) {
    auto im = as<muxc::Image>(h); if (!im) return;
    im.Stretch(mode == 1 ? muxm::Stretch::Uniform : mode == 2 ? muxm::Stretch::UniformToFill : mode == 3 ? muxm::Stretch::Fill : muxm::Stretch::None);
}

// ---------------------------------------------------------------------------------------------------
// Shapes.Path — geometry builder (single in-flight build; the toolkit calls begin..commit synchronously)
// ---------------------------------------------------------------------------------------------------
namespace {
struct PathBuild {
    muxm::GeometryGroup group{nullptr};
    muxm::PathFigure figure{nullptr};
    std::vector<muxm::PathFigure> figures;
} g_pb;

static wf::Point pt(double x, double y) { return wf::Point{static_cast<float>(x), static_cast<float>(y)}; }
static void ensure_figure() { if (!g_pb.figure) { muxm::PathFigure f; f.StartPoint(pt(0, 0)); g_pb.figure = f; } }
static void flush_figure(bool closed) { if (g_pb.figure) { g_pb.figure.IsClosed(closed); g_pb.figures.push_back(g_pb.figure); g_pb.figure = nullptr; } }
}

void hopwinui_path_begin(void* h) {
    (void)h;
    g_pb.group = muxm::GeometryGroup();
    g_pb.group.FillRule(muxm::FillRule::Nonzero);
    g_pb.figure = nullptr;
    g_pb.figures.clear();
}
void hopwinui_path_move(void* h, double x, double y) { (void)h; flush_figure(false); muxm::PathFigure f; f.StartPoint(pt(x, y)); g_pb.figure = f; }
void hopwinui_path_line(void* h, double x, double y) { (void)h; ensure_figure(); muxm::LineSegment s; s.Point(pt(x, y)); g_pb.figure.Segments().Append(s); }
void hopwinui_path_quad(void* h, double cx, double cy, double x, double y) {
    (void)h; ensure_figure(); muxm::QuadraticBezierSegment s; s.Point1(pt(cx, cy)); s.Point2(pt(x, y)); g_pb.figure.Segments().Append(s);
}
void hopwinui_path_cubic(void* h, double c1x, double c1y, double c2x, double c2y, double x, double y) {
    (void)h; ensure_figure(); muxm::BezierSegment s; s.Point1(pt(c1x, c1y)); s.Point2(pt(c2x, c2y)); s.Point3(pt(x, y)); g_pb.figure.Segments().Append(s);
}
void hopwinui_path_arc(void* h, double x, double y, double radius, int32_t clockwise, int32_t large_arc) {
    (void)h; ensure_figure();
    muxm::ArcSegment s; s.Point(pt(x, y)); s.Size(wf::Size{static_cast<float>(radius), static_cast<float>(radius)});
    s.SweepDirection(clockwise ? muxm::SweepDirection::Clockwise : muxm::SweepDirection::Counterclockwise);
    s.IsLargeArc(large_arc != 0);
    g_pb.figure.Segments().Append(s);
}
void hopwinui_path_close_figure(void* h, int32_t closed) { (void)h; flush_figure(closed != 0); }
void hopwinui_path_add_rect(void* h, double x, double y, double w, double height) {
    (void)h; muxm::RectangleGeometry r; r.Rect(wf::Rect{static_cast<float>(x), static_cast<float>(y), static_cast<float>(w), static_cast<float>(height)}); g_pb.group.Children().Append(r);
}
void hopwinui_path_add_round_rect(void* h, double x, double y, double w, double height, double rx, double ry) {
    (void)h;
    // RectangleGeometry has no corner radii in WinUI; trace the rounded rect as a closed figure of
    // straight edges + quarter-circle arcs (clockwise).
    float fx = static_cast<float>(x), fy = static_cast<float>(y), fw = static_cast<float>(w), fh = static_cast<float>(height);
    float frx = static_cast<float>(std::min(rx, w / 2)), fry = static_cast<float>(std::min(ry, height / 2));
    muxm::PathFigure f; f.StartPoint(wf::Point{fx + frx, fy}); f.IsClosed(true);
    auto line = [&](float px, float py) { muxm::LineSegment s; s.Point(wf::Point{px, py}); f.Segments().Append(s); };
    auto arc = [&](float px, float py) { muxm::ArcSegment s; s.Point(wf::Point{px, py}); s.Size(wf::Size{frx, fry}); s.SweepDirection(muxm::SweepDirection::Clockwise); f.Segments().Append(s); };
    line(fx + fw - frx, fy);          arc(fx + fw, fy + fry);
    line(fx + fw, fy + fh - fry);     arc(fx + fw - frx, fy + fh);
    line(fx + frx, fy + fh);          arc(fx, fy + fh - fry);
    line(fx, fy + fry);               arc(fx + frx, fy);
    muxm::PathGeometry pg; pg.Figures().Append(f); g_pb.group.Children().Append(pg);
}
void hopwinui_path_add_ellipse(void* h, double cx, double cy, double rx, double ry) {
    (void)h; muxm::EllipseGeometry e; e.Center(pt(cx, cy)); e.RadiusX(rx); e.RadiusY(ry); g_pb.group.Children().Append(e);
}
void hopwinui_path_commit(void* h) {
    flush_figure(false);
    if (!g_pb.figures.empty()) {
        muxm::PathGeometry pg;
        for (auto& f : g_pb.figures) pg.Figures().Append(f);
        g_pb.group.Children().Append(pg);
    }
    if (auto p = as<muxs::Path>(h)) p.Data(g_pb.group);
    g_pb.figure = nullptr; g_pb.figures.clear();
}
void hopwinui_path_set_fill(void* h, double r, double g2, double b, double a) { if (auto p = as<muxs::Path>(h)) p.Fill(brush(r, g2, b, a)); }

// The two brushes return DIFFERENT collection types for GradientStops(): LinearGradientBrush (via
// GradientBrush) gives the concrete GradientStopCollection, while RadialGradientBrush gives
// IObservableVector<GradientStop>. Both support .Append(GradientStop), so accept either via a template.
template <typename Coll>
static void hopwinui_add_stops(Coll const& coll, const double* stops, int n) {
    for (int i = 0; i < n; i++) {
        const double* s = stops + i * 5;
        muxm::GradientStop gs;
        gs.Offset(s[0]);
        gs.Color(col(s[1], s[2], s[3], s[4]));
        coll.Append(gs);
    }
}

void hopwinui_path_set_fill_linear(void* h, double x0, double y0, double x1, double y1, const double* stops, int n) {
    auto p = as<muxs::Path>(h); if (!p) return;
    muxm::LinearGradientBrush b;
    b.MappingMode(muxm::BrushMappingMode::Absolute);
    b.StartPoint(winrt::Windows::Foundation::Point{ (float)x0, (float)y0 });
    b.EndPoint(winrt::Windows::Foundation::Point{ (float)x1, (float)y1 });
    hopwinui_add_stops(b.GradientStops(), stops, n);
    p.Fill(b);
}

void hopwinui_path_set_fill_radial(void* h, double cx, double cy, double rx, double ry, const double* stops, int n) {
    auto p = as<muxs::Path>(h); if (!p) return;
    muxm::RadialGradientBrush b;
    b.MappingMode(muxm::BrushMappingMode::Absolute);
    b.Center(winrt::Windows::Foundation::Point{ (float)cx, (float)cy });
    b.GradientOrigin(winrt::Windows::Foundation::Point{ (float)cx, (float)cy });
    b.RadiusX(rx);
    b.RadiusY(ry);
    hopwinui_add_stops(b.GradientStops(), stops, n);
    p.Fill(b);
}

void hopwinui_path_set_stroke(void* h, double r, double g2, double b, double a, double thickness) {
    if (auto p = as<muxs::Path>(h)) { p.Stroke(brush(r, g2, b, a)); p.StrokeThickness(thickness); }
}
void hopwinui_path_clear_fill(void* h) { if (auto p = as<muxs::Path>(h)) p.Fill(nullptr); }
void hopwinui_path_clear_stroke(void* h) { if (auto p = as<muxs::Path>(h)) p.Stroke(nullptr); }
void hopwinui_path_set_transform(void* h, double cx, double cy, double tx, double ty, double rot, double sx, double sy) {
    auto p = as<muxs::Path>(h); if (!p) return;
    muxm::CompositeTransform t;
    t.CenterX(cx); t.CenterY(cy); t.TranslateX(tx); t.TranslateY(ty); t.Rotation(rot); t.ScaleX(sx); t.ScaleY(sy);
    p.RenderTransform(t);
}

// ---------------------------------------------------------------------------------------------------
// CalendarDatePicker / TimePicker  (date as seconds-since-1970 UTC; time as seconds-of-day)
// ---------------------------------------------------------------------------------------------------
void hopwinui_datepicker_set_date(void* h, double secs) {
    if (auto p = as<muxc::CalendarDatePicker>(h)) p.Date(winrt::clock::from_time_t(static_cast<time_t>(std::llround(secs))));
}
double hopwinui_datepicker_date(void* h) {
    auto p = as<muxc::CalendarDatePicker>(h); if (!p) return std::nan("");
    auto d = p.Date(); if (!d) return std::nan("");
    return static_cast<double>(winrt::clock::to_time_t(d.Value()));
}
void hopwinui_datepicker_connect(void* h, hopwinui_double_cb cb, void* ud) {
    auto p = as<muxc::CalendarDatePicker>(h); if (!p) return;
    p.DateChanged([cb, ud](muxc::CalendarDatePicker const& s, auto&&) {
        if (cb && s.Date()) cb(static_cast<double>(winrt::clock::to_time_t(s.Date().Value())), ud);
    });
}
void hopwinui_timepicker_set_time(void* h, double secs) {
    if (auto p = as<muxc::TimePicker>(h)) p.Time(std::chrono::duration_cast<wf::TimeSpan>(std::chrono::seconds(static_cast<int64_t>(std::llround(secs)))));
}
double hopwinui_timepicker_time(void* h) {
    auto p = as<muxc::TimePicker>(h); if (!p) return 0;
    return static_cast<double>(std::chrono::duration_cast<std::chrono::seconds>(p.Time()).count());
}
void hopwinui_timepicker_connect(void* h, hopwinui_double_cb cb, void* ud) {
    auto p = as<muxc::TimePicker>(h); if (!p) return;
    p.TimeChanged([cb, ud](wf::IInspectable const& s, auto&&) {
        if (cb) cb(static_cast<double>(std::chrono::duration_cast<std::chrono::seconds>(s.as<muxc::TimePicker>().Time()).count()), ud);
    });
}

// ---------------------------------------------------------------------------------------------------
// ColorPicker
// ---------------------------------------------------------------------------------------------------
void hopwinui_colorpicker_set_color(void* h, double r, double g2, double b, double a) { if (auto c = as<muxc::ColorPicker>(h)) c.Color(col(r, g2, b, a)); }
void hopwinui_colorpicker_set_alpha_enabled(void* h, int32_t e) { if (auto c = as<muxc::ColorPicker>(h)) c.IsAlphaEnabled(e != 0); }
void hopwinui_colorpicker_connect(void* h, hopwinui_color_cb cb, void* ud) {
    auto c = as<muxc::ColorPicker>(h); if (!c) return;
    c.ColorChanged([cb, ud](muxc::ColorPicker const& s, auto&&) {
        auto k = s.Color();
        if (cb) cb(k.R / 255.0, k.G / 255.0, k.B / 255.0, k.A / 255.0, ud);
    });
}

// ---------------------------------------------------------------------------------------------------
// Menu (Button + MenuFlyout). Container handles wrap an IVector<MenuFlyoutItemBase> (heap; small, leaked
// on rebuild — menus are reconfigured rarely).
// ---------------------------------------------------------------------------------------------------
using MenuItems = wf::Collections::IVector<muxc::MenuFlyoutItemBase>;
namespace { struct MenuHandle { MenuItems v; }; }
static MenuItems menu_items(void* c) { return reinterpret_cast<MenuHandle*>(c)->v; }

void* hopwinui_menubutton_new(void) { muxc::Button b; b.Flyout(muxc::MenuFlyout()); return mk(b); }
void hopwinui_menubutton_set_label(void* h, const char* u) { if (auto b = as<muxc::Button>(h)) b.Content(box_value(hs(u))); }
void* hopwinui_menubutton_flyout(void* h) {
    auto b = as<muxc::Button>(h); if (!b) return nullptr;
    auto mf = b.Flyout().try_as<muxc::MenuFlyout>(); if (!mf) { mf = muxc::MenuFlyout(); b.Flyout(mf); }
    return new MenuHandle{mf.Items()};
}
void hopwinui_menu_clear(void* c) { if (c) menu_items(c).Clear(); }
void hopwinui_menu_add_item(void* c, const char* title, hopwinui_void_cb cb, void* ud) {
    if (!c) return;
    muxc::MenuFlyoutItem item; item.Text(hs(title));
    item.Click([cb, ud](auto&&, auto&&) { if (cb) cb(ud); });
    menu_items(c).Append(item);
}
void hopwinui_menu_add_separator(void* c) { if (c) menu_items(c).Append(muxc::MenuFlyoutSeparator()); }
void* hopwinui_menu_add_submenu(void* c, const char* title) {
    if (!c) return nullptr;
    muxc::MenuFlyoutSubItem sub; sub.Text(hs(title));
    menu_items(c).Append(sub);
    return new MenuHandle{sub.Items()};
}

// ---------------------------------------------------------------------------------------------------
// File pickers. Unpackaged WinUI apps must seed the picker with the window's HWND (IInitializeWithWindow).
// The async result fires on a background thread, so marshal back to the UI thread before calling the C
// callback (which touches Swift main-actor state).
// ---------------------------------------------------------------------------------------------------
namespace wsp = winrt::Windows::Storage::Pickers;

static HWND main_hwnd() {
    if (!g.window) return nullptr;
    HWND hwnd{};
    if (auto native = g.window.try_as<::IWindowNative>()) native->get_WindowHandle(&hwnd);
    return hwnd;
}
template <typename TPicker> static void init_with_window(TPicker const& picker) {
    if (auto init = picker.try_as<::IInitializeWithWindow>()) init->Initialize(main_hwnd());
}

void hopwinui_open_file_picker(const char* const* exts, int32_t extCount, int32_t multiple, hopwinui_files_cb cb, void* ud) {
    wsp::FileOpenPicker picker;
    init_with_window(picker);
    picker.SuggestedStartLocation(wsp::PickerLocationId::DocumentsLibrary);
    if (extCount <= 0) picker.FileTypeFilter().Append(L"*");
    else for (int32_t i = 0; i < extCount; ++i) picker.FileTypeFilter().Append(L"." + hs(exts[i]));
    auto dispatcher = g.dispatcher;
    auto deliver = [cb, ud, dispatcher](std::vector<std::string> paths) {
        auto call = [cb, ud, paths] {
            std::vector<const char*> c; for (auto& p : paths) c.push_back(p.c_str());
            cb(c.empty() ? nullptr : c.data(), static_cast<int32_t>(c.size()), ud);
        };
        if (dispatcher) dispatcher.TryEnqueue(call); else call();
    };
    if (multiple) {
        picker.PickMultipleFilesAsync().Completed([deliver](auto const& op, auto&&) {
            std::vector<std::string> paths;
            if (auto files = op.GetResults()) for (auto const& f : files) paths.push_back(winrt::to_string(f.Path()));
            deliver(paths);
        });
    } else {
        picker.PickSingleFileAsync().Completed([deliver](auto const& op, auto&&) {
            std::vector<std::string> paths;
            if (auto file = op.GetResults()) paths.push_back(winrt::to_string(file.Path()));
            deliver(paths);
        });
    }
}

void hopwinui_save_file_picker(const char* defaultName, const char* ext, const char* typeName, hopwinui_file_cb cb, void* ud) {
    wsp::FileSavePicker picker;
    init_with_window(picker);
    picker.SuggestedFileName(hs(defaultName));
    auto choices = winrt::single_threaded_vector<winrt::hstring>();
    choices.Append((ext && *ext) ? (L"." + hs(ext)) : winrt::hstring(L"*"));
    auto label = hs(typeName); picker.FileTypeChoices().Insert(label.empty() ? winrt::hstring(L"File") : label, choices);
    auto dispatcher = g.dispatcher;
    picker.PickSaveFileAsync().Completed([cb, ud, dispatcher](auto const& op, auto&&) {
        auto file = op.GetResults();
        std::string path = file ? winrt::to_string(file.Path()) : std::string();
        bool has = static_cast<bool>(file);
        auto call = [cb, ud, path, has] { cb(has ? path.c_str() : nullptr, ud); };
        if (dispatcher) dispatcher.TryEnqueue(call); else call();
    });
}

// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// C++/WinRT implementation of CComboBoxWinUI.h — a Microsoft.UI.Xaml.Controls.ComboBox. Mirrors `hop`'s own
// CWinUI shim: a handle is a heap-held FrameworkElement (one strong ref) whose layout matches CWinUI's, so
// HopUI's WinUI backend wraps and lays it out like any other widget. Build/link flags come from the root
// package's `.winui/` staging (scripts/setup-winui.ps1), referenced via ../../../.winui in Package.swift.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <unknwn.h>
#undef GetCurrentTime

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
// ComboBox.SelectionChanged is inherited from Selector in the Controls.Primitives namespace; its
// auto-returning definition lives in that umbrella header (Controls.h only brings the declaration), so it
// must be included or the call fails with "deduced return type cannot be used before it is defined".
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>

#include <memory>
#include <string>
#include <string_view>

#include "CComboBoxWinUI.h"

using namespace winrt;
namespace mux = winrt::Microsoft::UI::Xaml;
namespace muxc = winrt::Microsoft::UI::Xaml::Controls;
namespace wf = winrt::Windows::Foundation;

// Same handle layout as CWinUI's (a single FrameworkElement), so the pointer is interchangeable across the
// shim boundary when HopUI's WinUI backend reinterprets it.
namespace { struct Handle { mux::FrameworkElement e; }; }
static mux::FrameworkElement elem(void *h) { return reinterpret_cast<Handle *>(h)->e; }
static void *mk(mux::FrameworkElement const &e) { return new Handle{e}; }
template <typename T> static T as(void *h) { return elem(h).try_as<T>(); }
static hstring hs(const char *u) { return u ? winrt::to_hstring(std::string_view(u)) : hstring{}; }

extern "C" {

void *hopwinui_combo_new(void) {
    muxc::ComboBox c;
    c.IsEditable(true);   // editable: freeform typing AND menu selection
    // hop measures self-hosted leaves with INFINITE height. An editable ComboBox measured with infinite
    // height over-reports its DesiredSize as itemCount*rowHeight, because its dropdown list (Popup ->
    // ScrollViewer -> ItemsPresenter) shares the template's visual tree and ComboBox.MaxDropDownHeight
    // defaults to infinity, so nothing bounds the vertical extent during measure. hop then stamps that
    // inflated DesiredSize.Height as an explicit Height in hopwinui_set_frame, rendering a ~190px-tall box
    // with no editable field. The XAML render height is min(Height, MaxHeight), so capping MaxHeight to the
    // standard compact closed-box height (ComboBoxMinHeight = 32 in the default WinUI 3 style) both bounds
    // the DesiredSize from the infinite measure AND clamps the explicit Height from set_frame, pinning the
    // closed combo to a single line. The dropdown is hosted in a SEPARATE top-level Popup governed only by
    // MaxDropDownHeight, so this does NOT clip the open menu. VerticalAlignment::Top keeps the single-line
    // box top-aligned within whatever (possibly taller) frame hop allocates.
    c.MaxHeight(32.0);
    c.VerticalAlignment(mux::VerticalAlignment::Top);
    return mk(c);
}

void hopwinui_combo_clear(void *h) { if (auto c = as<muxc::ComboBox>(h)) c.Items().Clear(); }

void hopwinui_combo_add_item(void *h, const char *text) {
    if (auto c = as<muxc::ComboBox>(h)) c.Items().Append(box_value(hs(text)));
}

void hopwinui_combo_set_text(void *h, const char *text) {
    auto c = as<muxc::ComboBox>(h);
    if (!c) return;
    auto value = hs(text);
    c.Text(value);
    // An editable WinUI 3 ComboBox does not reliably display Text set before its template part
    // (PART_EditableTextBox) is realized — it shows blank/placeholder until first interaction
    // (microsoft-ui-xaml #7103). set_text runs at creation time, before the control is loaded, so the
    // initial value would be dropped. Re-apply the value once the control fires Loaded (the template is
    // applied by then). The token is stored in a heap box that the lambda deletes when it detaches itself,
    // so the handler fires exactly once and leaks nothing.
    if (!c.IsLoaded()) {
        auto token = std::make_shared<winrt::event_token>();
        *token = c.Loaded([value, token](wf::IInspectable const &sender, mux::RoutedEventArgs const &) {
            if (auto combo = sender.try_as<muxc::ComboBox>()) {
                combo.Text(value);
                combo.Loaded(*token);   // detach: fire once
            }
        });
    }
}

void hopwinui_combo_set_placeholder(void *h, const char *text) {
    if (auto c = as<muxc::ComboBox>(h)) c.PlaceholderText(hs(text));
}

void hopwinui_combo_connect(void *h, hop_combo_text_fn fn, void *context) {
    auto c = as<muxc::ComboBox>(h);
    if (!c) return;
    // Freeform text committed in the edit field.
    c.TextSubmitted([fn, context](muxc::ComboBox const &, muxc::ComboBoxTextSubmittedEventArgs const &args) {
        if (fn) fn(winrt::to_string(args.Text()).c_str(), context);
    });
    // A menu item was picked — its title becomes the Text.
    c.SelectionChanged([fn, context](wf::IInspectable const &s, auto &&) {
        if (fn) fn(winrt::to_string(s.as<muxc::ComboBox>().Text()).c_str(), context);
    });
}

}  // extern "C"

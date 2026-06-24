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

// Show `value` in the (editable) combo. WinUI 3 does NOT reliably render ComboBox.Text on its own —
// the editable TextBox part stays blank/placeholder until first interaction (open bug microsoft-ui-xaml
// #7103). The selection system IS reliable, so if the value matches a menu item we select it (which renders
// its text); only a freeform value that's in no menu item falls back to Text.
static void combo_apply_value(muxc::ComboBox const &combo, hstring const &value) {
    int32_t match = -1;
    auto items = combo.Items();
    for (uint32_t i = 0; i < items.Size(); ++i) {
        if (winrt::unbox_value_or<hstring>(items.GetAt(i), hstring{}) == value) { match = static_cast<int32_t>(i); break; }
    }
    if (match >= 0) {
        combo.SelectedIndex(match);   // a menu item: selection renders its text reliably
    } else {
        combo.SelectedIndex(-1);      // freeform value (not in the menu)
        combo.Text(value);
    }
}

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
    combo_apply_value(c, value);
    // set_text runs at creation time, before the control is in the visual tree and its template part
    // (PART_EditableTextBox) is realized; WinUI 3 drops the displayed value until then (#7103). Re-apply it
    // once the control fires Loaded (template is up by then) and force a layout pass so the editable text
    // syncs immediately rather than only on first interaction. The token lives in a heap box the lambda
    // deletes when it detaches itself, so the handler fires exactly once and leaks nothing.
    if (!c.IsLoaded()) {
        auto token = std::make_shared<winrt::event_token>();
        *token = c.Loaded([value, token](wf::IInspectable const &sender, mux::RoutedEventArgs const &) {
            if (auto combo = sender.try_as<muxc::ComboBox>()) {
                combo_apply_value(combo, value);
                combo.UpdateLayout();
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

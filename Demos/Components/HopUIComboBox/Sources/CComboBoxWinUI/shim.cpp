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
    return mk(c);
}

void hopwinui_combo_clear(void *h) { if (auto c = as<muxc::ComboBox>(h)) c.Items().Clear(); }

void hopwinui_combo_add_item(void *h, const char *text) {
    if (auto c = as<muxc::ComboBox>(h)) c.Items().Append(box_value(hs(text)));
}

void hopwinui_combo_set_text(void *h, const char *text) {
    if (auto c = as<muxc::ComboBox>(h)) c.Text(hs(text));
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

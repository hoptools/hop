// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(AppKit)
import HopUI
import HopAppKit
import HopUIComboBoxAppKit

HopUIComboBoxAppKit.register()   // register the third-party ComboBox component for this toolkit
runApp(HopDemoApp(), toolkit: AppKitToolkit())
#else
print("The AppKit demo requires macOS.")
#endif

// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import HopUI
import HopWinUI

// Same entry point as every other toolkit demo: pick the toolkit and hand it to `runApp`. The WinUI
// toolkit's `run` owns the Windows App SDK message loop (via the CWinUI shim), so it blocks here — exactly
// like GTK4's GtkApplication or Qt's QApplication::exec.
runApp(HopDemoApp(), toolkit: WinUIToolkit())

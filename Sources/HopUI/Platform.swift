// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

// HopUI sits on the HopPlatform foundation layer (logging, the run-loop concurrency seam, …). The
// concurrency seam (`HopConcurrency` / `HopLoopExecutor` / `hopTask`) moved DOWN from HopUI into
// HopPlatform so non-UI code can use it; re-export HopPlatform here so existing `import HopUI` clients —
// the toolkit backends (`installGTK4MainExecutor` et al.) and app code — keep resolving those symbols
// (and now `Logger`) without adding an import. Removing this line would require every such client to
// `import HopPlatform` explicitly.
@_exported import HopPlatform

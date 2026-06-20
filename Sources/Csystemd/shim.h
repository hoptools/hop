// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// Surfaces libsystemd's journal API (sd_journal_sendv + iovec) to HopPlatform's JournaldLogHandler. Like
// CGTK4, this is a thin systemLibrary: include/link flags come from `pkg-config libsystemd` (declared in
// Package.swift); the iovec batch is built on the Swift side, so no helper code is needed here.

#ifndef HOP_CSYSTEMD_SHIM_H
#define HOP_CSYSTEMD_SHIM_H

#include <systemd/sd-journal.h>

#endif

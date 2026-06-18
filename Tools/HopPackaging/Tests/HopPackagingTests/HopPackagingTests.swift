// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import HopPackaging

@Suite struct PlatformTripleTests {
    @Test func parsesValidSectionKeys() {
        #expect(PlatformTriple("macos-aarch64-appkit") == PlatformTriple(os: .macos, arch: .aarch64, toolkit: .appkit))
        #expect(PlatformTriple("linux-x86_64-gtk4")?.key == "linux-x86_64-gtk4")
        #expect(PlatformTriple("windows-x86_64-winui")?.toolkit == .winui)
        #expect(PlatformTriple("linux-aarch64-qt")?.os == .linux)
    }

    @Test func rejectsNonTripleKeys() {
        #expect(PlatformTriple("metadata") == nil)        // the reserved common block, not a platform
        #expect(PlatformTriple("macos-appkit") == nil)    // missing arch
        #expect(PlatformTriple("bsd-aarch64-appkit") == nil)  // unknown OS
        #expect(PlatformTriple("macos-aarch64-cocoa") == nil) // unknown toolkit
    }

    @Test func mapsToolkitToHopBuildValue() {
        #expect(Toolkit.gtk4.hopToolkitEnvironmentValue == "gtk")  // section token differs from build value
        #expect(Toolkit.appkit.hopToolkitEnvironmentValue == "appkit")
        #expect(Toolkit.qt.hopToolkitEnvironmentValue == "qt")
    }
}

@Suite struct ConfigTests {
    let yaml = """
        metadata:
          identifier: net.hoptools.demo
          version: "2.0"
          launchargs: ["--x"]
        macos-aarch64-appkit:
          title: Demo AppKit
          executable: demo-appkit
        linux-x86_64-gtk4:
          title: Demo GTK
          executable: demo-gtk
          version: "3.0"
        """

    @Test func parsesCommonAndPlatformSections() throws {
        let config = try HoppackConfig.parse(yaml: yaml)
        #expect(config.common.identifier == "net.hoptools.demo")
        #expect(config.platforms.count == 2)
        #expect(config.platforms[PlatformTriple("macos-aarch64-appkit")!]?.title == "Demo AppKit")
        #expect(config.declaredTriples.map(\.key) == ["linux-x86_64-gtk4", "macos-aarch64-appkit"])
    }

    @Test func resolvesWithCommonFallbackAndPlatformOverride() throws {
        let config = try HoppackConfig.parse(yaml: yaml)
        let mac = try config.resolved(for: PlatformTriple("macos-aarch64-appkit")!, packageName: "pkg")
        #expect(mac.title == "Demo AppKit")
        #expect(mac.identifier == "net.hoptools.demo")   // inherited from common
        #expect(mac.version == "2.0")                // inherited from common
        #expect(mac.executable == "demo-appkit")
        #expect(mac.launchArgs == ["--x"])           // inherited from common

        let gtk = try config.resolved(for: PlatformTriple("linux-x86_64-gtk4")!, packageName: "pkg")
        #expect(gtk.version == "3.0")                // platform section overrides common
        #expect(gtk.identifier == "net.hoptools.demo")   // still inherits common
    }

    @Test func appliesDefaultsForOmittedKeys() throws {
        let config = try HoppackConfig.parse(yaml: "macos-aarch64-appkit:\n  executable: x\n")
        let m = try config.resolved(for: PlatformTriple("macos-aarch64-appkit")!, packageName: "MyPkg")
        #expect(m.title == "MyPkg")                  // defaults to the package name
        #expect(m.version == "1.0.0")
        #expect(m.build == "1")
        #expect(m.identifier == "com.example.MyPkg")
        #expect(m.launchArgs.isEmpty)
    }

    @Test func resolvesAppslugFromCommonAndDefaultsFromTitle() throws {
        let withSlug = try HoppackConfig.parse(yaml: """
            metadata:
              appslug: myslug
            macos-aarch64-appkit:
              executable: x
            """).resolved(for: PlatformTriple("macos-aarch64-appkit")!, packageName: "pkg")
        #expect(withSlug.appslug == "myslug")   // inherited from the common metadata block

        // Absent appslug defaults to the title, lowercased and reduced to alphanumerics.
        let defaulted = try HoppackConfig.parse(yaml: "macos-aarch64-appkit:\n  executable: x\n")
            .resolved(for: PlatformTriple("macos-aarch64-appkit")!, packageName: "My App")
        #expect(defaulted.appslug == "myapp")
    }

    @Test func missingExecutableThrows() throws {
        let config = try HoppackConfig.parse(yaml: "metadata:\n  version: '1'\n")
        #expect(throws: PackagingError.self) {
            _ = try config.resolved(for: PlatformTriple("macos-aarch64-appkit")!, packageName: "pkg")
        }
    }

    @Test func ignoresUnrecognizedTopLevelKeys() throws {
        let config = try HoppackConfig.parse(yaml: "schemaVersion: 1\nmetadata:\n  executable: x\n")
        #expect(config.platforms.isEmpty)
        #expect(config.common.executable == "x")
    }
}

@Suite struct TargetResolutionTests {
    @Test func explicitTripleSpecifier() throws {
        let target = try HopPackager.resolveTarget(specifier: "linux-aarch64-qt", config: HoppackConfig())
        #expect(target.key == "linux-aarch64-qt")
    }

    @Test func toolkitOnlySpecifierUsesHostOSAndArch() throws {
        let target = try HopPackager.resolveTarget(specifier: "appkit", config: HoppackConfig())
        #expect(target.toolkit == .appkit)
        #expect(target.os == PlatformTriple.hostOS)
        #expect(target.arch == PlatformTriple.hostArch)
    }

    @Test func unknownSpecifierThrows() {
        #expect(throws: PackagingError.self) {
            _ = try HopPackager.resolveTarget(specifier: "nonsense", config: HoppackConfig())
        }
    }

    @Test func ambiguousAutoSelectionThrows() throws {
        // Two sections for the same host OS+arch (whatever the host is) → must require --target.
        let host = "\(PlatformTriple.hostOS.rawValue)-\(PlatformTriple.hostArch.rawValue)"
        let config = try HoppackConfig.parse(yaml: """
            \(host)-appkit:
              executable: a
            \(host)-qt:
              executable: b
            """)
        // Only meaningful when both keys parsed as valid triples for this host.
        if config.platforms.count == 2 {
            #expect(throws: PackagingError.self) {
                _ = try HopPackager.resolveTarget(specifier: nil, config: config)
            }
        }
    }
}

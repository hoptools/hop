// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

#if canImport(Foundation)
import Foundation  // Bundle / URL / Data for resolving image sources
#endif

// SwiftUI's `Image` displayed through a native image widget (NSImageView / GtkPicture / QLabel+QPixmap).
// The same call sites compile against HopUI and Apple's SwiftUI. `ImageSpec` is the toolkit-agnostic
// payload (like `ShapeSpec`); the toolkit resolves `source` to a native image and applies the rest.

/// Everything a toolkit needs to display an image: where the pixels come from, how it scales, and how
/// it's tinted/labeled. Reapplied on every reconcile (not `Equatable`), like ``ShapeSpec``.
public struct ImageSpec {
    /// Where an image's pixels come from. `named`/`file`/`data` render identically on every toolkit;
    /// `system` (SF Symbol) is native on AppKit and best-effort (icon theme + fallback) on GTK/Qt.
    public enum Source {
        case named(String, Bundle?)
        case system(String)
        case file(URL)
        case data(Data)
    }
    public let source: Source
    /// `.resizable()` — when false the image shows at its natural pixel size; when true it scales to
    /// the laid-out frame (stretching unless a `contentMode` is set).
    public var resizable: Bool
    /// How a resizable image fills a frame of a different aspect ratio. `nil` ⇒ stretch both axes
    /// (plain `.resizable()`); `.fit`/`.fill` come from `.scaledToFit()`/`.scaledToFill()`/`.aspectRatio`.
    public var contentMode: ContentMode?
    /// Explicit aspect ratio from `.aspectRatio(_:contentMode:)` (nil ⇒ use the image's own).
    public var aspectRatio: CGFloat?
    /// `.renderingMode(.template)` — recolor the (alpha) image with `tint` instead of drawing its colors.
    public var isTemplate: Bool
    /// Tint for template images / symbols; defaults to the ambient `.foregroundStyle`.
    public var tint: Color?
    /// Accessibility label (`Image(_:label:)`); `nil` falls back to the symbol/resource name.
    public var label: String?
    /// `Image(decorative:)` — hidden from assistive technologies.
    public var isDecorative: Bool

    public init(source: Source, resizable: Bool = false, contentMode: ContentMode? = nil,
                aspectRatio: CGFloat? = nil, isTemplate: Bool = false, tint: Color? = nil,
                label: String? = nil, isDecorative: Bool = false) {
        self.source = source
        self.resizable = resizable
        self.contentMode = contentMode
        self.aspectRatio = aspectRatio
        self.isTemplate = isTemplate
        self.tint = tint
        self.label = label
        self.isDecorative = isDecorative
    }

    /// Resolve a `named`/`file` source to a file URL (trying common image extensions for `named`). The
    /// toolkits use this so bundle lookup isn't duplicated; `system`/`data` return nil here.
    public func resolvedURL() -> URL? {
        switch source {
        case .file(let url):
            return url
        case .named(let name, let bundle):
            let bundle = bundle ?? .main
            if let direct = bundle.url(forResource: name, withExtension: nil),
               FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            for ext in ["png", "jpg", "jpeg", "pdf", "tiff", "gif"] {
                if let url = bundle.url(forResource: name, withExtension: ext) { return url }
            }
            return nil
        case .system, .data:
            return nil
        }
    }

    /// The raw bytes for a `data`/`file`/`named` source (decoding is left to the toolkit); `system` ⇒ nil.
    public func resolvedData() -> Data? {
        switch source {
        case .data(let data): return data
        case .file, .named: return resolvedURL().flatMap { try? Data(contentsOf: $0) }
        case .system: return nil
        }
    }
}

/// A view that displays an image. Mirrors SwiftUI's `Image`. The `named`/`file`/`data` sources render
/// identically on all four toolkits; `systemName` is a native SF Symbol on AppKit/SwiftUI and a
/// best-effort icon-theme lookup on GTK/Qt. Modifiers (`.resizable()`, `.aspectRatio(_:contentMode:)`,
/// `.scaledToFit()`, `.scaledToFill()`, `.renderingMode(_:)`) return an `Image`, so the same chains
/// compile against HopUI and Apple's SwiftUI.
public struct Image: View, PrimitiveView {
    /// `.renderingMode(_:)` value. Mirrors SwiftUI's `Image.TemplateRenderingMode`.
    public enum TemplateRenderingMode: Equatable, Sendable { case template, original }

    var spec: ImageSpec
    init(spec: ImageSpec) { self.spec = spec }

    public init(_ name: String, bundle: Bundle? = nil) {
        self.init(spec: ImageSpec(source: .named(name, bundle), label: name))
    }

    public init(_ name: String, bundle: Bundle? = nil, label: Text) {
        self.init(spec: ImageSpec(source: .named(name, bundle), label: label.content))
    }

    public init(decorative name: String, bundle: Bundle? = nil) {
        self.init(spec: ImageSpec(source: .named(name, bundle), isDecorative: true))
    }

    public init(systemName: String) {
        // SF Symbols are template images by default (recolored by the foreground), like SwiftUI.
        self.init(spec: ImageSpec(source: .system(systemName), isTemplate: true, label: systemName))
    }

    /// HopUI convenience (not in SwiftUI): load an image directly from a file URL.
    public init(contentsOf url: URL) {
        self.init(spec: ImageSpec(source: .file(url), label: url.deletingPathExtension().lastPathComponent))
    }

    /// HopUI convenience (not in SwiftUI): build an image from raw encoded bytes.
    public init(data: Data) {
        self.init(spec: ImageSpec(source: .data(data)))
    }

    public typealias Body = Never
    public var body: Never { fatalError("Image has no body") }

    func makeNode(_ context: RenderContext) -> RenderNode {
        var resolved = spec
        // A template image / symbol tints with the inherited foreground color (default accent), like SwiftUI.
        if resolved.isTemplate, resolved.tint == nil {
            resolved.tint = currentEnvironment().foregroundColor
        }
        // Migrated to the open component system: the node carries an `ImageComponent`; each backend's
        // registered image renderer realizes it. (`kind: .image` is kept only as a harmless layout fallback
        // during the strangler migration; the component path drives realize/update/measure.)
        return RenderNode(id: context.id, component: ImageComponent(spec: resolved))
    }

    // MARK: - Image modifiers (return Image, so chains stay Image-typed like SwiftUI)

    /// Lets the image scale to fit the space offered by its frame. Mirrors `Image.resizable()`.
    public func resizable() -> Image {
        var copy = self; copy.spec.resizable = true; return copy
    }

    /// Constrains the image to an aspect ratio, scaled per `contentMode`. Mirrors `.aspectRatio(_:contentMode:)`.
    public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> Image {
        var copy = self
        copy.spec.aspectRatio = ratio
        copy.spec.contentMode = contentMode
        return copy
    }

    /// Scales the image to fit its frame, preserving aspect ratio. Mirrors `.scaledToFit()`.
    public func scaledToFit() -> Image { aspectRatio(contentMode: .fit) }

    /// Scales the image to fill its frame, preserving aspect ratio (may clip). Mirrors `.scaledToFill()`.
    public func scaledToFill() -> Image { aspectRatio(contentMode: .fill) }

    /// Selects template (tinted) vs. original (full-color) rendering. Mirrors `.renderingMode(_:)`.
    public func renderingMode(_ mode: TemplateRenderingMode) -> Image {
        var copy = self; copy.spec.isTemplate = (mode == .template); return copy
    }
}

/// The open ``WidgetComponent`` for ``Image``. All images share one native widget type, so the key is
/// simply "image"; resizable-ness is payload (handled by the renderer's measure), not a different widget.
/// Public so each backend's image renderer (a separate module) can read its `spec`.
public struct ImageComponent: WidgetComponent {
    public let spec: ImageSpec
    public init(spec: ImageSpec) { self.spec = spec }
    public var widgetKey: WidgetKey { WidgetKey("image") }
    public var role: WidgetRole { .leaf }
}

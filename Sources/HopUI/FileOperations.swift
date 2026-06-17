// Copyright 2026
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A content type for file dialogs, mirroring the subset of `UniformTypeIdentifiers.UTType` the file
/// importer/exporter need. Apple's UTType is Apple-only, so HopUI defines its own with matching static
/// members (`.plainText`, `.json`, …) and a `UTType(filenameExtension:)` init, so the same call sites
/// compile against HopUI and (in the native build) Apple's. Each toolkit maps it to its own filter
/// representation: a real `UniformTypeIdentifiers.UTType` (AppKit) or a filename-extension glob (GTK/Qt).
public struct UTType: Sendable, Equatable {
    /// The uniform type identifier (e.g. `public.json`); empty for an extension-only type.
    public let identifier: String
    /// The filename extensions this type matches (e.g. `["jpg", "jpeg"]`); empty means "any file".
    public let filenameExtensions: [String]
    /// A human-readable name for the dialog's filter row.
    public let displayName: String

    public init(identifier: String, filenameExtensions: [String], displayName: String) {
        self.identifier = identifier
        self.filenameExtensions = filenameExtensions
        self.displayName = displayName
    }

    /// Mirrors `UTType(filenameExtension:)`.
    public init(filenameExtension ext: String) {
        self.identifier = ""
        self.filenameExtensions = [ext]
        self.displayName = ext.uppercased()
    }

    /// The preferred (first) filename extension, if any.
    public var preferredFilenameExtension: String? { filenameExtensions.first }

    public static let plainText = UTType(identifier: "public.plain-text", filenameExtensions: ["txt"], displayName: "Plain Text")
    public static let utf8PlainText = UTType(identifier: "public.utf8-plain-text", filenameExtensions: ["txt"], displayName: "Text")
    public static let json = UTType(identifier: "public.json", filenameExtensions: ["json"], displayName: "JSON")
    public static let commaSeparatedText = UTType(identifier: "public.comma-separated-values-text", filenameExtensions: ["csv"], displayName: "CSV")
    public static let pdf = UTType(identifier: "com.adobe.pdf", filenameExtensions: ["pdf"], displayName: "PDF")
    public static let png = UTType(identifier: "public.png", filenameExtensions: ["png"], displayName: "PNG Image")
    public static let jpeg = UTType(identifier: "public.jpeg", filenameExtensions: ["jpg", "jpeg"], displayName: "JPEG Image")
    public static let image = UTType(identifier: "public.image", filenameExtensions: ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic"], displayName: "Image")
    public static let data = UTType(identifier: "public.data", filenameExtensions: [], displayName: "All Files")
}

/// Backend-agnostic payload for a `.fileImporter` presentation, attached to the modified view's node and
/// reapplied each reconcile (not `Equatable`). The toolkit shows a native open panel when `isPresented`
/// transitions true, then calls `onCompletion` and `setPresented(false)`.
public struct FileImporterSpec {
    public let isPresented: Bool
    public let allowedContentTypes: [UTType]
    public let allowsMultipleSelection: Bool
    public let onCompletion: @MainActor (Result<[URL], Error>) -> Void
    public let setPresented: @MainActor (Bool) -> Void
}

/// Backend-agnostic payload for a `.fileExporter` presentation. The toolkit shows a native save panel,
/// writes `data` to the chosen URL, then calls `onCompletion` and `setPresented(false)`.
public struct FileExporterSpec {
    public let isPresented: Bool
    public let data: Data
    public let contentType: UTType
    public let defaultFilename: String
    public let onCompletion: @MainActor (Result<URL, Error>) -> Void
    public let setPresented: @MainActor (Bool) -> Void
}

/// Wraps a view, attaching a ``FileImporterSpec`` to its node (like the layout modifiers attach a
/// `LayoutModifier`). Not a widget itself.
struct _FileImporterModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let spec: FileImporterSpec
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.fileImporter = spec
        return node
    }
}

struct _FileExporterModifier<Content: View>: View, PrimitiveView {
    let content: Content
    let spec: FileExporterSpec
    typealias Body = Never
    var body: Never { fatalError() }
    func makeNode(_ context: RenderContext) -> RenderNode {
        var node = evaluate(content, context.appending(0)).first ?? RenderNode(id: context.id, component: ContainerComponent.vstack())
        node.fileExporter = spec
        return node
    }
}

extension View {
    /// Presents a system file-open panel when `isPresented` becomes true, restricted to
    /// `allowedContentTypes`. Mirrors SwiftUI's `.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)`.
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                             allowsMultipleSelection: Bool = false,
                             onCompletion: @escaping @MainActor (Result<[URL], Error>) -> Void) -> some View {
        _FileImporterModifier(content: self, spec: FileImporterSpec(
            isPresented: isPresented.wrappedValue, allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: allowsMultipleSelection, onCompletion: onCompletion,
            setPresented: { isPresented.wrappedValue = $0 }))
    }

    /// Presents a system file-save panel when `isPresented` becomes true, writing `document` to the chosen
    /// URL. A pragmatic, data-based take on SwiftUI's `.fileExporter` (which uses a `FileDocument`).
    public func fileExporter(isPresented: Binding<Bool>, document: Data, contentType: UTType,
                             defaultFilename: String,
                             onCompletion: @escaping @MainActor (Result<URL, Error>) -> Void) -> some View {
        _FileExporterModifier(content: self, spec: FileExporterSpec(
            isPresented: isPresented.wrappedValue, data: document, contentType: contentType,
            defaultFilename: defaultFilename, onCompletion: onCompletion,
            setPresented: { isPresented.wrappedValue = $0 }))
    }
}

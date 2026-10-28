import SwiftUI
import AppKit

/// A shelf card: a colored header naming the type and source app, a preview, and a footer.
struct ClipCardView: View {
    @ObservedObject var item: ClipItem
    var selected: Bool
    var justCopied: Bool
    /// Set only for items that fit in a QR code (URLs and short text).
    var onShowQR: (() -> Void)?
    /// Non-nil while this card's title is being edited.
    var renameText: Binding<String>?
    var onRenameCommit: () -> Void = {}
    private let hovering = State(initialValue: false) // @State is a macro; CLT lacks its plugin

    static let size = CGSize(width: 216, height: 244)
    private static let corner: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 10 : 5, y: 3)
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering.wrappedValue ? 0.25 : 0.08),
                              lineWidth: selected ? 3 : 1)
        }
        .overlay {
            if justCopied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.callout.bold())
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering.wrappedValue, let onShowQR {
                Button(action: onShowQR) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .help("Show QR code")
                .padding(8)
                .padding(.bottom, 26)
                .transition(.opacity)
            }
        }
        .scaleEffect(selected ? 1.0 : (hovering.wrappedValue ? 0.99 : 0.97))
        .animation(.snappy(duration: 0.2), value: justCopied)
        .animation(.snappy(duration: 0.18), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering.wrappedValue)
        .contentShape(RoundedRectangle(cornerRadius: Self.corner))
        .onHover { hovering.wrappedValue = $0 }
    }

    /// The first category's color, else a color per type.
    private var accent: Color {
        if let category = item.categoryList.first { return category.color }
        switch item.kind {
        case .text: return Color(red: 0.25, green: 0.47, blue: 0.85)
        case .url: return Color(red: 0.05, green: 0.6, blue: 0.62)
        case .image: return Color(red: 0.55, green: 0.36, blue: 0.85)
        case .file: return Color(red: 0.9, green: 0.55, blue: 0.15)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let renameText {
                    TextField(defaultTitle, text: renameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                        .onSubmit(onRenameCommit)
                        .accessibilityIdentifier("cardRenameField")
                } else {
                    Text(item.title ?? defaultTitle).font(.system(size: 13, weight: .bold)).lineLimit(1)
                }
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.system(size: 10.5))
                    .opacity(0.85)
            }
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 11))
            }
            SourceAppIcon(bundleID: item.sourceAppBundleID)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(accent.gradient)
    }

    private var defaultTitle: String { Self.defaultTitle(for: item) }

    static func defaultTitle(for item: ClipItem) -> String {
        switch item.kind {
        case .text: "Text"
        case .url: "Link"
        case .image: "Image"
        case .file: item.filePaths.count > 1 ? "\(item.filePaths.count) Files" : "File"
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text(detail).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(item.categoryList.prefix(4)) { category in
                Circle().fill(category.color).frame(width: 7, height: 7).help(category.name)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.primary.opacity(0.04))
    }

    private var detail: String {
        switch item.kind {
        case .text:
            let count = item.text?.count ?? 0
            return "\(count) character\(count == 1 ? "" : "s")"
        case .url:
            return URL(string: item.urlString ?? "")?.host() ?? ""
        case .image:
            if let image = ThumbnailCache.pixelSize(for: item) {
                return "\(Int(image.width)) × \(Int(image.height))"
            }
            return "Image"
        case .file:
            return item.filePaths.first.map { ($0 as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? ""
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 12.5))
                .lineLimit(9)
        case .url:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(accent)
                Text(item.urlString ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(6)
            }
        case .image:
            if let image = ThumbnailCache.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .file:
            FilePreview(paths: item.filePaths)
        }
    }
}

private struct FilePreview: View {
    let paths: [String]

    var body: some View {
        VStack(spacing: 8) {
            if let first = paths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(paths.count > 1 ? "\((first as NSString).lastPathComponent) + \(paths.count - 1) more"
                                     : (first as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SourceAppIcon: View {
    let bundleID: String?

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.2), radius: 1)
        }
    }
}

/// Decoded, downscaled images keyed by object ID so scrolling doesn't re-decode PNGs.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSManagedObjectID, NSImage>()

    private static let sizes = NSCache<NSManagedObjectID, NSValue>()

    /// Original pixel dimensions, read from the image header without decoding it.
    static func pixelSize(for item: ClipItem) -> CGSize? {
        if let cached = sizes.object(forKey: item.objectID) { return cached.sizeValue }
        guard let data = item.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let size = CGSize(width: width, height: height)
        sizes.setObject(NSValue(size: size), forKey: item.objectID)
        return size
    }

    static func image(for item: ClipItem) -> NSImage? {
        if let cached = cache.object(forKey: item.objectID) { return cached }
        guard let data = item.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 400,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: item.objectID)
        return image
    }
}

/// Writes a stored item back to the general pasteboard, tagged so the monitor skips it.
@MainActor
enum Paster {
    static func write(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .url:
            let string = item.urlString ?? ""
            pasteboard.setString(string, forType: .string)
            pasteboard.setString(string, forType: .URL)
        case .image:
            if let data = item.imageData { pasteboard.setData(data, forType: .png) }
        case .file:
            pasteboard.writeObjects(item.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        }
        pasteboard.setData(Data(), forType: PasteboardMonitor.ownWriteType)
    }
}

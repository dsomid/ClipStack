import SwiftUI
import AppKit

struct ClipCardView: View {
    @ObservedObject var item: ClipItem
    var justCopied: Bool
    /// Set only for items that fit in a QR code (URLs and short text).
    var onShowQR: (() -> Void)?
    private let hovering = State(initialValue: false) // @State is a macro; CLT lacks its plugin

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceAppIcon(bundleID: item.sourceAppBundleID)
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(height: 140)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovering.wrappedValue ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: hovering.wrappedValue ? 2 : 1)
        }
        .overlay {
            if justCopied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.callout.bold())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering.wrappedValue, let onShowQR {
                Button(action: onShowQR) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show QR code")
                .padding(6)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: justCopied)
        .animation(.easeOut(duration: 0.12), value: hovering.wrappedValue)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering.wrappedValue = $0 }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 12))
                .lineLimit(6)
        case .url:
            VStack(alignment: .leading, spacing: 4) {
                Label(URL(string: item.urlString ?? "")?.host() ?? "Link", systemImage: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(item.urlString ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
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
        VStack(spacing: 6) {
            if let first = paths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(paths.count > 1 ? "\((first as NSString).lastPathComponent) + \(paths.count - 1) more"
                                     : (first as NSString).lastPathComponent)
                    .font(.system(size: 11))
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
                .frame(width: 14, height: 14)
        }
    }
}

/// Decoded, downscaled images keyed by object ID so scrolling doesn't re-decode PNGs.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSManagedObjectID, NSImage>()

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

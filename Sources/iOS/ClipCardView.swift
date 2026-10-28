import SwiftUI
import CoreData
import ImageIO
import UniformTypeIdentifiers

/// A card: a colored header naming the item, a preview, and a footer, as on the Mac shelf.
struct ClipCardView: View {
    @ObservedObject var item: ClipItem

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            footer
        }
        .frame(height: 210)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    static func defaultTitle(for item: ClipItem) -> String {
        switch item.kind {
        case .text: "Text"
        case .url: "Link"
        case .image: "Image"
        case .file: item.filePaths.count > 1 ? "\(item.filePaths.count) Files" : "File"
        }
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
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? Self.defaultTitle(for: item))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .opacity(0.85)
            }
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill").font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(accent.gradient)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "").font(.footnote).lineLimit(7)
        case .url:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link.circle.fill").font(.title).foregroundStyle(accent)
                Text(item.urlString ?? "").font(.footnote).foregroundStyle(.tint).lineLimit(4)
            }
        case .image:
            if let image = Thumbnails.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .file:
            VStack(spacing: 6) {
                Image(systemName: "doc.fill").font(.system(size: 40)).foregroundStyle(accent)
                Text(item.filePaths.first.map { ($0 as NSString).lastPathComponent } ?? "")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(detail).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(item.categoryList.prefix(4)) { category in
                Circle().fill(category.color).frame(width: 7, height: 7)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
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
            return Thumbnails.pixelSize(for: item).map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Image"
        case .file:
            return "From your Mac"
        }
    }
}

/// Downscaled images keyed by object ID so scrolling doesn't re-decode PNGs.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSManagedObjectID, UIImage>()

    static func image(for item: ClipItem) -> UIImage? {
        if let cached = cache.object(forKey: item.objectID) { return cached }
        guard let data = item.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 500,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: item.objectID)
        return image
    }

    static func pixelSize(for item: ClipItem) -> CGSize? {
        guard let data = item.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// Turns what PasteButton hands over into a clip for the store.
enum ClipImporter {
    static let types: [UTType] = [.image, .url, .plainText]

    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor (CapturedClip?) -> Void) {
        guard let provider = providers.first else { return }
        let finish: (CapturedClip?) -> Void = { clip in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(clip) } }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                finish(data.map { CapturedClip(kind: .image, imageData: $0, sourceAppBundleID: nil) })
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return finish(nil) }
                finish(url.isFileURL
                    ? CapturedClip(kind: .file, filePaths: [url.path], sourceAppBundleID: nil)
                    : CapturedClip(kind: .url, urlString: url.absoluteString, sourceAppBundleID: nil))
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                let text = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { return finish(nil) }
                if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
                   !text.contains(where: \.isWhitespace) {
                    finish(CapturedClip(kind: .url, urlString: text, sourceAppBundleID: nil))
                } else {
                    finish(CapturedClip(kind: .text, text: text, sourceAppBundleID: nil))
                }
            }
        } else {
            finish(nil)
        }
    }
}

/// Writing to the clipboard never prompts on iOS.
@MainActor
enum ClipboardWriter {
    static func write(_ item: ClipItem) {
        let pasteboard = UIPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.string = item.text ?? ""
        case .url:
            if let url = URL(string: item.urlString ?? "") { pasteboard.url = url }
        case .image:
            if let data = item.imageData {
                pasteboard.setData(data, forPasteboardType: UTType.png.identifier)
            }
        case .file:
            // Mac file paths don't exist on iOS; copy the path as text.
            pasteboard.string = item.filePaths.joined(separator: "\n")
        }
    }
}

struct SettingsSheet: View {
    let store: ClipStore
    let syncEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.historyLimit) private var historyLimit = Prefs.defaultHistoryLimit
    @AppStorage(Prefs.expiryDays) private var expiryDays = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("History") {
                    Picker("Keep", selection: $historyLimit) {
                        ForEach([100, 250, 500, 1000, 2500], id: \.self) { Text("\($0) items").tag($0) }
                    }
                    Picker("Delete unpinned after", selection: $expiryDays) {
                        Text("Never").tag(0)
                        Text("1 day").tag(1)
                        Text("1 week").tag(7)
                        Text("1 month").tag(30)
                    }
                }
                .onChange(of: historyLimit) { store.applyHistoryLimit() }
                .onChange(of: expiryDays) { store.applyHistoryLimit() }

                Section {
                    LabeledContent("iCloud sync", value: syncEnabled ? "On" : "Off")
                } footer: {
                    Text(syncEnabled
                         ? "History syncs with ClipStack on your Mac through iCloud."
                         : "Sync needs a build signed with the iCloud container iCloud.com.omid.clipstack.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } footer: {
                    Text("iOS only lets apps read the clipboard when you tap Paste, so copy something, open ClipStack and tap Paste to save it.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

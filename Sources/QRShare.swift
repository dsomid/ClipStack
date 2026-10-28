import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCode {
    /// Byte-mode capacity at error correction "M" is 2,331 bytes; stay well under for easy scanning.
    static let maxPayloadBytes = 1200

    static func payload(for item: ClipItem) -> String? {
        let candidate: String? = switch item.kind {
        case .url: item.urlString
        case .text: item.text
        case .image, .file: nil
        }
        guard let candidate, !candidate.isEmpty, candidate.utf8.count <= maxPayloadBytes else { return nil }
        return candidate
    }

    private static let context = CIContext()

    /// Renders crisp modules at roughly `pixelSize`, with the standard 4-module quiet zone.
    static func image(for string: String, pixelSize: CGFloat = 1024) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // CoreImage already adds a 1-module margin; pad to 4 on white.
        let margin: CGFloat = 3
        let padded = output
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
            .composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -margin, dy: -margin)
                .offsetBy(dx: margin, dy: margin)))
        let extent = padded.extent
        // Integer scale keeps every module the same width, which scanners prefer.
        let scale = max(1, (pixelSize / extent.width).rounded(.down))
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

struct QRShareView: View {
    let payload: String
    let isURL: Bool
    var onClose: () -> Void

    private let copied = State(initialValue: false) // @State is a macro; CLT lacks its plugin

    var body: some View {
        let cgImage = QRCode.image(for: payload)
        VStack(spacing: 12) {
            if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Couldn't make a QR code", systemImage: "qrcode")
                    .frame(width: 260, height: 260)
            }

            Label(isURL ? (URL(string: payload)?.host() ?? payload) : "Text · \(payload.count) characters",
                  systemImage: isURL ? "link" : "text.alignleft")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text("Scan with your phone's camera")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(copied.wrappedValue ? "Copied" : "Copy Image") {
                    if let cgImage { copy(cgImage) }
                }
                .disabled(cgImage == nil)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }

    private func copy(_ image: CGImage) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        // Don't add our own QR image to the history.
        pasteboard.setData(Data(), forType: PasteboardMonitor.ownWriteType)
        copied.wrappedValue = true
    }
}

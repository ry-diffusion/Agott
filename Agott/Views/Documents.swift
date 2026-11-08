import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file in a message, the way Telegram shows one: a round coloured icon,
/// the name, and a quiet line of details (kind · size · pages).
struct DocumentRow: View {
    var symbol: String
    var title: String
    var detail: String
    /// The badge on the icon: PDF, DOC, PNG…
    var badge: String?
    var outgoing = false
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(outgoing ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Ink.spot))
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(outgoing ? Ink.spot : .white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(outgoing ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text.opacity(0.85))))
                        .offset(x: 4, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(outgoing ? AnyShapeStyle(Ink.onSpot) : AnyShapeStyle(highlighted ? Ink.spot : Ink.text))
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(outgoing ? AnyShapeStyle(Ink.onSpot.opacity(0.75)) : AnyShapeStyle(Ink.muted))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 220, alignment: .leading)
    }
}

extension FileAttachment {
    var detail: String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)]
        if let pages { parts.append(String(localized: "\(pages) pages")) }
        return parts.joined(separator: " · ")
    }

    var badge: String? {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? nil : String(ext.prefix(4))
    }

    func open() {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// What you attached, inside your message: photos as pictures, the rest as files.
struct AttachmentsView: View {
    var attachments: [FileAttachment]
    var outgoing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                Button { attachment.open() } label: {
                    if attachment.kind == .image {
                        AsyncImage(url: attachment.url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(Ink.text.opacity(0.08))
                            }
                        }
                        .frame(maxWidth: 280, maxHeight: 220)
                        .frame(minWidth: 120, minHeight: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        DocumentRow(symbol: attachment.kind.symbol, title: attachment.name, detail: attachment.detail,
                                    badge: attachment.badge, outgoing: outgoing)
                    }
                }
                .buttonStyle(.plain)
                .help(Text("Open \(attachment.name)"))
            }
        }
    }
}

/// Files waiting to be sent, above what you are typing.
struct PendingAttachments: View {
    @Binding var attachments: [FileAttachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        if attachment.kind == .image {
                            AsyncImage(url: attachment.url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Image(systemName: attachment.kind.symbol).foregroundStyle(Ink.spot)
                        }
                        Text(attachment.name).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: 160)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(HoverIconStyle(size: 20))
                        .help(Text("Remove"))
                    }
                    .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
                    .background(Capsule().fill(Ink.text.opacity(0.07)))
                }
            }
        }
        .scrollIndicators(.never)
    }
}

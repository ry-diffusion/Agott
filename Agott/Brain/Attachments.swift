import Foundation
import FoundationModels
import PDFKit
import UniformTypeIdentifiers
import Vision
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A file you sent in the chat: a photo, a PDF, a document (Word, RTF,
/// OpenDocument, a web page), a text or code file.
nonisolated struct FileAttachment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image, pdf, document, text, file

        var symbol: String {
            switch self {
            case .image: "photo"
            case .pdf: "doc.richtext"
            case .document, .text: "doc.text"
            case .file: "doc"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// The copy Agott keeps, under Application Support.
    var fileName: String
    var pages: Int?
    var bytes: Int

    var url: URL { AttachmentStore.folder.appending(path: fileName) }
}

/// Keeps a copy of each attached file and reads what is in it.
nonisolated enum AttachmentStore {
    static let folder: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "Agott/Attachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Characters of a file's text that go to the model.
    static let textBudget = 40_000

    /// Pages the text layer leaves empty (a scan) are read from the picture,
    /// up to this many per PDF.
    static let scannedPageBudget = 30

    /// Formats the system reads as styled text: Word, RTF, OpenDocument and
    /// web pages. A web page is checked here before it counts as plain text.
    static let documentTypes: [UTType] = [.rtf, .rtfd, .flatRTFD, .html, .webArchive]
        + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
           "org.oasis-open.opendocument.text"].compactMap { UTType($0) }

    static func kind(of url: URL) -> FileAttachment.Kind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .commaSeparatedText) || type.conforms(to: .xml) { return .text }
        return .file
    }

    /// Copies a file in and describes it.
    static func add(_ source: URL) throws -> FileAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let ext = source.pathExtension
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destination = folder.appending(path: fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        let kind = kind(of: source)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return FileAttachment(
            id: id, name: source.lastPathComponent, kind: kind, fileName: fileName,
            pages: kind == .pdf ? PDFDocument(url: destination)?.pageCount : nil, bytes: size)
    }

    /// The words in a file, for the model: a PDF's text (scanned pages read
    /// from the picture), a document's, a text file, or what is written in
    /// an image.
    @concurrent static func text(of attachment: FileAttachment) async -> String? {
        switch attachment.kind {
        case .pdf:
            guard let document = PDFDocument(url: attachment.url) else { return nil }
            var text = ""
            var scanned = 0
            for index in 0..<document.pageCount {
                guard text.count < textBudget else { break }
                guard let page = document.page(at: index) else { continue }
                var words = page.string ?? ""
                // A page with no text layer is a scan or a figure: read the
                // picture. A blank one is skipped, not the end of the document.
                if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scanned < scannedPageBudget {
                    scanned += 1
                    words = await recognizedText(in: page) ?? ""
                }
                guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                text += "\n[page \(index + 1)]\n" + words
            }
            return String(text.prefix(textBudget))
        case .document:
            return await documentText(attachment.url).map { String($0.prefix(textBudget)) }
        case .text:
            guard let data = try? Data(contentsOf: attachment.url) else { return nil }
            return String(String(decoding: data, as: UTF8.self).prefix(textBudget))
        case .image:
            return await recognizedText(in: attachment.url)
        case .file:
            return nil
        }
    }

    /// A Word, RTF, OpenDocument or web page file as plain text. Web pages
    /// are read through WebKit, which wants the main thread.
    static func documentText(_ url: URL) async -> String? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let web = type.map { $0.conforms(to: .html) || $0.conforms(to: .webArchive) } ?? false
        func read() -> String? {
            (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        let text = web ? await MainActor.run { read() } : read()
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// What is written on a PDF page that has no text layer.
    static func recognizedText(in page: PDFPage) async -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 2000 / max(bounds.width, bounds.height)
        let picture = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        #if os(macOS)
        guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let image = picture.cgImage else { return nil }
        #endif
        let request = RecognizeTextRequest()
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func recognizedText(in url: URL) async -> String? {
        let request = RecognizeTextRequest()
        guard let observations = try? await request.perform(on: url) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// What the model reads about the files, plus the images it can look at.
    static func context(for attachments: [FileAttachment], modelSeesImages: Bool) async -> (text: String, images: [URL]) {
        var parts: [String] = []
        var images: [URL] = []
        for attachment in attachments {
            let header = "Attached \(attachment.kind.rawValue) \"\(attachment.name)\""
                + (attachment.pages.map { " (\($0) pages)" } ?? "")
            if attachment.kind == .image && modelSeesImages {
                images.append(attachment.url)
                parts.append("\(header): shown to you as an image.")
                continue
            }
            if attachment.kind == .image {
                // The chat model is blind: a model that sees describes the
                // picture, so a photo with no words in it still gets through.
                let words = await text(of: attachment)
                if let seen = await ImageDescriber.describe(attachment.url) {
                    var part = "\(header), what it shows (described for you by a vision model; talk about it as if you saw it):\n\(seen)"
                    if let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        part += "\n\nText in it:\n\(words)"
                    }
                    parts.append(part)
                    continue
                }
            }
            if let text = await text(of: attachment), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = attachment.kind == .image ? "text found in the image" : "content"
                parts.append("\(header), \(label):\n\(text)")
            } else {
                parts.append("\(header): could not be read.")
            }
        }
        return (parts.joined(separator: "\n\n"), images)
    }
}

/// Looks at a picture for a chat model that cannot: a model that sees
/// writes a description, and the on-device classifier is the fallback.
enum ImageDescriber {
    /// A model that takes images and speaks Chat Completions: the one chosen
    /// for vision in Settings, else the first in the catalogue.
    static var visionModel: String? {
        let catalog = ModelCatalog.shared
        func sees(_ model: CatalogModel?) -> Bool {
            guard let model else { return false }
            return model.vision && model.chatBaseURL != nil && model.executorAPI == .chatCompletions
        }
        let chosen = AppSettings.shared.visionModelName
        if sees(catalog.model(chosen)) { return chosen }
        return catalog.models.first(where: sees)?.id
    }

    static func describe(_ url: URL) async -> String? {
        if ModelHub.isAvailable(.openCode), let id = visionModel {
            let session = LanguageModelSession(
                model: ModelHub.openCodeModel(vision: true, modelName: id),
                instructions: """
                Describe the image for someone who will talk about it without seeing it. \
                Say who or what is in it, what they wear and do, the setting, the mood, and any \
                text, in a few plain sentences. Do not guess names.
                """)
            if let answer = try? await session.respond(to: Prompt {
                "Describe this image."
                FoundationModels.Attachment(imageURL: url)
            }).content, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return answer
            }
        }
        return await Task.detached(priority: .userInitiated) { labels(url) }.value
    }

    /// What Apple's on-device classifier sees, most likely first. Runs where
    /// it is called: keep it off the main thread.
    nonisolated static func labels(_ url: URL) -> String? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(url: url)
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return nil }
        let names = results.filter { $0.confidence > 0.3 }.prefix(10)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        guard !names.isEmpty else { return nil }
        return "An on-device classifier sees: " + names.joined(separator: ", ") + ". (No detailed description was available.)"
    }
}

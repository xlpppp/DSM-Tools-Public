import SwiftUI
import WebKit
import ZIPFoundation
import DSMKit

enum BookKind {
    static let extensions: Set<String> = ["epub", "txt", "text", "mobi", "azw", "azw3"]

    static func matches(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Reader for TXT, EPUB and classic MOBI. Type size, spacing, font and theme stay on this phone.
struct BookReaderView: View {
    let file: RemoteFile
    var remoteURL: (() async throws -> URL)?

    @Environment(SessionManager.self) private var session
    @AppStorage("book.font") private var font = "serif"
    @AppStorage("book.size") private var size = 18.0
    @AppStorage("book.spacing") private var spacing = 1.65
    @AppStorage("book.theme") private var theme = "paper"
    @AppStorage("book.margin") private var margin = 22.0
    @State private var html: String?
    @State private var error: String?
    @State private var page = BookWebPage()

    var body: some View {
        Group {
            if let html {
                BookWebView(html: html, page: page)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error {
                ContentUnavailableView("无法打开", systemImage: "book.closed", description: Text(error))
            } else {
                ProgressView("正在打开…")
            }
        }
        .background(BookTheme.color(theme).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("风格", selection: $theme) {
                        Text("纸张").tag("paper")
                        Text("护眼").tag("sepia")
                        Text("夜间").tag("night")
                    }
                    Picker("字体", selection: $font) {
                        Text("衬线").tag("serif")
                        Text("黑体").tag("sans")
                        Text("等宽").tag("mono")
                    }
                    Stepper("字号 \(Int(size))", value: $size, in: 14...32, step: 1)
                    Stepper("行距 \(spacing, specifier: "%.1f")", value: $spacing, in: 1.2...2.4, step: 0.1)
                    Stepper("边距 \(Int(margin))", value: $margin, in: 12...48, step: 2)
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .onChange(of: styleKey) { _, _ in page.apply(style) }
        .task { await load() }
    }

    private var styleKey: String { "\(font)-\(size)-\(spacing)-\(theme)-\(margin)" }

    private var style: String {
        let face: String
        switch font {
        case "sans": face = "-apple-system, sans-serif"
        case "mono": face = "ui-monospace, monospace"
        default: face = "Iowan Old Style, Palatino, serif"
        }
        let colors = BookTheme.css(theme)
        return """
        body { margin: 0; background: \(colors.bg); color: \(colors.fg); }
        #page { font-family: \(face); font-size: \(Int(size))px; line-height: \(spacing);
                 padding: \(Int(margin))px; }
        img { max-width: 100%; height: auto; }
        p { margin: 0.8em 0; }
        """
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let data = try await previewBytes(client: client, path: file.path, remoteURL: remoteURL)
            let body = try BookDocument.html(name: file.name, data: data)
            html = BookDocument.page(body: body, css: style)
        } catch {
            self.error = error.userMessage
        }
    }
}

private enum BookTheme {
    static func color(_ name: String) -> Color {
        switch name {
        case "night": return Color(hex: 0x121212)
        case "sepia": return Color(hex: 0xF4ECD8)
        default: return Color(hex: 0xFFFEF8)
        }
    }

    static func css(_ name: String) -> (bg: String, fg: String) {
        switch name {
        case "night": return ("#121212", "#E8E8E8")
        case "sepia": return ("#F4ECD8", "#3B2F23")
        default: return ("#FFFEF8", "#1C1917")
        }
    }
}

enum BookDocument {
    static func html(name: String, data: Data) throws -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "epub": return try epub(data)
        case "mobi", "azw", "azw3": return try mobi(data)
        default: return "<pre>" + escape(text(data)) + "</pre>"
        }
    }

    static func page(body: String, css: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style id="reader">\(css)</style></head><body><div id="page">\(body)</div></body></html>
        """
    }

    private static func text(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb)) ?? String(decoding: data, as: UTF8.self)
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func epub(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .read)
        func read(_ path: String) throws -> String {
            guard let entry = archive[path] ?? archive[path.removingPercentEncoding ?? path] else {
                throw DSMError.invalidResponse
            }
            var out = Data()
            _ = try archive.extract(entry) { out.append($0) }
            return text(out)
        }
        let container = try read("META-INF/container.xml")
        guard let opfPath = first(#"full-path\s*=\s*"([^"]+)""#, in: container) else { throw DSMError.invalidResponse }
        let opf = try read(opfPath)
        let base = (opfPath as NSString).deletingLastPathComponent
        var hrefs: [String: String] = [:]
        for match in all(#"id\s*=\s*"([^"]+)"[^>]*href\s*=\s*"([^"]+)""#, in: opf) where match.count == 2 {
            hrefs[match[0]] = match[1]
        }
        for match in all(#"href\s*=\s*"([^"]+)"[^>]*id\s*=\s*"([^"]+)""#, in: opf) where match.count == 2 {
            hrefs[match[1]] = match[0]
        }
        let spine = all(#"idref\s*=\s*"([^"]+)""#, in: opf).compactMap { $0.first }
        let parts = spine.compactMap { id -> String? in
            guard let href = hrefs[id] else { return nil }
            let path = base == "" || base == "." ? href : base + "/" + href
            return try? read(path.removingPercentEncoding ?? path)
        }
        guard !parts.isEmpty else { throw DSMError.invalidResponse }
        return parts.joined(separator: "\n")
    }

    private static func mobi(_ data: Data) throws -> String {
        guard data.count > 100 else { throw DSMError.invalidResponse }
        let name = String(data: data.subdata(in: 60..<min(68, data.count)), encoding: .ascii) ?? ""
        guard name == "BOOKMOBI" else { throw DSMError.invalidResponse }
        let records = int16(data, 76)
        guard records > 1 else { throw DSMError.invalidResponse }
        func offset(_ index: Int) -> Int { int32(data, 78 + index * 8) }
        let header = offset(0)
        let compression = int16(data, header)
        let textRecords = int16(data, header + 0x18)
        guard compression == 1 || compression == 2 else {
            throw DSMError.transport("这个 MOBI 使用了 KF8 压缩，请在电脑上转为 EPUB 后再阅读。")
        }
        var raw = Data()
        let count = min(Int(textRecords), records - 1)
        for index in 1...count {
            let start = offset(index)
            let end = index + 1 < records ? offset(index + 1) : data.count
            guard start >= 0, end > start, end <= data.count else { continue }
            let chunk = data.subdata(in: start..<end)
            raw.append(compression == 2 ? palmDoc(chunk) : chunk)
        }
        let body = text(raw).trimmingCharacters(in: .controlCharacters)
        guard !body.isEmpty else { throw DSMError.invalidResponse }
        return "<pre>" + escape(body) + "</pre>"
    }

    private static func palmDoc(_ data: Data) -> Data {
        var out = Data()
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            if b == 0 { break }
            if b <= 8, index + Int(b) <= bytes.count {
                out.append(contentsOf: bytes[index..<(index + Int(b))])
                index += Int(b)
            } else if b < 0x80 {
                out.append(b)
            } else if b >= 0xC0 {
                out.append(32)
                out.append(b ^ 0x80)
            } else if index < bytes.count {
                let next = bytes[index]
                index += 1
                let pair = (Int(b) << 8) | Int(next)
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                for _ in 0..<length {
                    out.append(out[out.count - distance])
                }
            }
        }
        return out
    }

    private static func int16(_ data: Data, _ offset: Int) -> Int {
        guard offset + 1 < data.count else { return 0 }
        return (Int(data[offset]) << 8) | Int(data[offset + 1])
    }

    private static func int32(_ data: Data, _ offset: Int) -> Int {
        guard offset + 3 < data.count else { return 0 }
        return (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        regexCaptureGroups(pattern, in: text)?.first
    }

    private static func all(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                let ns = match.range(at: index)
                guard ns.location != NSNotFound, let range = Range(ns, in: text) else { return nil }
                groups.append(String(text[range]))
            }
            return groups
        }
    }
}

private struct BookWebView: UIViewRepresentable {
    let html: String
    let page: BookWebPage

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.isOpaque = false
        view.backgroundColor = .clear
        page.view = view
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        page.view = view
    }
}

@MainActor
final class BookWebPage {
    weak var view: WKWebView?

    func apply(_ css: String) {
        let quoted = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        view?.evaluateJavaScript("document.getElementById('reader').textContent = `\(quoted)`")
    }
}

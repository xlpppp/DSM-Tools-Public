import SwiftUI
import WebKit
import AVFoundation
import MediaPlayer
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
    @AppStorage("book.columns") private var columns = 1
    @AppStorage("book.tracking") private var tracking = 0.0
    @AppStorage("book.paragraph") private var paragraph = 0.8
    @AppStorage("book.align") private var align = "left"
    @AppStorage("book.indent") private var indent = 0.0
    @AppStorage("book.brightness") private var brightness = 1.0
    @AppStorage("book.volumeKeys") private var volumeKeys = true
    @State private var html: String?
    @State private var error: String?
    @State private var page = BookWebPage()
    @State private var pageLabel = ""

    var body: some View {
        Group {
            if let html {
                BookWebView(html: html, page: page)
                    .padding(.horizontal, margin)
                    .overlay {
                        HStack(spacing: 0) {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { page.turn(-1) { pageLabel = $0 } }
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { page.turn(1) { pageLabel = $0 } }
                        }
                    }
                    .overlay { Color.black.opacity(1 - brightness).allowsHitTesting(false) }
            } else if let error {
                ContentUnavailableView("无法打开", systemImage: "book.closed", description: Text(error))
            } else {
                ProgressView("正在打开…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BookTheme.color(theme).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("背景", selection: $theme) {
                        Text("纸张").tag("paper")
                        Text("米黄").tag("sepia")
                        Text("浅绿").tag("green")
                        Text("淡蓝").tag("blue")
                        Text("灰色").tag("gray")
                        Text("夜间").tag("night")
                    }
                    Picker("字体", selection: $font) {
                        Text("衬线").tag("serif")
                        Text("黑体").tag("sans")
                        Text("等宽").tag("mono")
                    }
                    Picker("分栏", selection: $columns) {
                        Text("一栏").tag(1)
                        Text("两栏").tag(2)
                    }
                    Picker("对齐", selection: $align) {
                        Text("左对齐").tag("left")
                        Text("两端对齐").tag("justify")
                    }
                    Stepper("字号 \(Int(size))", value: $size, in: 14...36, step: 1)
                    Stepper("行距 \(spacing, specifier: "%.1f")", value: $spacing, in: 1.1...2.6, step: 0.1)
                    Stepper("段距 \(paragraph, specifier: "%.1f")", value: $paragraph, in: 0...2, step: 0.1)
                    Stepper("字距 \(tracking, specifier: "%.1f")", value: $tracking, in: 0...3, step: 0.2)
                    Stepper("首行缩进 \(indent, specifier: "%.0f")", value: $indent, in: 0...2, step: 1)
                    Stepper("边距 \(Int(margin))", value: $margin, in: 8...48, step: 2)
                    Stepper("亮度 \(Int(brightness * 100))%", value: $brightness, in: 0.4...1, step: 0.05)
                    Toggle("音量键翻页", isOn: $volumeKeys)
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if html != nil {
                HStack {
                    Button { page.turn(-1) { pageLabel = $0 } } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(pageLabel.isEmpty ? "第 1 页" : pageLabel).font(.footnote.monospacedDigit())
                    Spacer()
                    Button { page.turn(1) { pageLabel = $0 } } label: { Image(systemName: "chevron.right") }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .background {
            VolumePageKeys(enabled: volumeKeys && html != nil) { delta in
                page.turn(delta) { pageLabel = $0 }
            }
        }
        .onChange(of: styleKey) { _, _ in page.apply(style, columns: columns, gap: Int(margin) * 2) { pageLabel = $0 } }
        .task { await load() }
    }

    private var styleKey: String {
        "\(font)-\(size)-\(spacing)-\(theme)-\(margin)-\(columns)-\(tracking)-\(paragraph)-\(align)-\(indent)-\(brightness)"
    }

    private var style: String {
        let face: String
        switch font {
        case "sans": face = "-apple-system, sans-serif"
        case "mono": face = "ui-monospace, monospace"
        default: face = "Iowan Old Style, Palatino, serif"
        }
        let colors = BookTheme.css(theme)
        return """
        html, body { height: 100%; margin: 0; overflow: hidden; background: \(colors.bg); color: \(colors.fg); }
        #scroller { height: 100%; overflow: hidden; }
        #page { height: 100%; box-sizing: border-box; column-fill: auto; margin: 0;
                font-family: \(face); font-size: \(Int(size))px; line-height: \(spacing);
                letter-spacing: \(tracking)px; text-align: \(align == "justify" ? "justify" : "left");
                white-space: normal; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word;
              margin: 0; font-family: inherit; font-size: inherit; line-height: inherit; text-indent: 0; }
        img { max-width: 100%; height: auto; }
        p { margin: 0 0 \(paragraph)em; text-indent: \(indent)em; }
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
        case "green": return Color(hex: 0xE7F3E1)
        case "blue": return Color(hex: 0xE8F1F8)
        case "gray": return Color(hex: 0xF2F2F2)
        default: return Color(hex: 0xFFFEF8)
        }
    }

    static func css(_ name: String) -> (bg: String, fg: String) {
        switch name {
        case "night": return ("#121212", "#E8E8E8")
        case "sepia": return ("#F4ECD8", "#3B2F23")
        case "green": return ("#E7F3E1", "#1C2B18")
        case "blue": return ("#E8F1F8", "#1A2836")
        case "gray": return ("#F2F2F2", "#222222")
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
        <style id="reader">\(css)</style>
        <script>
        window.nasColumns = 1;
        window.nasGap = 40;
        function nasLayout() {
          var box = document.getElementById('scroller');
          var page = document.getElementById('page');
          if (!box || !page) return;
          var cols = window.nasColumns > 1 ? 2 : 1;
          var w = box.clientWidth || window.innerWidth || 1;
          var col = Math.max(40, Math.floor(w / cols));
          page.style.columnWidth = col + 'px';
          page.style.columnGap = '0px';
          page.style.padding = '16px 0';
          page.style.height = (box.clientHeight || window.innerHeight) + 'px';
          page.style.columnFill = 'auto';
          page.style.boxSizing = 'border-box';
          window.nasStep = col * cols;
        }
        function nasTurn(delta) {
          nasLayout();
          var box = document.getElementById('scroller');
          var step = window.nasStep || box.clientWidth || 1;
          var max = Math.max(0, box.scrollWidth - step);
          var index0 = Math.round(box.scrollLeft / step);
          var x = Math.max(0, Math.min(max, (index0 + delta) * step));
          box.scrollLeft = x;
          var pages = Math.max(1, Math.ceil(box.scrollWidth / step));
          var index = Math.min(pages, Math.round(x / step) + 1);
          return index + '/' + pages;
        }
        </script>
        </head><body><div id="scroller"><div id="page">\(body)</div></div>
        <script>nasLayout();</script></body></html>
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

    func apply(_ css: String, columns: Int, gap: Int, done: @escaping (String) -> Void = { _ in }) {
        let quoted = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        let script = "window.nasColumns=\(columns);window.nasGap=\(gap);document.getElementById('reader').textContent=`\(quoted)`;nasTurn(0)"
        view?.evaluateJavaScript(script) { result, _ in
            let text = result as? String ?? ""
            DispatchQueue.main.async { done(text.isEmpty ? "" : "第 \(text.replacingOccurrences(of: "/", with: " / ")) 页") }
        }
    }

    func turn(_ delta: Int, done: @escaping (String) -> Void) {
        view?.evaluateJavaScript("nasTurn(\(delta))") { result, _ in
            let text = result as? String ?? ""
            DispatchQueue.main.async { done(text.isEmpty ? "" : "第 \(text.replacingOccurrences(of: "/", with: " / ")) 页") }
        }
    }
}

/// Volume up turns back a page, volume down turns forward. The system volume is put back.
private struct VolumePageKeys: UIViewControllerRepresentable {
    var enabled: Bool
    var turn: (Int) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.turn = turn
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.enabled = enabled
        controller.turn = turn
    }

    final class Controller: UIViewController {
        var enabled = true
        var turn: (Int) -> Void = { _ in }
        private var base: Float = 0.5
        private var busy = false
        private var slider: UISlider?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            let volume = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            view.addSubview(volume)
            slider = volume.subviews.compactMap { $0 as? UISlider }.first
            try? AVAudioSession.sharedInstance().setActive(true)
            base = AVAudioSession.sharedInstance().outputVolume
            AVAudioSession.sharedInstance().addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        }

        deinit {
            AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            guard keyPath == "outputVolume", enabled, !busy else { return }
            let now = AVAudioSession.sharedInstance().outputVolume
            guard abs(now - base) > 0.001 else { return }
            busy = true
            let direction = now > base ? -1 : 1
            DispatchQueue.main.async { self.turn(direction) }
            slider?.setValue(base, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.busy = false }
        }
    }
}

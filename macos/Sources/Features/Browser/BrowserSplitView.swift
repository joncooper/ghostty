import AppKit
import Darwin
import SwiftUI
import WebKit

enum BrowserSplitFocusTarget: Equatable {
    case addressBar
    case webView
}

struct BrowserSplitFocusRequest: Equatable {
    let id: UUID
    let target: BrowserSplitFocusTarget

    init(target: BrowserSplitFocusTarget) {
        self.id = UUID()
        self.target = target
    }
}

enum BrowserHostAction: Equatable {
    case open
    case close
    case focus
    case openURL(String)

    static func parse(_ action: String) -> BrowserHostAction? {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "browser_split":
            return .open
        case "browser_close":
            return .close
        case "browser_focus":
            return .focus
        default:
            break
        }

        let prefix = "browser_open_url:"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return .openURL(String(trimmed.dropFirst(prefix.count)))
    }
}

struct BrowserSplitRestorableState: Codable, Equatable {
    static let defaultSplitRatio: Double = 0.67

    let currentLocation: String?
    let splitRatio: Double

    init(currentLocation: String?, splitRatio: Double = BrowserSplitRestorableState.defaultSplitRatio) {
        self.currentLocation = currentLocation
        self.splitRatio = min(max(splitRatio, 0.2), 0.8)
    }
}

@MainActor
final class BrowserSplitModel: NSObject, ObservableObject {
    @Published var address: String
    @Published private(set) var canGoBack: Bool
    @Published private(set) var canGoForward: Bool
    @Published private(set) var isLoading: Bool
    @Published var splitRatio: CGFloat
    @Published private(set) var focusRequest: BrowserSplitFocusRequest?

    let webView: BrowserSplitNativeView

    private(set) var currentLocation: String?

    override init() {
        self.address = ""
        self.canGoBack = false
        self.canGoForward = false
        self.isLoading = false
        self.splitRatio = CGFloat(BrowserSplitRestorableState.defaultSplitRatio)
        self.focusRequest = nil
        self.webView = BrowserSplitNativeView(frame: .zero, configuration: BrowserSplitModel.makeConfiguration())
        self.currentLocation = nil

        super.init()

        configureWebView()
        loadPlaceholderPage()
    }

    convenience init(focusOnAppear: Bool) {
        self.init()
        if focusOnAppear {
            focusRequest = .init(target: .addressBar)
        }
    }

    init(restoring state: BrowserSplitRestorableState, focusOnAppear: Bool = false) {
        self.address = state.currentLocation ?? ""
        self.canGoBack = false
        self.canGoForward = false
        self.isLoading = false
        self.splitRatio = CGFloat(min(max(state.splitRatio, 0.2), 0.8))
        self.focusRequest = focusOnAppear ? .init(target: state.currentLocation == nil ? .addressBar : .webView) : nil
        self.webView = BrowserSplitNativeView(frame: .zero, configuration: BrowserSplitModel.makeConfiguration())
        self.currentLocation = state.currentLocation

        super.init()

        configureWebView()

        if let location = state.currentLocation {
            openLocation(location)
        } else {
            loadPlaceholderPage()
        }
    }

    nonisolated var restorableState: BrowserSplitRestorableState {
        MainActor.assumeIsolated {
            .init(
                currentLocation: currentLocation,
                splitRatio: Double(splitRatio))
        }
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
        refreshNavigationState()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
        refreshNavigationState()
    }

    func reload() {
        if currentLocation == nil {
            loadPlaceholderPage()
            return
        }

        webView.reload()
        refreshNavigationState()
    }

    func stopLoading() {
        webView.stopLoading()
        refreshNavigationState()
    }

    func requestDefaultFocus() {
        focusRequest = .init(target: currentLocation == nil ? .addressBar : .webView)
    }

    func completeFocusRequest(_ request: BrowserSplitFocusRequest) {
        guard focusRequest == request else { return }
        focusRequest = nil
    }

    func focusWebView() {
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
        }
    }

    func openLocation(_ candidate: String? = nil) {
        let rawValue = (candidate ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            address = ""
            currentLocation = nil
            loadPlaceholderPage()
            return
        }

        guard let url = Self.resolvedURL(from: rawValue) else {
            address = rawValue
            currentLocation = nil
            loadInvalidLocationPage(rawValue)
            return
        }

        let absoluteString = url.absoluteString
        address = absoluteString
        currentLocation = absoluteString
        webView.load(URLRequest(url: url))
        refreshNavigationState()
    }

    nonisolated static func resolvedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        let lowercase = trimmed.lowercased()
        if lowercase.hasPrefix("http://") ||
            lowercase.hasPrefix("https://") ||
            lowercase.hasPrefix("file://") ||
            lowercase.hasPrefix("about:") ||
            lowercase.hasPrefix("data:") {
            return URL(string: trimmed)
        }

        if trimmed.contains(where: { $0.isWhitespace }) {
            return nil
        }

        return URL(string: "https://\(trimmed)")
    }

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        refreshNavigationState()
    }

    private func loadPlaceholderPage() {
        currentLocation = nil
        webView.loadHTMLString(
            """
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <style>
                  :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
                  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: canvas; color: canvastext; }
                  main { max-width: 30rem; padding: 2rem; text-align: center; line-height: 1.5; }
                  h1 { margin-bottom: 0.75rem; font-size: 1.5rem; }
                  p { margin: 0; opacity: 0.8; }
                </style>
              </head>
              <body>
                <main>
                  <h1>Browser Split</h1>
                  <p>Enter a URL in the address bar to load a page inside Ghostty.</p>
                </main>
              </body>
            </html>
            """,
            baseURL: nil)
        refreshNavigationState()
    }

    private func loadInvalidLocationPage(_ location: String) {
        let escapedLocation = Self.escapeHTML(location)
        webView.loadHTMLString(
            """
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <style>
                  :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
                  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: canvas; color: canvastext; }
                  main { max-width: 30rem; padding: 2rem; text-align: center; line-height: 1.5; }
                  h1 { margin-bottom: 0.75rem; font-size: 1.5rem; color: #c53b2c; }
                  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
                </style>
              </head>
              <body>
                <main>
                  <h1>Invalid Address</h1>
                  <p>Ghostty couldn’t turn <code>\(escapedLocation)</code> into a URL.</p>
                </main>
              </body>
            </html>
            """,
            baseURL: nil)
        refreshNavigationState()
    }

    private func refreshNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

extension BrowserSplitModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let absoluteString = webView.url?.absoluteString {
            currentLocation = absoluteString
            address = absoluteString
        }
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshNavigationState()
    }
}

final class BrowserSplitNativeView: WKWebView {
    var focusDidChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusDidChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            focusDidChange?(false)
        }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            focusDidChange?(false)
        }
    }
}

struct BrowserSplitView: View {
    @ObservedObject var model: BrowserSplitModel

    let onClose: () -> Void
    let onFocusChange: (Bool) -> Void

    @FocusState private var addressFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            BrowserSplitWebViewRepresentable(
                webView: model.webView,
                onFocusChange: onFocusChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Browser pane")
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let request = model.focusRequest {
                performFocus(request)
            }
        }
        .onChange(of: model.focusRequest) { request in
            guard let request else { return }
            performFocus(request)
        }
        .onChange(of: addressFieldFocused) { focused in
            onFocusChange(focused)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("Back")

            Button(action: model.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("Forward")

            Button(action: model.isLoading ? model.stopLoading : model.reload) {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(model.isLoading ? "Stop Loading" : "Reload")

            TextField("Enter URL", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFieldFocused)
                .onSubmit {
                    model.openLocation()
                }
                .accessibilityLabel("Browser address")
                .accessibilityIdentifier("BrowserSplitAddressField")

            Button("Open") {
                model.openLocation()
            }
            .accessibilityIdentifier("BrowserSplitOpenButton")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Close Browser Split")
            .accessibilityLabel("Close Browser Split")
        }
        .padding(10)
    }

    private func performFocus(_ request: BrowserSplitFocusRequest) {
        DispatchQueue.main.async {
            switch request.target {
            case .addressBar:
                addressFieldFocused = true
            case .webView:
                model.focusWebView()
            }
        }
        model.completeFocusRequest(request)
    }
}

private struct BrowserSplitWebViewRepresentable: NSViewRepresentable {
    let webView: BrowserSplitNativeView
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> BrowserSplitNativeView {
        webView.focusDidChange = onFocusChange
        return webView
    }

    func updateNSView(_ nsView: BrowserSplitNativeView, context: Context) {
        nsView.focusDidChange = onFocusChange
    }
}

private let browserSplitCommandTerminator = Data("\n\n".utf8)

enum BrowserSplitCommandProtocolError: Error, Equatable {
    case invalidLine(String)
    case missingField(String)
    case invalidBoolean(String)
    case invalidEncoding
}

struct BrowserSplitCommandRequest: Equatable {
    let terminalID: String
    let close: Bool
    let focus: Bool
    let url: String?

    func serialized() -> Data {
        Data(
            """
            terminal-id:\(terminalID)
            close:\(close ? "true" : "false")
            focus:\(focus ? "true" : "false")
            url:\(url ?? "")

            """.utf8)
    }

    static func parse(_ data: Data) throws -> BrowserSplitCommandRequest {
        let fields = try parseFields(data)
        return .init(
            terminalID: try requireField("terminal-id", in: fields),
            close: try parseBooleanField("close", in: fields),
            focus: try parseBooleanField("focus", in: fields),
            url: fields["url"].flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct BrowserSplitCommandResponse: Equatable {
    let ok: Bool
    let error: String?

    func serialized() -> Data {
        Data(
            """
            ok:\(ok ? "true" : "false")
            error:\(error ?? "")

            """.utf8)
    }

    static func parse(_ data: Data) throws -> BrowserSplitCommandResponse {
        let fields = try parseFields(data)
        return .init(
            ok: try parseBooleanField("ok", in: fields),
            error: fields["error"].flatMap { $0.isEmpty ? nil : $0 })
    }
}

private func parseFields(_ data: Data) throws -> [String: String] {
    guard let message = String(data: data, encoding: .utf8) else {
        throw BrowserSplitCommandProtocolError.invalidEncoding
    }

    var result: [String: String] = [:]
    for rawLine in message.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
        guard let separator = line.firstIndex(of: ":") else {
            throw BrowserSplitCommandProtocolError.invalidLine(String(line))
        }

        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        result[key] = value
    }

    return result
}

private func requireField(_ key: String, in fields: [String: String]) throws -> String {
    guard let value = fields[key] else {
        throw BrowserSplitCommandProtocolError.missingField(key)
    }
    return value
}

private func parseBooleanField(_ key: String, in fields: [String: String]) throws -> Bool {
    let value = try requireField(key, in: fields)
    switch value {
    case "true":
        return true
    case "false":
        return false
    default:
        throw BrowserSplitCommandProtocolError.invalidBoolean(key)
    }
}

enum BrowserSplitCommandServerError: Error, Equatable {
    case messageTooLarge
    case missingTerminator
    case socketPathTooLong
    case posix(Int32)
}

final class BrowserSplitCommandServer {
    typealias Handler = (BrowserSplitCommandRequest) -> BrowserSplitCommandResponse

    let socketPath: String

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.browser-split")
    private var readSource: DispatchSourceRead?
    private var socketFD: Int32 = -1

    init(
        socketPath: String = BrowserSplitCommandServer.socketPath(
            processID: ProcessInfo.processInfo.processIdentifier),
        handler: @escaping Handler)
    {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    static func socketPath(processID: Int32) -> String {
        "/tmp/ghostty-browser-\(processID).sock"
    }

    func start() throws {
        guard readSource == nil else { return }

        try removeSocketFileIfPresent()

        let socketType = Int32(SOCK_STREAM)
        let fd = Darwin.socket(AF_UNIX, socketType, 0)
        guard fd >= 0 else { throw BrowserSplitCommandServerError.posix(errno) }

        do {
            try configure(socketFD: fd)
            try bind(socketFD: fd)
            guard Darwin.listen(fd, SOMAXCONN) == 0 else {
                throw BrowserSplitCommandServerError.posix(errno)
            }
        } catch {
            Darwin.close(fd)
            try? removeSocketFileIfPresent()
            throw error
        }

        socketFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.resume()
        readSource = source
    }

    func stop() {
        readSource?.cancel()
        readSource = nil

        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }

        try? removeSocketFileIfPresent()
    }

    private func configure(socketFD: Int32) throws {
        let currentFlags = fcntl(socketFD, F_GETFL)
        guard currentFlags >= 0 else { throw BrowserSplitCommandServerError.posix(errno) }
        guard fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            throw BrowserSplitCommandServerError.posix(errno)
        }
        guard fcntl(socketFD, F_SETFD, FD_CLOEXEC) == 0 else {
            throw BrowserSplitCommandServerError.posix(errno)
        }
    }

    private func bind(socketFD: Int32) throws {
        var address = sockaddr_un()
        let utf8Path = socketPath.utf8CString

        guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BrowserSplitCommandServerError.socketPathTooLong
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        address.sun_family = sa_family_t(AF_UNIX)

        utf8Path.withUnsafeBufferPointer { pathBuffer in
            guard let pathBaseAddress = pathBuffer.baseAddress else { return }
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                let destination = UnsafeMutableRawPointer(pathPointer)
                destination.copyMemory(
                    from: UnsafeRawPointer(pathBaseAddress),
                    byteCount: pathBuffer.count)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard result == 0 else { throw BrowserSplitCommandServerError.posix(errno) }

        guard chmod(socketPath, 0o600) == 0 else {
            throw BrowserSplitCommandServerError.posix(errno)
        }
    }

    private func acceptConnections() {
        while true {
            let clientFD = Darwin.accept(socketFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            handleConnection(clientFD)
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { Darwin.close(clientFD) }

        let response = Result(catching: {
            let request = try readRequest(from: clientFD)
            return DispatchQueue.main.sync {
                handler(request)
            }
        }).getOrElse { error in
            BrowserSplitCommandResponse(
                ok: false,
                error: String(describing: error))
        }

        try? writeAll(response.serialized(), to: clientFD)
    }

    private func readRequest(from clientFD: Int32) throws -> BrowserSplitCommandRequest {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                if let range = data.range(of: browserSplitCommandTerminator) {
                    return try BrowserSplitCommandRequest.parse(data.subdata(in: 0..<range.lowerBound))
                }
                if data.count > 64 * 1024 {
                    throw BrowserSplitCommandServerError.messageTooLarge
                }
                continue
            }

            if count == 0 {
                throw BrowserSplitCommandServerError.missingTerminator
            }

            if errno == EINTR {
                continue
            }

            throw BrowserSplitCommandServerError.posix(errno)
        }
    }

    private func writeAll(_ data: Data, to clientFD: Int32) throws {
        let bytes = Array(data)
        try bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0

            while offset < buffer.count {
                let written = Darwin.write(
                    clientFD,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1 && errno == EINTR {
                    continue
                }
                throw BrowserSplitCommandServerError.posix(errno)
            }
        }
    }

    private func removeSocketFileIfPresent() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: socketPath) else { return }
        try fileManager.removeItem(atPath: socketPath)
    }
}

private extension Result {
    func getOrElse(_ fallback: (Failure) -> Success) -> Success {
        switch self {
        case .success(let success):
            return success
        case .failure(let failure):
            return fallback(failure)
        }
    }
}

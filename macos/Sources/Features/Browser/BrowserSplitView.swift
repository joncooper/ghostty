import AppKit
import SwiftUI
import WebKit

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

    let webView: BrowserSplitNativeView

    private(set) var currentLocation: String?

    override init() {
        self.address = ""
        self.canGoBack = false
        self.canGoForward = false
        self.isLoading = false
        self.splitRatio = CGFloat(BrowserSplitRestorableState.defaultSplitRatio)
        self.webView = BrowserSplitNativeView(frame: .zero, configuration: BrowserSplitModel.makeConfiguration())
        self.currentLocation = nil

        super.init()

        configureWebView()
        loadPlaceholderPage()
    }

    init(restoring state: BrowserSplitRestorableState) {
        self.address = state.currentLocation ?? ""
        self.canGoBack = false
        self.canGoForward = false
        self.isLoading = false
        self.splitRatio = CGFloat(min(max(state.splitRatio, 0.2), 0.8))
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
            if model.currentLocation == nil {
                DispatchQueue.main.async {
                    addressFieldFocused = true
                }
            }
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

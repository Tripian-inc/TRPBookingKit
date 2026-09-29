import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// What the hosted payment page posts to `window.webkit.messageHandlers.viatorPayment`.
///
/// `{event: "ready"}`, `{event: "success", paymentToken}`, `{event: "error", message?, code?}`,
/// `{event: "cancel"}`. See `docs/viator-payment-page.html` for the page side of the contract.
public enum ViatorPaymentMessage: Sendable, Hashable {
    public static let handlerName = "viatorPayment"

    case ready
    case success(paymentToken: String)
    case error(code: String?, message: String?)
    case cancel

    /// Parses a `WKScriptMessage.body`; `nil` for anything outside the contract.
    public init?(body: Any) {
        guard let object = body as? [String: Any], let event = object["event"] as? String else { return nil }
        switch event {
        case "ready":
            self = .ready
        case "success":
            guard let token = object["paymentToken"] as? String, !token.isEmpty else { return nil }
            self = .success(paymentToken: token)
        case "error":
            self = .error(code: object["code"].map { "\($0)" }, message: object["message"] as? String)
        case "cancel":
            self = .cancel
        default:
            return nil
        }
    }
}

/// The script that starts Viator's form once the page has loaded, passing the session token in
/// memory rather than in the url.
public enum ViatorPaymentScript {
    public static func start(sessionToken: String, languageCode: String) -> String {
        let payload = ["sessionToken": sessionToken, "language": ViatorAPIClient.acceptLanguage(for: languageCode)]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.trpViatorPayment && window.trpViatorPayment.start(\(json));"
    }
}

#if canImport(WebKit) && os(iOS)
/// Hosts Viator's payment form in a `WKWebView` locked to the payment page's origin, and answers
/// with the payment token the form produces.
///
/// The host presents `webView`; `paymentToken(for:)` waits for the page to report back and throws
/// `BookingError.paymentCancelled` when `cancel()` is called or the page posts `cancel`.
@MainActor
public final class ViatorPaymentWebSession: NSObject {

    public let webView: WKWebView
    private let pageURL: URL
    private let allowedOrigin: String
    private let languageCode: String
    private var sessionToken: String?
    private var continuation: CheckedContinuation<String, Error>?

    public init(credentials: ViatorCredentials, languageCode: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        pageURL = credentials.paymentPageURL
        allowedOrigin = credentials.hostingOrigin
        self.languageCode = languageCode
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: ViatorPaymentMessage.handlerName)
        webView.navigationDelegate = self
    }

    /// Loads the page and waits for the token. Only one payment runs at a time.
    public func paymentToken(sessionToken: String) async throws -> String {
        continuation?.resume(throwing: BookingError.paymentCancelled)
        self.sessionToken = sessionToken
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: pageURL))
        }
    }

    public func cancel() {
        finish(.failure(BookingError.paymentCancelled))
    }

    /// Drops the message handler; call when the screen goes away.
    public func invalidate() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ViatorPaymentMessage.handlerName)
        cancel()
    }

    fileprivate func receive(_ message: ViatorPaymentMessage) {
        switch message {
        case .ready:
            break
        case .success(let token):
            finish(.success(token))
        case .error(let code, let message):
            finish(.failure(BookingError.paymentFailed(message ?? code ?? "The payment could not be completed.")))
        case .cancel:
            finish(.failure(BookingError.paymentCancelled))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        sessionToken = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    fileprivate func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "about" { return true }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else { return false }
        let origin = components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        return origin == allowedOrigin
    }
}

extension ViatorPaymentWebSession: ViatorPaymentTokenProviding {

    public nonisolated func paymentToken(for hold: ViatorCheckoutHold) async throws -> String {
        try await paymentToken(sessionToken: hold.paymentSessionToken)
    }
}

extension ViatorPaymentWebSession: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        decisionHandler(!isMainFrame || isAllowed(navigationAction.request.url) ? .allow : .cancel)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let sessionToken, isAllowed(webView.url) else { return }
        webView.evaluateJavaScript(ViatorPaymentScript.start(sessionToken: sessionToken, languageCode: languageCode))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(BookingError.transport(error.localizedDescription)))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(BookingError.transport(error.localizedDescription)))
    }
}

/// Keeps `WKUserContentController` from retaining the session.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var session: ViatorPaymentWebSession?

    init(_ session: ViatorPaymentWebSession) {
        self.session = session
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let parsed = ViatorPaymentMessage(body: message.body) else { return }
        MainActor.assumeIsolated {
            guard let session, session.isAllowed(message.frameInfo.request.url) else { return }
            session.receive(parsed)
        }
    }
}
#endif

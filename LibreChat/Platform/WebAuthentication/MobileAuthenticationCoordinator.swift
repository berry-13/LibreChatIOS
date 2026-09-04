import AuthenticationServices
import CryptoKit
import Foundation
import LibreChatDomain
import LibreChatProtocol
import Security
import SwiftUI
import UIKit

struct MobileAuthorizationGrant: Sendable {
    let code: String
    let verifier: String
    let redirectURI: URL
}

enum MobileAuthenticationCallbackParser {
    private static let allowedQueryNames: Set<String> = [
        "code", "state", "error", "error_description"
    ]

    static func authorizationCode(
        from callback: URL,
        expectedState: String
    ) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "librechat",
              components.host?.lowercased() == "auth",
              components.percentEncodedPath == "/callback",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil else {
            throw MobileAuthenticationError.invalidCallback
        }

        let items = components.queryItems ?? []
        let names = items.map(\.name)
        guard Set(names).count == names.count,
              Set(names).isSubset(of: allowedQueryNames) else {
            throw MobileAuthenticationError.invalidCallback
        }
        guard let state = items.first(where: { $0.name == "state" })?.value,
              state == expectedState else {
            throw MobileAuthenticationError.stateMismatch
        }
        guard !names.contains("error"),
              !names.contains("error_description"),
              Set(names) == ["state", "code"] else {
            throw MobileAuthenticationError.invalidCallback
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty,
              code.utf8.count <= 2_048 else {
            throw MobileAuthenticationError.invalidCallback
        }
        return code
    }
}

enum MobileAuthenticationError: LocalizedError {
    case invalidConfiguration
    case invalidCallback
    case stateMismatch

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "This server returned an invalid mobile sign-in configuration."
        case .invalidCallback: "LibreChat did not return a usable authorization code."
        case .stateMismatch: "The sign-in response could not be verified. Please try again."
        }
    }
}

@MainActor
final class MobileAuthenticationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(
        profile: ServerProfile,
        provider: AuthenticationMethod,
        configuration: MobileAuthenticationConfigDTO
    ) async throws -> MobileAuthorizationGrant {
        guard configuration.protocolVersion == 1 else { throw MobileAuthenticationError.invalidConfiguration }
        let redirectURI = URL(string: "librechat://auth/callback")!
        let verifier = try Self.randomURLSafeValue(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try Self.randomURLSafeValue(byteCount: 24)
        let endpoint = try Self.endpoint(
            configuration.authorizationEndpoint,
            fallback: "api/auth/mobile/authorize",
            baseURL: profile.baseURL
        )
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw MobileAuthenticationError.invalidConfiguration
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "profile", value: profile.id.rawValue)
        ]
        guard let authorizationURL = components.url else { throw MobileAuthenticationError.invalidConfiguration }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "librechat"
            ) { callback, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callback else {
                    continuation.resume(throwing: MobileAuthenticationError.invalidCallback)
                    return
                }
                do {
                    let code = try MobileAuthenticationCallbackParser.authorizationCode(
                        from: callback,
                        expectedState: state
                    )
                    continuation.resume(returning: MobileAuthorizationGrant(
                        code: code,
                        verifier: verifier,
                        redirectURI: redirectURI
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: MobileAuthenticationError.invalidConfiguration)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    static func endpoint(_ advertised: String?, fallback: String, baseURL: URL) throws -> URL {
        if let advertised, let absolute = URL(string: advertised), absolute.scheme != nil {
            guard isTrustedAuthorizationEndpoint(absolute, for: baseURL) else {
                throw MobileAuthenticationError.invalidConfiguration
            }
            return absolute
        }
        let rawComponents = (advertised ?? fallback).split(separator: "/")
        guard !rawComponents.isEmpty,
              rawComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw MobileAuthenticationError.invalidConfiguration
        }
        var url = baseURL
        for component in rawComponents { url.append(path: String(component)) }
        return url
    }

    static func randomURLSafeValue(
        byteCount: Int,
        randomBytes: @MainActor (Int) throws -> Data = secureRandomBytes
    ) throws -> String {
        guard byteCount > 0 else { throw MobileAuthenticationError.invalidConfiguration }
        return base64URL(try randomBytes(byteCount))
    }

    private static func secureRandomBytes(byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MobileAuthenticationError.invalidConfiguration
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isTrustedAuthorizationEndpoint(_ endpoint: URL, for baseURL: URL) -> Bool {
        guard let endpointComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              endpointComponents.user == nil,
              endpointComponents.password == nil,
              endpointComponents.fragment == nil,
              endpointComponents.query == nil,
              endpointComponents.host?.lowercased() == baseComponents.host?.lowercased(),
              endpointComponents.scheme?.lowercased() == baseComponents.scheme?.lowercased(),
              effectivePort(endpointComponents) == effectivePort(baseComponents),
              isSecureServerURL(endpointComponents),
              !endpointComponents.percentEncodedPath.lowercased().contains("%2e") else {
            return false
        }

        let basePath = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = endpointComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return basePath.isEmpty || endpointPath == basePath || endpointPath.hasPrefix(basePath + "/")
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private static func isSecureServerURL(_ components: URLComponents) -> Bool {
        if components.scheme?.lowercased() == "https" { return true }
        guard components.scheme?.lowercased() == "http" else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(components.host?.lowercased())
    }
}

// MARK: - Stock-server social login (in-app WKWebView)

import WebKit

/// Presentation payload for the in-app social login sheet.
struct SocialLoginPresentation: Identifiable {
    let id = UUID()
    let provider: AuthenticationMethod
}

/// Stock LibreChat servers finish social login by setting httpOnly cookies in
/// the browser and redirecting to the client — there is no mobile token
/// exchange. This sheet runs the provider flow inside an in-app WKWebView,
/// then harvests the session cookies from the shared cookie store so the
/// native transport can adopt the session via a refresh.
struct InAppOAuthSheet: View {
    let profile: ServerProfile
    let provider: AuthenticationMethod
    let onSessionCookies: @MainActor ([StoredCookie]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    ContentUnavailableView(
                        "Couldn’t open sign-in",
                        systemImage: "safari",
                        description: Text("The provider page failed to load. Check the connection and try again.")
                    )
                } else {
                    let startURL = profile.baseURL.appending(path: "oauth/\(Self.route(for: provider))")
                    OAuthWebView(
                        startURL: startURL,
                        oauthPathPrefix: OAuthWebView.oauthPathPrefix(for: startURL),
                        host: profile.baseURL.host ?? "",
                        onLanding: { cookies in
                            dismiss()
                            onSessionCookies(cookies)
                        },
                        onFailure: { loadFailed = true }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("Sign in with \(Self.displayName(for: provider))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }

    }

    private static func route(for provider: AuthenticationMethod) -> String {
        switch provider {
        case .openID: "openid"
        case .email, .ldap, .saml: "openid"
        default: provider.rawValue.lowercased()
        }
    }

    private static func displayName(for provider: AuthenticationMethod) -> String {
        switch provider {
        case .openID: "OpenID Connect"
        default: provider.rawValue.capitalized
        }
    }
}

private struct OAuthWebView: UIViewRepresentable {
    let startURL: URL
    /// Path of the OAuth route up to and including `/oauth`, derived from
    /// `startURL` so deployments served beneath a subpath (`/librechat`)
    /// are recognized too.
    let oauthPathPrefix: String
    let host: String
    let onLanding: @MainActor ([StoredCookie]) -> Void
    let onFailure: @MainActor () -> Void

    static func oauthPathPrefix(for startURL: URL) -> String {
        var prefix = startURL.deletingLastPathComponent().path
        while prefix.count > 1, prefix.hasSuffix("/") {
            prefix.removeLast()
        }
        return prefix
    }

    static func isOAuthPath(_ path: String, prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: OAuthWebView
        fileprivate weak var webView: WKWebView?
        private var sawOAuthHop = false
        private var completing = false

        init(parent: OAuthWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                let isOAuthPath = OAuthWebView.isOAuthPath(url.path, prefix: parent.oauthPathPrefix)
                if isOAuthPath { sawOAuthHop = true }
                // Only the top-frame return to the deployment may adopt the
                // session: subframe navigations and duplicate redirect hops
                // must never harvest cookies or fire onLanding twice.
                if sawOAuthHop,
                   !isOAuthPath,
                   url.host?.lowercased() == parent.host.lowercased(),
                   navigationAction.targetFrame?.isMainFrame == true,
                   !completing {
                    completing = true
                    finish(webView: webView)
                    decisionHandler(.allow)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in parent.onFailure() }
        }

        private func finish(webView: WKWebView) {
            // Give the redirect response a moment to land its Set-Cookie
            // headers before reading the store.
            let callback = parent.onLanding
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let host = self.parent.host.lowercased()
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let harvested = Self.storedCookies(from: cookies, matchingHost: host)
                    Task { @MainActor in
                        callback(harvested)
                    }
                }
            }
        }

        private static func storedCookies(
            from cookies: [HTTPCookie],
            matchingHost host: String
        ) -> [StoredCookie] {
            let dotCharacters = CharacterSet(charactersIn: ".")
            return cookies.filter { cookie in
                let domain = cookie.domain
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: dotCharacters)
                    .lowercased()
                if domain.isEmpty { return false }
                return host == domain || host.hasSuffix("." + domain)
            }
            .map(StoredCookie.init)
        }
    }
}

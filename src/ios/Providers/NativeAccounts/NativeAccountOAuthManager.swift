import Foundation
import CryptoKit
import SafariServices
import UIKit
import Combine

/// These credentials are only stored through ProviderKeychainHelper, never in provider JSON.
struct NativeAccountToken: Codable, Sendable, Equatable {
    var providerType: ProviderType
    var accessToken: String
    var refreshToken: String
    var expires: Int64
    var userID: String = ""
    var machineID: String? = nil
    var deviceID: String? = nil
    var oauthHost: String? = nil
    var orgCode: String = ""
    var orgName: String = ""
    var orgRole: String = ""
    var modelFunctions: [String: String] = [:]
}

/// Small URLSession client for the vendors' control planes. No response/token logging.
struct NativeAccountHTTPClient: Sendable {
    func request(url: URL, method: String, headers: [String: String], body: Data? = nil,
                 cancellation: Bool? = nil) async throws -> (HTTPURLResponse, Data) {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (response, data)
    }
}

struct NativeAccountPKCE: Sendable {
    let verifier: String
    var challenge: String { Self.urlSafe(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func urlSafe(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func random() -> NativeAccountPKCE {
        NativeAccountPKCE(verifier: urlSafe(Data((0..<32).map { _ in UInt8.random(in: 0...255) })))
    }
}

@MainActor
final class NativeAccountOAuthManager: NSObject, ObservableObject, SFSafariViewControllerDelegate {
    static let shared = NativeAccountOAuthManager()
    @Published private(set) var isAuthenticating = false
    private var server: TraeLoopback?
    private var safari: SFSafariViewController?
    private var refreshIDs: [String: UUID] = [:]
    private var refreshTasks: [String: Task<NativeAccountToken, Error>] = [:]

    func token(instanceId: String) -> NativeAccountToken? {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: NativeAccountToken.self)
    }
    func isAuthenticated(instanceId: String) -> Bool {
        guard let token = token(instanceId: instanceId) else { return false }
        return !token.accessToken.isEmpty && !ProviderKeychainHelper.oauthNeedsReauth(instanceId: instanceId)
    }
    func maskedToken(instanceId: String) -> String? {
        token(instanceId: instanceId).map { ClaudeOAuthManager.maskToken($0.accessToken) }
    }
    func accountLabel(instanceId: String) -> String? {
        guard let token = token(instanceId: instanceId) else { return nil }
        return token.orgName.isEmpty ? (token.userID.isEmpty ? nil : token.userID) : token.orgName
    }
    func logout(instanceId: String) {
        refreshIDs.removeValue(forKey: instanceId)
        refreshTasks.removeValue(forKey: instanceId)?.cancel()
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
        objectWillChange.send()
    }
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { server?.stop() }

    func login(instanceId: String, type: ProviderType) async throws {
        guard type.isNativeAccount else { throw LLMError.providerError(message: "Unsupported account type") }
        guard !isAuthenticating else { throw LLMError.providerError(message: "Another sign-in is in progress") }
        isAuthenticating = true
        let listener = TraeLoopback(path: type == .raccoon ? RaccoonOAuth.callbackPath : TraeOAuth.callbackPath)
        server = listener
        defer {
            listener.stop(); server = nil
            safari?.dismiss(animated: true); safari = nil
            isAuthenticating = false
        }
        try Task.checkCancellation()
        try await listener.listen()
        let stored: NativeAccountToken
        if type == .raccoon {
            let state = try RaccoonOAuth.randomState()
            let page = try RaccoonOAuth.authorizeURL(state: state, redirect: listener.redirectURI)
            present(page)
            let parameters = try await wait(listener)
            try RaccoonOAuth.checkCallbackError(parameters)
            let code = try RaccoonOAuth.callbackCode(parameters, expectedState: state)
            let result = try await RaccoonOAuth.exchange(authCode: code)
            stored = NativeAccountToken(providerType: type, accessToken: result.access,
                refreshToken: result.refresh, expires: result.expires,
                orgCode: result.officeIdentity, orgName: result.officeOrgName, orgRole: result.officeOrgRole)
        } else {
            let profile = TraeOAuth.Profile.of(type.traeSite)
            let pkce = NativeAccountPKCE.random()
            let machineID = profile.deviceIdentity == .uuid ? UUID().uuidString : TraeWire.traceID() + TraeWire.traceID()
            let deviceID = profile.fixedDeviceID ?? TraeOAuth.randomDeviceID()
            let trace = UUID().uuidString
            let host = try await TraeOAuth.signInHost(profile: profile, loginTraceID: trace)
            let page = try TraeOAuth.loginURL(loginHost: host, redirect: listener.redirectURI,
                machineID: machineID, deviceID: deviceID, loginTraceID: trace,
                pkce: pkce, profile: profile)
            present(page)
            let parameters = try await wait(listener)
            try TraeOAuth.checkCallbackError(parameters)
            let callback = try TraeOAuth.callbackPayload(parameters)
            guard callback.loginTraceID.isEmpty || callback.loginTraceID == trace else {
                throw TraeOAuthError("The sign-in response belongs to another login.")
            }
            let result = try await TraeOAuth.exchange(authCode: callback.authCode, codeVerifier: pkce.verifier,
                machineID: machineID, deviceID: deviceID, profile: profile)
            stored = NativeAccountToken(providerType: type, accessToken: result.access,
                refreshToken: result.refresh, expires: result.expires,
                userID: callback.userID.isEmpty ? TraeOAuth.jwtUserID(result.access) : callback.userID,
                machineID: machineID, deviceID: deviceID, oauthHost: result.origin)
        }
        try Task.checkCancellation()
        ProviderKeychainHelper.saveOAuthToken(stored, instanceId: instanceId)
        guard token(instanceId: instanceId) == stored else {
            throw LLMError.providerError(message: "Could not save the sign-in securely. Please try again.")
        }
        objectWillChange.send()
    }

    private func wait(_ listener: TraeLoopback) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await listener.waitForCallback() }
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func present(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        let controller = SFSafariViewController(url: url)
        controller.delegate = self
        safari = controller
        top.present(controller, animated: true)
    }

    func validToken(instanceId: String, type: ProviderType, forceRefresh: Bool = false) async throws -> NativeAccountToken {
        guard let existing = token(instanceId: instanceId), existing.providerType == type,
              !ProviderKeychainHelper.oauthNeedsReauth(instanceId: instanceId) else {
            throw LLMError.invalidAPIKey(detail: "Sign in to \(type.displayName) again.")
        }
        if let flight = refreshTasks[instanceId] { return try await flight.value }
        let fresh = existing.expires == .max || Double(existing.expires) > Date().timeIntervalSince1970 * 1000 + 300_000
        if fresh && !forceRefresh { return existing }
        guard !existing.refreshToken.isEmpty else { throw LLMError.invalidAPIKey(detail: "Sign in again to renew this account.") }
        let flightID = UUID()
        let flight = Task<NativeAccountToken, Error> {
            var updated = existing
            if type == .raccoon {
                let result = try await RaccoonWire.refresh(site: .work, refreshToken: existing.refreshToken,
                    client: NativeAccountHTTPClient())
                updated.accessToken = result.access; updated.refreshToken = result.refresh.isEmpty ? existing.refreshToken : result.refresh; updated.expires = result.expires
                if !result.orgCode.isEmpty { updated.orgCode = result.orgCode }
            } else {
                let profile = TraeOAuth.Profile.of(type.traeSite)
                guard let gate = existing.oauthHost, profile.exchangeOrigins.contains(gate) else {
                    throw TraeOAuthError("The saved sign-in gateway is invalid. Sign in again.")
                }
                let result = try await TraeWire.exchangeToken(site: type.traeSite, refreshToken: existing.refreshToken,
                    userID: existing.userID, gate: gate, client: NativeAccountHTTPClient())
                updated.accessToken = result.access; updated.refreshToken = result.refresh.isEmpty ? existing.refreshToken : result.refresh; updated.expires = result.expires
            }
            try Task.checkCancellation()
            // A logout/re-login or a newer cloud credential must win over this stale flight.
            guard let current = self.token(instanceId: instanceId) else { throw CancellationError() }
            var currentIdentity = current
            var previousIdentity = existing
            currentIdentity.modelFunctions = [:]
            previousIdentity.modelFunctions = [:]
            if currentIdentity != previousIdentity { return current }
            updated.modelFunctions = current.modelFunctions
            ProviderKeychainHelper.saveOAuthToken(updated, instanceId: instanceId)
            guard self.token(instanceId: instanceId) == updated else {
                throw LLMError.providerError(message: "Could not securely save the renewed account.")
            }
            self.objectWillChange.send()
            return updated
        }
        refreshTasks[instanceId] = flight
        refreshIDs[instanceId] = flightID
        defer {
            if refreshIDs[instanceId] == flightID {
                refreshTasks.removeValue(forKey: instanceId)
                refreshIDs.removeValue(forKey: instanceId)
            }
        }
        return try await flight.value
    }
}

extension ProviderType {
    var isNativeAccount: Bool { self == .trae || self == .traeCN || self == .raccoon }
    var traeSite: TraeSite { self == .traeCN ? .china : .international }
    var nativeAccountBase: String {
        self == .raccoon ? RaccoonSite.work.apiBase + RaccoonSite.work.llmPrefix : traeSite.origin(base: nil)
    }
}

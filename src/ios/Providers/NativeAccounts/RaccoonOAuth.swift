import Foundation
import Darwin

enum RaccoonOAuth {
    // MARK: - The client's own values

    static let origin = "https://xiaohuanxiong.com"
    static let authorizePath = "/code/authorize"
    /// The web-auth family: sign-in by authorisation code, and renewal.
    static let authBase = "https://xiaohuanxiong.com/api/web/auth/v1"
    static let loginSource = "desktop"
    /// The name the page reports this client as. The desktop client's own.
    static let appName = "办公小浣熊客户端"
    /// The address the page redirects to; nothing here binds it.
    static let callbackScheme = "office-raccoon"
    static let callbackHost = "auth"
    static let callbackPath = "/auth/callback"

    /// The credential's extras, read back by `RaccoonCredential`.
    static let officeIdentityExtra = "officeIdentity"
    static let officeOrgNameExtra = "officeOrgName"
    static let officeOrgRoleExtra = "officeOrgRole"

    /// `https://xiaohuanxiong.com/code/authorize?login_source=desktop&appname=…&state=…`
    ///
    /// The page answers `307` to `/authorize`; the redirect is left to the
    /// browser, since the page it lands on is the one that signs the account in.
    /// `appname` is Chinese and must be percent-encoded: built through
    /// `URLComponents` rather than a string, which encodes it and the callback
    /// address's own `://` correctly.
    static func authorizeURL(state: String, redirect: String) throws -> URL {
        var components = URLComponents(string: origin + authorizePath)
        components?.queryItems = [
            URLQueryItem(name: "login_source", value: loginSource),
            URLQueryItem(name: "appname", value: appName),
            URLQueryItem(name: "state", value: state),
            // Without these the page navigates to `office-raccoon://auth/callback`,
            // a scheme Safari has no handler for: the page shows the signed-in
            // view and never leaves it, and the code is lost. Naming the
            // loopback makes the page deliver the code over http instead, which
            // is the shape `desktop_callback=loopback` selects.
            URLQueryItem(name: "redirect", value: redirect),
            URLQueryItem(name: "desktop_callback", value: "loopback"),
        ]
        guard let url = components?.url else {
            throw RaccoonOAuthError("The Raccoon sign-in address could not be built.")
        }
        return url
    }

    // MARK: - The callback

    /// The authorisation code the page redirected with.
    ///
    /// The state is compared when the page sent one: a redirect that names
    /// another state is not this sign-in's, and taking its code would sign
    /// the account in to a flow it did not start. A redirect that omits the
    /// state is taken, since some clients drop it, and the code itself is
    /// single-use.
    static func callbackCode(_ parameters: [String: String], expectedState: String) throws -> String {
        let code = (parameters["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw RaccoonOAuthError("The Raccoon page did not return a sign-in code. Sign in again.")
        }
        if let state = parameters["state"], !state.isEmpty, state != expectedState {
            throw RaccoonOAuthError("The Raccoon page returned another sign-in's code. Sign in again.")
        }
        return code
    }

    // MARK: - The exchange

    struct Exchanged: Sendable {
        var access: String
        var refresh: String
        var officeIdentity: String
        var officeOrgName: String
        var officeOrgRole: String
        /// Unix ms of the access token's expiry; `.max` when it says none.
        var expires: Int64
    }

    /// `POST {authBase}/login_with_authorization_code`, the body one field.
    ///
    /// `200035` is the code having been spent already; any other non-zero
    /// code is the gate's own refusal, reported in its words.
    static func exchange(
        authCode: String,
        client: NativeAccountHTTPClient = NativeAccountHTTPClient(),
        authBase: String = RaccoonOAuth.authBase,
    ) async throws -> Exchanged {
        guard let url = URL(string: authBase + "/login_with_authorization_code") else {
            throw RaccoonOAuthError("The Raccoon token address could not be read.")
        }
        let body: [String: Any] = ["authorization_code": authCode]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw RaccoonOAuthError("The Raccoon sign-in request could not be built.")
        }
        let (response, answer) = try await client.request(
            url: url,
            method: "POST",
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: data,
        )
        guard answer.count <= 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        else {
            throw RaccoonOAuthError("The Raccoon sign-in answer could not be read (HTTP \(response.statusCode)).")
        }
        if let failure = envelopeError(root) {
            throw RaccoonOAuthError(failure == "200035"
                ? "This Raccoon sign-in code was already used. Sign in again."
                : "The Raccoon sign-in was refused: \(failure)")
        }
        guard response.statusCode == 200 else {
            throw RaccoonOAuthError("The Raccoon sign-in failed (HTTP \(response.statusCode)).")
        }
        let result = (root["data"] ?? root["Data"]) as? [String: Any] ?? root
        guard let access = firstString(result, ["access_token", "accessToken"]), !access.isEmpty else {
            throw RaccoonOAuthError("The Raccoon sign-in returned no token. Sign in again.")
        }
        return Exchanged(
            access: access,
            refresh: firstString(result, ["refresh_token", "refreshToken"]) ?? "",
            officeIdentity: firstString(result, ["office_identity", "officeIdentity"]) ?? "",
            officeOrgName: firstString(result, ["office_org_name", "officeOrgName"]) ?? "",
            officeOrgRole: firstString(result, ["office_org_role", "officeOrgRole"]) ?? "",
            expires: expiry(result["expires_at"] ?? result["expiresAt"]),
        )
    }

    // MARK: - Small helpers

    /// A port nothing is listening on, above 1023 as the page requires.
    ///
    /// Bound once and released: the listener takes it a moment later, and the
    /// window between the two is the same one every browser sign-in here has.
    static func freePort() throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RaccoonOAuthError("The Raccoon sign-in could not reserve a local port.")
        }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw RaccoonOAuthError("The Raccoon sign-in could not reserve a local port.")
        }
        var resolved = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &size)
            }
        }
        guard named == 0, resolved.sin_port != 0 else {
            throw RaccoonOAuthError("The Raccoon sign-in could not reserve a local port.")
        }
        return UInt16(bigEndian: resolved.sin_port)
    }

    /// Thirty-two random bytes as sixty-four hexadecimal digits: the page
    /// accepts a loopback redirect only with a state of exactly that shape.
    static func randomState() throws -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255, using: &generator)) }.joined()
    }

    /// `code` is a number on this gate's envelopes; `0` is success.
    static func envelopeError(_ root: [String: Any]) -> String? {
        for key in ["code", "Code"] {
            guard let value = root[key] else { continue }
            let code: Int? = if let number = value as? NSNumber {
                number.intValue
            } else if let text = value as? String {
                Int(text)
            } else {
                nil
            }
            guard let code, code != 0 else { continue }
            return String(code)
        }
        return nil
    }

    /// The first non-empty string among `keys`, numbers included as text.
    static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    /// `expires_at` is Unix seconds or milliseconds; an entry that says
    /// neither never lapses.
    static func expiry(_ raw: Any?) -> Int64 {
        guard let number = raw as? NSNumber, number.doubleValue > 0 else { return .max }
        let milliseconds = Int64(number.doubleValue)
        return milliseconds > 1_000_000_000_000 ? milliseconds : milliseconds * 1000
    }

    /// The user leaving the page ends the sign-in `cancelled`, as everywhere
    /// else.
    static func checkCallbackError(_ parameters: [String: String]) throws {
        guard let error = parameters["error"], !error.isEmpty else { return }
        if error == "access_denied" { throw CancellationError() }
        let description = parameters["error_description"].map { ": \($0)" } ?? ""
        throw RaccoonOAuthError("Raccoon \(error)\(description)")
    }

}

struct RaccoonOAuthError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

import Foundation
import CryptoKit
import Network

enum TraeOAuth {
    // MARK: - One build's values

    /// How a build's device identity is made.
    enum DeviceIdentity: Sendable {
        /// A fresh 64-hex machine id (the China client's `machine_id`).
        case hex64
        /// A UUID, which the international client sends as its `machine_id`.
        case uuid
    }

    /// Everything one build's flow needs that the other's does not share.
    struct Profile: Sendable {
        let site: TraeSite
        /// Where the sign-in page is, when it is known without asking. Nil
        /// asks `GetLoginGuidance` first, as the international client does:
        /// its page is not one fixed host.
        let fixedLoginHost: String?
        /// The gates to ask for a sign-in host. Empty for a build whose page
        /// is fixed.
        let guidanceURLs: [String]
        let pluginVersion: String
        let appVersion: String
        let appType: String
        let deviceBrand: String
        /// The `x_device_type` the page is told, which is also
        /// `DeviceInfo.OSInfo`.
        let osInfo: String
        let osVersion: String
        /// The page's `channel_name`; nil sends none, which the
        /// international client does.
        let channelName: String?
        let deviceIdentity: DeviceIdentity
        /// A device id the client sends as a constant; nil generates one.
        let fixedDeviceID: String?
        /// The account gates this build's exchange may use, in order. A
        /// sign-in only reaches the one that serves its region, so every one
        /// is tried before the sign-in is called failed.
        let exchangeOrigins: [String]

        static let china = Profile(
            site: .china,
            fixedLoginHost: "https://www.trae.cn",
            guidanceURLs: [],
            pluginVersion: "2.3.83560",
            appVersion: "3.3.100",
            appType: "stable",
            deviceBrand: "",
            osInfo: "windows",
            osVersion: "Windows 10 Home",
            channelName: "common",
            deviceIdentity: .hex64,
            fixedDeviceID: nil,
            exchangeOrigins: ["https://api.trae.cn"],
        )

        static let international = Profile(
            site: .international,
            fixedLoginHost: nil,
            guidanceURLs: [
                "https://api.marscode.com/cloudide/api/v3/trae/GetLoginGuidance",
                "https://api.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
                "https://www.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
            ],
            pluginVersion: "local",
            appVersion: "3.5.54",
            appType: "stable",
            deviceBrand: "unknown",
            osInfo: "unknown",
            osVersion: "unknown",
            channelName: nil,
            deviceIdentity: .uuid,
            fixedDeviceID: "0",
            // The gates the client's `product.json` publishes for its
            // account service: the default, Singapore and the US TTP gate,
            // then the ones the API's own hosts serve.
            exchangeOrigins: [
                "https://grow-normal.trae.ai",
                "https://growsg-normal.trae.ai",
                "https://grow-normal.traeapi.us",
                "https://api.marscode.com",
                "https://api.trae.ai",
                "https://www.trae.ai",
            ],
        )

        static func of(_ site: TraeSite) -> Profile {
            site == .china ? .china : .international
        }
    }

    // MARK: - Shared paths

    static let authorizationPath = "/authorization"
    static let callbackPath = "/authorize"
    /// The sign-in's `ExchangeToken`, which is not the renewal's.
    static let authExchangePath = "/trae/api/v3/oauth/ExchangeToken"

    static let clientID = "ono9krqynydwx5"
    static let loginRedirect = "0"
    static let platformCode = "IDE_PC"
    static let deviceType = "PC"

    // MARK: - The credential's extras

    /// The account's id, which the renewal body carries as `UserID` and
    /// `TraeCredential` reads back.
    static let userIDExtra = "userId"
    /// `Result.BoundDeviceID`: the device the service bound this sign-in to.
    static let boundDeviceIDExtra = "deviceId"
    /// The device id this sign-in registered, which the client sends as
    /// `x-device-id` on its own account calls.
    static let loginDeviceIDExtra = "checkinDeviceId"
    /// The machine id this sign-in sent.
    static let machineIDExtra = "machineId"
    /// The gate that accepted this sign-in, which its renewals go to: the
    /// international build has several, and only one serves the account.
    static let oauthHostExtra = "oauthHost"

    /// Where this build's sign-in page is: the host it publishes, or the one
    /// `GetLoginGuidance` names.
    ///
    /// The China build's page is one host and it does not ask. The
    /// international build's is not, so it asks and takes the answer; when
    /// no gate answers, the sign-in says so rather than opening a page that
    /// would not know the client.
    static func signInHost(
        profile: Profile,
        loginTraceID: String,
        client: NativeAccountHTTPClient = NativeAccountHTTPClient(),
    ) async throws -> String {
        if let fixed = profile.fixedLoginHost { return fixed }
        var failures: [String] = []
        for address in profile.guidanceURLs {
            guard let url = URL(string: address) else { continue }
            do {
                let body = try JSONSerialization.data(withJSONObject: [
                    "loginTraceID": loginTraceID,
                    "login_trace_id": loginTraceID,
                ])
                let (response, data) = try await client.request(
                    url: url,
                    method: "POST",
                    headers: ["Accept": "application/json", "Content-Type": "application/json"],
                    body: body,
                )
                guard response.statusCode == 200, data.count <= 1024 * 1024,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let host = guidanceHost(root), !host.isEmpty
                else {
                    failures.append("\(address): no sign-in host")
                    continue
                }
                return host
            } catch {
                failures.append("\(address): \(error.localizedDescription)")
            }
        }
        throw TraeOAuthError(
            "The Trae sign-in page could not be found. \(failures.joined(separator: " · "))",
        )
    }

    /// `Result.LoginHost`, whichever spelling the gate answers with.
    static func guidanceHost(_ root: [String: Any]) -> String? {
        for key in ["Result", "result", "data"] {
            if let layer = root[key] as? [String: Any],
               let host = firstString(layer, ["LoginHost", "loginHost", "LoginURL", "loginUrl"])
            {
                return host
            }
        }
        return firstString(root, ["LoginHost", "loginHost", "loginUrl"])
    }

    /// `<host>/authorization?<query>`, its parameters in the order the client
    /// sends them so a capture can be compared line for line. `URLComponents`
    /// does the percent-encoding: the callback address carries `://` and `:`
    /// and a hand-built query loses them.
    static func loginURL(
        loginHost: String,
        redirect: String,
        machineID: String,
        deviceID: String,
        loginTraceID: String,
        pkce: NativeAccountPKCE,
        profile: Profile,
    ) throws -> URL {
        guard let origin = origin(of: loginHost) else {
            throw TraeOAuthError("The Trae sign-in page address could not be read.")
        }
        var components = URLComponents(string: origin + authorizationPath)
        var items = [
            URLQueryItem(name: "login_version", value: "1"),
            URLQueryItem(name: "auth_from", value: "trae"),
            URLQueryItem(name: "login_channel", value: "native_ide"),
            URLQueryItem(name: "plugin_version", value: profile.pluginVersion),
            URLQueryItem(name: "auth_type", value: "local"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect", value: loginRedirect),
            URLQueryItem(name: "login_trace_id", value: loginTraceID),
            URLQueryItem(name: "auth_callback_url", value: redirect),
            URLQueryItem(name: "machine_id", value: machineID),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "x_device_id", value: deviceID),
            URLQueryItem(name: "x_machine_id", value: machineID),
            URLQueryItem(name: "x_device_brand", value: profile.deviceBrand),
            URLQueryItem(name: "x_device_type", value: profile.osInfo),
            URLQueryItem(name: "x_os_version", value: profile.osVersion),
            URLQueryItem(name: "x_env", value: ""),
            URLQueryItem(name: "x_app_version", value: profile.appVersion),
            URLQueryItem(name: "x_app_type", value: profile.appType),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // The international client sends no channel name; the China one
        // sends `common`, and a page given one too few parameters stops at
        // "authenticating" without saying why.
        if let channelName = profile.channelName {
            items.append(URLQueryItem(name: "channel_name", value: channelName))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw TraeOAuthError("The Trae sign-in address could not be built.")
        }
        return url
    }

    // MARK: - The callback

    /// What the page called back with.
    struct Callback: Sendable, Equatable {
        /// `authCodeInfo.AuthCode`, exchanged for the token.
        var authCode: String
        /// `userInfo.UserID`, empty when the page sent no user block.
        var userID: String
        /// `loginTraceID`, the value this sign-in generated.
        var loginTraceID: String
        /// `loginHost`: the gate this account belongs to, on the build that
        /// has more than one. Empty on the China build.
        var loginHost: String
    }

    /// Reads `authCodeInfo` out of the callback's query.
    ///
    /// The page is dual-mode: with a `code_challenge` it hands back an
    /// `authCodeInfo` for the client to exchange, without one it calls
    /// `GetRefreshToken` itself and hands back `refreshToken`. This flow
    /// always asks for NativeAccountPKCE, so a callback without an auth code is a failure
    /// the user can act on rather than a second flow.
    static func callbackPayload(_ parameters: [String: String]) throws -> Callback {
        guard let raw = parameters["authCodeInfo"], !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let authCode = firstString(object, ["AuthCode", "authCode"]), !authCode.isEmpty
        else {
            throw TraeOAuthError("The Trae page did not return a sign-in code. Sign in again.")
        }
        var userID = ""
        if let raw = parameters["userInfo"], !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            userID = firstString(object, ["UserID", "UserId", "userId"]) ?? ""
        }
        return Callback(
            authCode: authCode,
            userID: userID,
            loginTraceID: parameters["loginTraceID"] ?? "",
            loginHost: firstString(parameters, ["loginHost", "login_host", "LoginHost"]) ?? "",
        )
    }

    // MARK: - The exchange

    struct Exchanged: Sendable {
        var access: String
        var refresh: String
        var boundDeviceID: String
        /// Unix ms of the access token's expiry; `.max` when it says none.
        var expires: Int64
        /// The gate that answered, which the credential keeps for renewal.
        var origin: String
    }

    /// `POST <gate>/trae/api/v3/oauth/ExchangeToken`, the body exactly the
    /// five fields the client sends. No `ClientSecret` and no `DeviceProof`:
    /// both belong to the renewal path, and this endpoint refuses them.
    ///
    /// Every gate in the build's list is tried, and only the one that answers
    /// ends the call. The builds' accounts do not cross over, so an answer
    /// naming `20101` is reported as signing in to the wrong build rather
    /// than as a failed exchange.
    static func exchange(
        authCode: String,
        codeVerifier: String,
        machineID: String,
        deviceID: String,
        profile: Profile,
        client: NativeAccountHTTPClient = NativeAccountHTTPClient(),
        exchangeOrigins: [String]? = nil,
    ) async throws -> Exchanged {
        let body: [String: Any] = [
            "ClientID": clientID,
            "AuthCode": authCode,
            "CodeVerifier": codeVerifier,
            "DeviceInfo": deviceInfo(
                machineID: machineID,
                deviceID: deviceID,
                profile: profile,
            ),
            "IDEVersion": profile.appVersion,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw TraeOAuthError("The Trae sign-in request could not be built.")
        }

        var failures: [String] = []
        var wrongBuild = false
        for origin in exchangeOrigins ?? profile.exchangeOrigins {
            guard let url = URL(string: origin + authExchangePath) else { continue }
            do {
                let (response, answer) = try await client.request(
                    url: url,
                    method: "POST",
                    headers: [
                        "Accept": "application/json",
                        "Content-Type": "application/json",
                        "x-cloudide-token": "",
                    ],
                    body: payload,
                )
                guard answer.count <= 1024 * 1024,
                      let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
                else {
                    failures.append("\(origin): unreadable answer (HTTP \(response.statusCode))")
                    continue
                }
                if let failure = envelopeError(root) {
                    if failure.contains("20101")
                        || failure.lowercased().contains("refresh token is invalid")
                    {
                        wrongBuild = true
                    }
                    failures.append("\(origin): \(failure)")
                    continue
                }
                guard response.statusCode == 200 else {
                    failures.append("\(origin): HTTP \(response.statusCode)")
                    continue
                }
                let result = (root["Result"] ?? root["result"]) as? [String: Any] ?? root
                guard let access = firstString(
                    result,
                    ["Token", "token", "AccessToken", "accessToken", "access_token"],
                ), !access.isEmpty
                else {
                    failures.append("\(origin): no token")
                    continue
                }
                return Exchanged(
                    access: access,
                    refresh: firstString(result, ["RefreshToken", "refreshToken", "refresh_token"]) ?? "",
                    boundDeviceID: firstString(result, ["BoundDeviceID", "BoundDeviceId", "boundDeviceId"]) ?? "",
                    expires: expiry(
                        result["TokenExpireAt"] ?? result["tokenExpireAt"]
                            ?? result["ExpiresAt"] ?? result["expiresAt"],
                    ),
                    origin: origin,
                )
            } catch {
                failures.append("\(origin): \(error.localizedDescription)")
            }
        }
        if wrongBuild {
            throw TraeOAuthError(
                profile.site == .china
                    ? "This account belongs to the international build. Sign in to Trae instead."
                    : "This account belongs to the China build. Sign in to Trae CN instead.",
            )
        }
        throw TraeOAuthError("The Trae sign-in could not be completed. \(failures.joined(separator: " · "))")
    }

    /// The twelve fields the client sends, in its order. The ones it takes
    /// from the machine (brand, CPU, model) are empty rather than guessed,
    /// and the public key is a real one: the service validates it.
    static func deviceInfo(machineID: String, deviceID: String, profile: Profile) -> [String: Any] {
        [
            "DeviceID": deviceID,
            "MachineID": machineID,
            "PlatformCode": platformCode,
            "DeviceType": deviceType,
            "DeviceName": ProcessInfo.processInfo.hostName,
            "DeviceModel": profile.deviceBrand,
            "ClientVersion": profile.appVersion,
            "DevicePublicKey": P256.Signing.PrivateKey().publicKey.pemRepresentation,
            "DeviceBrand": profile.deviceBrand,
            "DeviceCPU": "",
            "OSInfo": profile.osInfo,
            "OSVersion": profile.osVersion,
        ]
    }

    // MARK: - Small helpers

    /// Sixteen decimal digits, the shape the China page checks for its
    /// `device_id` and the id the client sends as `x-device-id`.
    static func randomDeviceID() -> String {
        (0 ..< 16).map { _ in String(Int.random(in: 0 ... 9)) }.joined()
    }

    /// `https://host[:port]` of an address a page or a gate named; nil when
    /// it names no host.
    static func origin(of address: String) -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty
        else { return nil }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard let port = components.port else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// The user id a JWT carries, for a callback whose `userInfo` was absent.
    static func jwtUserID(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return "" }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "" }
        return firstString(object, ["user_id", "userId", "uid", "sub", "UserID"]) ?? ""
    }

    /// `TokenExpireAt` is Unix seconds or milliseconds; an entry that says
    /// neither never lapses.
    static func expiry(_ raw: Any?) -> Int64 {
        guard let number = raw as? NSNumber, number.doubleValue > 0 else { return .max }
        let milliseconds = Int64(number.doubleValue)
        return milliseconds > 1_000_000_000_000 ? milliseconds : milliseconds * 1000
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

    static func firstString(_ parameters: [String: String], _ keys: [String]) -> String? {
        for key in keys where parameters[key]?.isEmpty == false {
            return parameters[key]
        }
        return nil
    }

    /// Trae's `{Code, Message}` envelope, either spelling; a body with no
    /// code is a success, which some of its services answer with.
    static func envelopeError(_ root: [String: Any]) -> String? {
        for key in ["Code", "code", "ErrCode", "errCode"] {
            guard let value = root[key] else { continue }
            let code: Int? = if let number = value as? NSNumber {
                number.intValue
            } else if let text = value as? String {
                Int(text)
            } else {
                nil
            }
            guard let code, code != 0 else { continue }
            let message = firstString(root, ["Message", "message", "Msg", "msg", "ErrMsg", "errMsg"])
            return message ?? "code \(code)"
        }
        if let error = root["Error"] as? String ?? root["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }

    /// `access_denied` is the user leaving the page, which ends the sign-in
    /// `cancelled` rather than `failed`.
    static func checkCallbackError(_ parameters: [String: String]) throws {
        guard let error = firstString(parameters, ["error", "error_code", "errorCode"]) else { return }
        if error == "access_denied" { throw CancellationError() }
        let description = firstString(parameters, ["error_description", "error_desc", "message"]) ?? ""
        throw TraeOAuthError(
            "Trae \(error)\(description.isEmpty ? "" : ": \(description)")",
        )
    }

}

struct TraeOAuthError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class TraeLoopback: @unchecked Sendable {
    private let callbackPath: String
    init(path: String = TraeOAuth.callbackPath) { callbackPath = path }
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var listeningContinuation: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var answered: Result<[String: String], Error>?
    private var stopped = false

    var redirectURI: String {
        "http://127.0.0.1:\(lock.withLock { boundPort ?? 0 })\(callbackPath)"
    }

    func listen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TraeOAuthError("The Trae sign-in could not open its local address.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let refused: Bool = lock.withLock {
                if stopped { return true }
                listeningContinuation = continuation
                self.listener = listener
                return false
            }
            if refused {
                continuation.resume(throwing: CancellationError())
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resolveListening(port: listener.port?.rawValue, error: nil)
                case .failed:
                    self.resolveListening(
                        port: nil,
                        error: TraeOAuthError("The Trae sign-in could not open its local address."),
                    )
                case .cancelled:
                    self.resolveListening(port: nil, error: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: DispatchQueue(label: "com.openminis.trae-loopback"))
        }
    }

    private func resolveListening(port: UInt16?, error: Error?) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let continuation = listeningContinuation else { return nil }
            listeningContinuation = nil
            if let port { boundPort = port }
            return continuation
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let early: Result<[String: String], Error>? = lock.withLock {
                    if let answered { return answered }
                    if stopped || Task.isCancelled { return .failure(CancellationError()) }
                    waiter = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            stop()
        }
    }

    func stop() {
        let (continuation, listening, listener): (
            CheckedContinuation<[String: String], Error>?,
            CheckedContinuation<Void, Error>?,
            NWListener?,
        ) = lock.withLock {
            stopped = true
            let continuation = waiter
            let listening = listeningContinuation
            let listener = self.listener
            waiter = nil
            listeningContinuation = nil
            self.listener = nil
            return (continuation, listening, listener)
        }
        listener?.cancel()
        listening?.resume(throwing: CancellationError())
        continuation?.resume(throwing: CancellationError())
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.openminis.trae-connection"))
        receive(connection, collected: Data())
    }

    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self else {
                connection.cancel()
                return
            }
            var collected = collected
            if let data { collected.append(data) }
            // The head ends the request: a redirect carries no body.
            if let separator = collected.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: collected[..<separator.lowerBound], as: UTF8.self)
                respond(connection, to: head)
                return
            }
            if ended || error != nil || collected.count > 65536 {
                connection.cancel()
                return
            }
            receive(connection, collected: collected)
        }
    }

    private func respond(_ connection: NWConnection, to head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.first ?? ""
        let target = parts.count > 1 ? parts[1] : "/"
        let components = URLComponents(string: "http://127.0.0.1" + target)
        let path = components?.path ?? ""
        var parameters: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }

        // A preflight is answered before the path is judged: it is the same
        // address, and a 404 there reads as "not reachable" to the browser.
        if method == "OPTIONS" {
            write(connection, status: "204 No Content", body: "")
            return
        }
        guard path == callbackPath else {
            write(connection, status: "404 Not Found", body: "Not found")
            return
        }
        // Only a request that carries what this page sends ends the sign-in.
        // Anything else (a probe, a stray tab) is answered and the flow goes
        // on waiting, rather than stranding the user mid-sign-in.
        guard parameters["authCodeInfo"] != nil || parameters["refreshToken"] != nil
            || parameters["code"] != nil || parameters["error"] != nil
        else {
            write(connection, status: "400 Bad Request", body: "No sign-in payload")
            return
        }
        write(connection, status: "200 OK", body: "<!doctype html><meta charset=utf-8><p>Signed in. Return to Minis.</p>")
        resolve(.success(parameters))
    }

    private func write(_ connection: NWConnection, status: String, body: String) {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET,POST,OPTIONS\r\n"
            + "Access-Control-Allow-Headers: content-type\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(Data(bytes))
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resolve(_ result: Result<[String: String], Error>) {
        let continuation: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard answered == nil else { return nil }
            answered = result
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

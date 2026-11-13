import Flutter
import CShieldEmbedded
import Foundation

/// Mirrors SslBridge.kt (android) — keep both in sync.
final class SslBridge {

    /// The URLSession shared by all `ssl.httpRequest` calls. Its delegate is the native SDK's
    /// SINGLE `CShieldTrustManager` (multi-host), so one session serves every pinned host and
    /// connections are reused.
    private lazy var pinnedSession: URLSession = CShieldSSL.urlSession()

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "ssl.configure":          handleConfigure(args: args, result: result)
        case "ssl.updatePins":         handleUpdatePins(args: args, result: result)
        case "ssl.isConfigured":       result(CShieldSSL.isConfigured())
        case "ssl.checkServerTrusted": handleCheckServerTrusted(args: args, result: result)
        case "ssl.httpRequest":        handleHttpRequest(args: args, result: result)
        default:                       result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - ssl.configure / ssl.updatePins (mirror SslBridge.kt)

    private func handleConfigure(args: [String: Any], result: @escaping FlutterResult) {
        // Multi-host: prefer the `pinsByHost` map (host pattern → pins). The legacy arguments
        // (`pins` + `hostname`) stay supported by wrapping them into a one-entry map. The native
        // iOS SDK supports real multi-host pinning (exact / `*.` / `**.`).
        var pinsByHost: [String: [String]] = [:]
        if let raw = args["pinsByHost"] as? [String: Any] {
            for (host, value) in raw {
                guard let pins = value as? [String] else { result(invalidArg("pinsByHost[\(host)] must be a list of pins")); return }
                pinsByHost[host] = pins
            }
        }
        if pinsByHost.isEmpty, let pins = args["pins"] as? [String], let hostname = args["hostname"] as? String {
            pinsByHost[hostname] = pins
        }
        guard !pinsByHost.isEmpty else { result(invalidArg("pinsByHost (or pins+hostname) required")); return }

        // Sealed by default; the app passes allowRuntimeUpdates = true if it needs to rotate pins
        // at runtime.
        let allowRuntimeUpdates = args["allowRuntimeUpdates"] as? Bool ?? false
        do {
            try CShieldSSL.configure(pinsByHost: pinsByHost, allowRuntimeUpdates: allowRuntimeUpdates)
            result(nil)
        } catch {
            result(mapConfigError(error))
        }
    }

    private func handleUpdatePins(args: [String: Any], result: @escaping FlutterResult) {
        guard let pins = args["pins"] as? [String] else { result(invalidArg("pins required")); return }
        guard let hostname = args["hostname"] as? String else { result(invalidArg("hostname required")); return }
        do {
            // Merged into the current configuration (like addPins on Android). Only works when
            // configured with allowRuntimeUpdates = true.
            try CShieldSSL.updatePins(pins: pins, hostname: hostname)
            result(nil)
        } catch {
            result(mapConfigError(error))
        }
    }

    /// Same mapping as SslBridge.kt: sealed → `ssl_not_configured`; malformed host or pin →
    /// `invalid_argument`.
    private func mapConfigError(_ error: Error) -> FlutterError {
        switch error as? CShieldSSLError {
        case .sealed?:
            return FlutterError(code: CShieldErrorCode.sslNotConfigured, message: error.localizedDescription, details: nil)
        case .invalidConfiguration(let message)?:
            return FlutterError(code: CShieldErrorCode.invalidArgument, message: message, details: nil)
        default:
            return FlutterError(code: CShieldErrorCode.nativeError, message: error.localizedDescription, details: nil)
        }
    }

    // MARK: - ssl.httpRequest

    /// Performs an HTTPS request through `CShieldSSL.urlSession()`, whose
    /// URLSession delegate (`CShieldTrustManager`) enforces certificate pinning
    /// at the TLS layer over the FULL chain.
    ///
    /// Flutter's Dart adapter (CShieldNativeHttpAdapter) delegates the pinned
    /// host's requests here so Flutter can match intermediate/root pins — which
    /// pure-Dart networking (leaf-only) cannot.
    private func handleHttpRequest(args: [String: Any], result: @escaping FlutterResult) {
        guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
            result(invalidArg()); return
        }
        guard CShieldSSL.isConfigured() else {
            result(FlutterError(code: CShieldErrorCode.sslNotConfigured,
                                message: "CShieldSSL not configured", details: nil))
            return
        }

        let method = (args["method"] as? String ?? "GET").uppercased()
        let headers = args["headers"] as? [String: String] ?? [:]
        let body = (args["body"] as? FlutterStandardTypedData)?.data
        let followRedirects = args["followRedirects"] as? Bool ?? true

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body = body { request.httpBody = body }
        if let receiveTimeoutMs = args["receiveTimeoutMs"] as? Int, receiveTimeoutMs > 0 {
            request.timeoutInterval = Double(receiveTimeoutMs) / 1000.0
        }

        // NOTE: URLSession follows redirects by default; `followRedirects == false`
        // is best-effort only (honoring it would require a task-level delegate).
        _ = followRedirects

        // MethodChannel results must be delivered on the main thread; URLSession
        // completions run on a background queue.
        func reply(_ value: Any?) { DispatchQueue.main.async { result(value) } }

        let task = pinnedSession.dataTask(with: request) { data, response, error in
            if let error = error {
                let nsError = error as NSError
                // URLSession surfaces a pin/trust failure as a TLS cancel.
                let isTrustFailure = nsError.domain == NSURLErrorDomain
                    && (nsError.code == NSURLErrorCancelled
                        || nsError.code == NSURLErrorServerCertificateUntrusted
                        || nsError.code == NSURLErrorSecureConnectionFailed)
                reply(FlutterError(
                    code: isTrustFailure ? CShieldErrorCode.sslPinMismatch : CShieldErrorCode.nativeError,
                    message: error.localizedDescription, details: nil))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                reply(FlutterError(code: CShieldErrorCode.nativeError,
                                   message: "Non-HTTP response", details: nil))
                return
            }

            var headerMap = [String: [String]]()
            for (key, value) in httpResponse.allHeaderFields {
                headerMap["\(key)"] = ["\(value)"]
            }
            let payload: [String: Any?] = [
                "statusCode": httpResponse.statusCode,
                "reasonPhrase": HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                "headers": headerMap,
                "body": FlutterStandardTypedData(bytes: data ?? Data()),
            ]
            reply(payload)
        }
        task.resume()
    }

    // MARK: - ssl.checkServerTrusted

    /// Verifies a single leaf certificate (base64 DER) for `host` with the native
    /// `CShieldSSL.verifyPin`, using the same logic as `CShieldSSL.verifyPin` on Android: the pins
    /// of THIS host (multi-host); with a full chain it also runs system CA validation, with only a
    /// leaf it checks the certificate structure (validity period + hostname) and compares the leaf
    /// pin. Runs off the main thread because SecTrust may touch the network (to fetch
    /// intermediates).
    private func handleCheckServerTrusted(args: [String: Any], result: @escaping FlutterResult) {
        guard let certDerBase64 = args["certDer"] as? String,
              let certData = Data(base64Encoded: certDerBase64, options: .ignoreUnknownCharacters),
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            result(invalidArg()); return
        }
        let host = args["host"] as? String ?? ""

        guard CShieldSSL.isConfigured() else {
            result(FlutterError(code: CShieldErrorCode.sslNotConfigured,
                                message: "CShieldSSL not configured",
                                details: nil))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let trusted = CShieldSSL.verifyPin(host: host, certificates: [cert])
            DispatchQueue.main.async { result(trusted) }
        }
    }

    private func invalidArg(_ message: String = "Missing or invalid arguments") -> FlutterError {
        FlutterError(code: CShieldErrorCode.invalidArgument, message: message, details: nil)
    }
}

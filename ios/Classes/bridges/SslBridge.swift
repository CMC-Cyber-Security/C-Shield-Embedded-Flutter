import Flutter
import CShieldEmbedded
import Foundation

/// Mirrors SslBridge.kt (android) — keep both in sync.
final class SslBridge {

    // Cached when ssl.configure / ssl.updatePins is called so that
    // handleCheckServerTrusted can access pins without modifying the iOS SDK.
    private var cachedPins: [String] = []
    private var cachedHostname: String = ""

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "ssl.configure":
            // Dart gửi `pinsByHost` (map host→pins) + `allowRuntimeUpdates` (R5/H-3), KHÔNG phải
            // `pins`+`hostname` cũ → trước đây iOS trả invalidArgument. Native iOS `CShieldSSL` hiện
            // CHỈ single-host nên cấu hình theo từng entry của map (app pin 1 host — demo — là đủ;
            // nhiều host thì native giữ host cuối, cần nâng cấp native multi-host sau). `allowRuntimeUpdates`:
            // iOS chưa có cơ chế auto-seal → bỏ qua. Giữ tương thích đường cũ `pins`+`hostname`.
            if let pinsByHost = args["pinsByHost"] as? [String: Any], !pinsByHost.isEmpty {
                var configured = false
                cachedPins = []
                for (host, value) in pinsByHost {
                    guard let pins = value as? [String], !host.isEmpty else { continue }
                    CShieldSSL.configure(pins: pins, hostname: host)
                    cachedPins.append(contentsOf: pins)
                    if cachedHostname.isEmpty { cachedHostname = host }
                    configured = true
                }
                configured ? result(nil) : result(invalidArg())
            } else if let pins = args["pins"] as? [String], let hostname = args["hostname"] as? String {
                cachedPins = pins
                cachedHostname = hostname
                CShieldSSL.configure(pins: pins, hostname: hostname)
                result(nil)
            } else {
                result(invalidArg())
            }
        case "ssl.updatePins":
            guard let pins = args["pins"] as? [String],
                  let hostname = args["hostname"] as? String else { result(invalidArg()); return }
            cachedPins = pins
            cachedHostname = hostname
            CShieldSSL.updatePins(pins: pins, hostname: hostname)
            result(nil)
        case "ssl.isConfigured":
            result(CShieldSSL.isConfigured())
        case "ssl.checkServerTrusted":
            handleCheckServerTrusted(args: args, result: result)
        case "ssl.httpRequest":
            handleHttpRequest(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
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

        // Retain the session until completion by capturing it in the closure.
        let session = CShieldSSL.urlSession()
        let task = session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }

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

    /// Verifies a single DER-encoded leaf certificate (base64): SPKI pin check
    /// (via the native SDK's `CShieldSSL.spkiPin`) plus a structural SecTrust
    /// evaluation.
    ///
    /// NOTE: this path only receives the leaf cert from Dart, so it cannot do
    /// real CA chain validation or chain-based pin matching — the self-anchored
    /// SecTrust evaluation below is structural only. Full chain pinning + CA
    /// validation is enforced at the TLS layer by the native `CShieldSSL.urlSession()`
    /// delegate (`CShieldTrustManager`), which is the recommended integration path.
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

        // Step 1: SPKI pin verification (does not require full chain).
        // Reuses the native SDK's single source of truth for pin computation
        // (CShieldTrustManager.computeSpkiPin) so the pin format never diverges
        // between the native URLSession delegate path and this Flutter bridge.
        let computed = CShieldSSL.spkiPin(for: cert)
        guard cachedPins.contains(computed) else {
            result(false); return
        }

        // Step 2: System CA validation with the leaf cert as its own anchor so
        // the evaluation succeeds even when the intermediate CA is not cached.
        // This mirrors Android's X509TrustManagerExtensions behaviour where the
        // system validates and we additionally enforce the SPKI pin above.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        let certArray = [cert] as CFArray
        guard SecTrustCreateWithCertificates(certArray, policy, &trust) == errSecSuccess,
              let serverTrust = trust else {
            result(false); return
        }
        // Allow the cert to serve as its own anchor so CA chain validation
        // doesn't fail when only the leaf cert is provided.
        SecTrustSetAnchorCertificates(serverTrust, certArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, false)
        var cfError: CFError?
        let trusted = SecTrustEvaluateWithError(serverTrust, &cfError)
        result(trusted)
    }

    private func invalidArg() -> FlutterError {
        FlutterError(code: CShieldErrorCode.invalidArgument,
                     message: "Missing or invalid arguments",
                     details: nil)
    }
}

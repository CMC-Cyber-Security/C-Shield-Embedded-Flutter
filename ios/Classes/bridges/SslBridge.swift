import Flutter
import CShieldEmbedded
import Foundation

/// Mirrors SslBridge.kt (android) — keep both in sync.
final class SslBridge {

    /// URLSession dùng chung cho `ssl.httpRequest`: delegate là `CShieldTrustManager` DUY NHẤT của
    /// native (multi-host), nên một session phục vụ mọi host pin và giữ được connection reuse.
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
        // R5 — multi-host: ưu tiên map `pinsByHost` (host pattern → pins); tương thích đường cũ
        // `pins`+`hostname` bằng cách gói thành map 1 phần tử. Native iOS giờ multi-host thật
        // (exact / `*.` / `**.`) — trước đây chỉ giữ 1 host.
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

        // H-3 — mặc định auto-seal; app truyền allowRuntimeUpdates=true nếu cần rotate runtime.
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
            // Merge vào cấu hình hiện tại (giống Android addPins). Chỉ chạy khi allowRuntimeUpdates=true.
            try CShieldSSL.updatePins(pins: pins, hostname: hostname)
            result(nil)
        } catch {
            result(mapConfigError(error))
        }
    }

    /// Khớp mapping của SslBridge.kt: đã seal → `ssl_not_configured`; sai format → `invalid_argument`.
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

    /// Kiểm tra một leaf certificate (DER base64) cho `host` bằng `CShieldSSL.verifyPin` của native —
    /// cùng logic với Android `CShieldSSL.verifyPin`: pin của ĐÚNG host (multi-host); chuỗi đủ → system CA,
    /// chỉ có leaf → kiểm tra cấu trúc (hạn dùng + hostname) + so pin leaf. Chạy off-main vì SecTrust có
    /// thể chạm mạng (tải intermediate).
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

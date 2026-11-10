import Flutter
import CShieldEmbedded

/// Mirrors AipBridge.kt (android) — keep both in sync.
///
/// Chỉ phần ký/verify crypto cross sang Flutter; normalize body, dựng payload, băm và check cửa sổ
/// timestamp response đều làm ở Dart (AIPNormalizer / CShieldAIP). Ký per-request dùng **App Attest**
/// (khóa Secure Enclave) — fallback RSA v1 đã bỏ (D6).
final class AipBridge {

    // CHỈ v2: App Attest assertion. (CompositeRequestSigner/NativeRsaRequestSigner đã bị gỡ.)
    private let requestSigner: RequestSigner = AppAttestRequestSigner()

    private let bg = DispatchQueue(label: "com.cmc.cshield.flutter.aip", qos: .userInitiated)

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "aip.verify":        verify(args: args, result: result)
        case "aip.signRequest":   signRequest(args: args, result: result)
        case "aip.forceRefresh":  forceRefresh(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - verify response

    private func verify(args: [String: Any], result: @escaping FlutterResult) {
        guard let payload   = args["payload"] as? String,
              let signature = args["signature"] as? String else { result(invalidArg()); return }

        bg.async {
            do {
                let valid = try CShieldAIP.verifySign(payload, signature: signature)
                DispatchQueue.main.async {
                    if valid { result(nil) }
                    else {
                        result(FlutterError(code: CShieldErrorCode.aipInvalidSignature,
                                            message: "Signature verification failed", details: nil))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: CShieldErrorCode.nativeError,
                                        message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - sign request (per-request cs-proof)

    private func signRequest(args: [String: Any], result: @escaping FlutterResult) {
        guard let method = args["method"] as? String,
              let path = args["path"] as? String,
              let canonicalQuery = args["canonicalQuery"] as? String,
              let timestampSec = (args["timestampSec"] as? Int).map(Int64.init),
              let bodyHashHex = args["bodyHashHex"] as? String else { result(invalidArg()); return }

        bg.async {
            let ctx = RequestContext(method: method, path: path, canonicalQuery: canonicalQuery,
                                     timestampSec: timestampSec, bodyHashHex: bodyHashHex)
            do {
                // Ký thử; nil = chưa sẵn sàng (token hết hạn...) → tự làm mới NỀN (an toàn vì đang off-main,
                // mirror Android HardwareRequestSigner.ensureReady) rồi ký lại MỘT lần.
                var headers = try self.requestSigner.sign(ctx)
                if headers == nil {
                    _ = CShield.awaitReady(timeoutMs: 1500)
                    headers = try self.requestSigner.sign(ctx)
                }
                if let headers = headers {
                    let map = headers.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
                    DispatchQueue.main.async { result(map) }
                } else {
                    // Vẫn chưa sẵn sàng → NOT_READY kèm phân loại (retryable/state) như Android, để Dart
                    // interceptor biết nên chờ/retry (tạm thời) hay chặn (UNAVAILABLE = vĩnh viễn).
                    let st = CShield.state()
                    DispatchQueue.main.async {
                        result(FlutterError(code: CShieldErrorCode.notReady,
                                            message: "device attestation chưa sẵn sàng",
                                            details: ["retryable": st != .unavailable,
                                                      "state": AttestBridge.stateId(st)]))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: CShieldErrorCode.aipSigningFailed,
                                        message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - force refresh (401 invalid-token)

    private func forceRefresh(args: [String: Any], result: @escaping FlutterResult) {
        let timeoutMs = Int64(args["timeoutMs"] as? Int ?? 5000)
        bg.async {
            let ok = CShield.forceRefresh(timeoutMs: timeoutMs)
            DispatchQueue.main.async { result(ok) }
        }
    }

    // MARK: - Helpers

    private func invalidArg() -> FlutterError {
        FlutterError(code: CShieldErrorCode.invalidArgument, message: "Missing or invalid arguments", details: nil)
    }
}

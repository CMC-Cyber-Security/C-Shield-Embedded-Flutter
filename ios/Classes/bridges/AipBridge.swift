import Flutter
import CShieldEmbedded

/// Mirrors AipBridge.kt (android) — keep both in sync.
///
/// Only the cryptographic sign/verify is exposed to Flutter. Body normalization, payload
/// construction, hashing and the response timestamp-window check are all done in Dart
/// (AIPNormalizer / CShieldAIP). Per-request signing uses **App Attest** (a Secure Enclave key).
final class AipBridge {

    // Signs with an App Attest assertion.
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
                // Try to sign. nil = not ready (expired token, …) → wait for a background refresh
                // (safe, since this runs off the main thread; mirrors
                // HardwareRequestSigner.ensureReady on Android), then sign ONCE more.
                var headers = try self.requestSigner.sign(ctx)
                if headers == nil {
                    _ = CShield.awaitReady(timeoutMs: 1500)
                    headers = try self.requestSigner.sign(ctx)
                }
                if let headers = headers {
                    let map = headers.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
                    DispatchQueue.main.async { result(map) }
                } else {
                    // Still not ready → NOT_READY with its classification (retryable/state), as on
                    // Android, so the Dart interceptor knows whether to wait and retry (transient)
                    // or to block (UNAVAILABLE = permanent).
                    let st = CShield.state()
                    DispatchQueue.main.async {
                        result(FlutterError(code: CShieldErrorCode.notReady,
                                            message: "device attestation is not ready",
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

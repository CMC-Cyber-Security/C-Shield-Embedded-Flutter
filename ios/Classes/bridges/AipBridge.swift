import Flutter
import CShieldEmbedded

/// Mirrors AipBridge.kt (android) — keep both in sync.
final class AipBridge {
    private let requestSigner = CompositeRequestSigner([
        AppAttestRequestSigner(),
        NativeRsaRequestSigner(),
    ])

    // Only the cryptographic sign/verify are exposed to Flutter. Body
    // normalization, payload construction, hashing and the response
    // timestamp-window check are all done in Dart (AIPNormalizer / CShieldAIP),
    // so no fabricated URLRequest/URL is needed here.
    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "aip.sign":   sign(args: args, result: result)
        case "aip.verify": verify(args: args, result: result)
        case "aip.signRequest": signRequest(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Sign / verify

    private func sign(args: [String: Any], result: @escaping FlutterResult) {
        guard let payload = args["payload"] as? String else { result(invalidArg()); return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let signature = try CShieldAIP.sign(payload)
                DispatchQueue.main.async { result(signature) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: CShieldErrorCode.aipSigningFailed,
                                         message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func verify(args: [String: Any], result: @escaping FlutterResult) {
        guard let payload   = args["payload"] as? String,
              let signature = args["signature"] as? String else { result(invalidArg()); return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let valid = try CShieldAIP.verifySign(payload, signature: signature)
                DispatchQueue.main.async {
                    if valid {
                        result(nil)
                    } else {
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
    
    private func signRequest(args: [String: Any], result: @escaping FlutterResult) {
        guard let method = args["method"] as? String else { result(invalidArg()); return }
        guard let path = args["path"] as? String else { result(invalidArg()); return }
        guard let canonicalQuery = args["canonicalQuery"] as? String else { result(invalidArg()); return }
        guard let timestampSec = args["timestampSec"] as? Int64 else { result(invalidArg()); return }
        guard let bodyHashHex = args["bodyHashHex"] as? String else { result(invalidArg()); return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ctx = RequestContext(method: method,
                                         path: path,
                                         canonicalQuery: canonicalQuery,
                                         timestampSec: timestampSec,
                                         bodyHashHex: bodyHashHex)
                let headers = try self.requestSigner.sign(ctx)
                DispatchQueue.main.async { result(headers?.reduce(into: [String: String]()) { partialResult, field in
                    partialResult[field.name] = field.value
                })}
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: CShieldErrorCode.aipSigningFailed,
                                         message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - Helpers

    private func invalidArg() -> FlutterError {
        FlutterError(code: CShieldErrorCode.invalidArgument, message: "Missing or invalid arguments", details: nil)
    }
}

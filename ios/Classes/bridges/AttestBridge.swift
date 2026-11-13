import Flutter
import CShieldEmbedded

/// Mirrors AttestBridge.kt (android) — keep both in sync.
///
/// Exposes the attestation contract of `CShield` to Dart: readiness (`CShieldState`), trust
/// (`TrustLevel`), and on-demand trust elevation (`ensureTrust`).
///
/// The BLOCKING calls (`awaitReady` / `ensureTrust`, which wait for registration, refresh or App
/// Attest) run on a **background queue** and post their result back to main, so they NEVER block
/// Flutter's main thread. The READ calls (`state` / `lastError` / `currentTrustLevel`) do not
/// block and answer directly.
///
/// Enums cross the method channel as **NAMES** (`"READY"`, `"L4"`, `"SATISFIED"`); Dart maps them
/// back with `fromId`.
final class AttestBridge {

    private let bg = DispatchQueue(label: "com.cmc.cshield.flutter.attest", qos: .userInitiated)

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "attest.state":
            result(AttestBridge.stateId(CShield.state()))
        case "attest.lastError":
            result(CShield.lastError())
        case "attest.currentTrustLevel":
            result(AttestBridge.trustId(CShield.currentTrustLevel()))
        case "attest.awaitReady":
            handleAwaitReady(args: args, result: result)
        case "attest.ensureTrust":
            handleEnsureTrust(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Waits until ready (or until the timeout) and returns the name of the final `CShieldState`.
    /// Runs in the background because it blocks.
    private func handleAwaitReady(args: [String: Any], result: @escaping FlutterResult) {
        let timeoutMs = Int64(args["timeoutMs"] as? Int ?? 8000)
        bg.async {
            let s = CShield.awaitReady(timeoutMs: timeoutMs)
            DispatchQueue.main.async { result(AttestBridge.stateId(s)) }
        }
    }

    /// Raises trust to at least `minLevel` before a sensitive flow (may cost an App Attest refresh,
    /// and always does with `requireFresh`).
    /// A missing or unmappable `minLevel` → `invalidArgument`, rather than silently raising to the
    /// wrong level.
    private func handleEnsureTrust(args: [String: Any], result: @escaping FlutterResult) {
        guard let minLevelId = args["minLevel"] as? String else {
            result(FlutterError(code: CShieldErrorCode.invalidArgument, message: "minLevel required", details: nil))
            return
        }
        let minLevel = TrustLevel.fromId(minLevelId)
        if minLevel == .unknown {
            result(FlutterError(code: CShieldErrorCode.invalidArgument, message: "minLevel invalid: \(minLevelId)", details: nil))
            return
        }
        let requireFresh = args["requireFresh"] as? Bool ?? false
        let timeoutMs = Int64(args["timeoutMs"] as? Int ?? 15000)
        bg.async {
            let r = CShield.ensureTrust(minLevel, requireFresh: requireFresh, timeoutMs: timeoutMs)
            DispatchQueue.main.async { result(AttestBridge.ensureId(r)) }
        }
    }

    // MARK: - enum → id string (matches Dart `fromId`; also used by AipBridge for NOT_READY details)

    static func stateId(_ s: CShieldState) -> String {
        switch s {
        case .initializing: return "INITIALIZING"
        case .ready:        return "READY"
        case .degraded:     return "DEGRADED"
        case .unavailable:  return "UNAVAILABLE"
        @unknown default:   return "UNAVAILABLE"
        }
    }

    /// `TrustLevel.id` is "" for `.unknown` → send "UNKNOWN" instead, to match Dart's `TrustLevel.fromId`.
    static func trustId(_ t: TrustLevel) -> String {
        t.id.isEmpty ? "UNKNOWN" : t.id
    }

    static func ensureId(_ r: EnsureTrustResult) -> String {
        switch r {
        case .satisfied:    return "SATISFIED"
        case .insufficient: return "INSUFFICIENT"
        case .rateLimited:  return "RATE_LIMITED"
        case .timeout:      return "TIMEOUT"
        case .offline:      return "OFFLINE"
        case .unavailable:  return "UNAVAILABLE"
        @unknown default:   return "UNAVAILABLE"
        }
    }
}

import Flutter
import CShieldEmbedded

/// Mirrors AttestBridge.kt (android) — keep both in sync.
///
/// Phơi hợp đồng attestation của `CShield` sang Dart: readiness (`CShieldState`) + trust
/// (`TrustLevel`) + nâng trust theo yêu cầu (`ensureTrust`).
///
/// Hàm BLOCK (`awaitReady`/`ensureTrust` — chờ register/refresh/App Attest) chạy trên **thread nền**
/// rồi post kết quả về main — KHÔNG bao giờ block main thread của Flutter. Các hàm ĐỌC
/// (`state`/`lastError`/`currentTrustLevel`) không block nên trả thẳng.
///
/// Enum qua method-channel dạng **TÊN** (`"READY"`, `"L4"`, `"SATISFIED"`); Dart map ngược (`fromId`).
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

    /// Chờ tới khi sẵn sàng (hoặc hết timeout) → trả tên `CShieldState` cuối. Chạy nền (block).
    private func handleAwaitReady(args: [String: Any], result: @escaping FlutterResult) {
        let timeoutMs = Int64(args["timeoutMs"] as? Int ?? 8000)
        bg.async {
            let s = CShield.awaitReady(timeoutMs: timeoutMs)
            DispatchQueue.main.async { result(AttestBridge.stateId(s)) }
        }
    }

    /// Nâng trust ≥ `minLevel` trước luồng nhạy (có thể tốn App Attest refresh / `requireFresh`).
    /// `minLevel` sai/không map được → `invalidArgument` (đừng im lặng nâng nhầm mức).
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

    // MARK: - enum → id string (khớp Dart `fromId`; dùng chung bởi AipBridge cho NOT_READY details)

    static func stateId(_ s: CShieldState) -> String {
        switch s {
        case .initializing: return "INITIALIZING"
        case .ready:        return "READY"
        case .degraded:     return "DEGRADED"
        case .unavailable:  return "UNAVAILABLE"
        @unknown default:   return "UNAVAILABLE"
        }
    }

    /// `TrustLevel.id` trả "" cho `.unknown` → đổi thành "UNKNOWN" cho khớp Dart `TrustLevel.fromId`.
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

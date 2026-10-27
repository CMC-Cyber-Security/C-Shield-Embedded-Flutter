# Attestation v2 — port từ Android embedded SDK sang Flutter plugin

**Ngày:** 2026-10-27 · **Nguồn:** `cshieldembeddedandroid` @ `5210065` (register KA-only L3 +
ensureTrust) · **Tài liệu gốc:** `solution/attestation/CSHIELD-ATTESTATION-GUIDE.md`

Trước đợt này, tầng Flutter đã có **ký request bằng hardware key** (`aip.signRequest`),
**force-refresh 401** (`aip.forceRefresh`) và phân loại `not_ready` (`retryable`/`state`). Phần còn
thiếu so với Android là **hợp đồng readiness + trust**: `state`/`lastError`/`awaitReady`,
`currentTrustLevel`, `ensureTrust` (nâng trust bằng Play Integrity theo yêu cầu) và state listener.
Đợt này port đúng phần đó.

## Mặt API mới (Dart)

| Dart | Native tương ứng |
|---|---|
| `CShieldAttest.state()` | `CShieldSDK.state()` |
| `CShieldAttest.lastError()` | `CShieldSDK.lastError()` |
| `CShieldAttest.awaitReady(timeoutMs)` | `CShieldSDK.awaitReady(timeoutMs)` |
| `CShieldAttest.currentTrustLevel()` | `CShieldSDK.currentTrustLevel()` |
| `CShieldAttest.ensureTrust(level, requireFresh, timeoutMs)` | `CShieldSDK.ensureTrust(...)` |
| `CShieldAttest.stateChanges` | `CShieldSDK.addStateListener` / `removeStateListener` |
| `CShieldAttest.forceRefresh()` | `CShieldSDK.forceRefresh()` (đã có từ trước) |

Enum mirror 1-1 native: `TrustLevel` (unknown + L0–L5, có `rank`/`atLeast`), `CShieldState`,
`EnsureTrustResult`. **Cross method-channel bằng TÊN enum** (`"READY"`, `"L4"`, `"SATISFIED"`) —
`fromId` map ngược, tên lạ/null → mức "không khả dụng" (fail-closed).

## Thay đổi theo lớp

- **Kotlin** `bridges/AttestBridge.kt` (mới): handle `attest.*`. Mọi hàm SDK ở đây đều BLOCK
  (register/refresh/Play Integrity) → chạy trên `Thread` nền, post kết quả về main handler.
  `minLevel` không map được → `invalid_argument` (không im lặng nâng nhầm mức).
- **Kotlin** `CShieldEmbeddedPlugin.kt`: route prefix `attest.`; đăng ký state listener **sau
  `sdk.initialize`** (attestManager chỉ tồn tại sau initialize), đẩy lên EventChannel dưới dạng
  `onAttestStateChanged` (+ `trustLevel`, `lastError`); gỡ listener ở `onDetachedFromEngine`.
- **Dart** `api/attest/*`: 3 enum + facade `CShieldAttest`.
- **Dart** `event/c_shield_event.dart`: thêm `AttestStateChanged`.
- **Dart** platform interface + method channel: 5 method `attest*`; map TÊN enum → enum Dart ở MỘT
  chỗ duy nhất (method channel).
- **Dart** interceptor (`http` + Dio): thêm `onNotReady` (`failFast`/`blockRetry`/`passThrough`,
  mirror `OnNotReady` native) và `requiredLevel` (per-request `ensureTrust` trước khi ký,
  best-effort — lỗi native KHÔNG chặn request vì server mới chốt trust).
- **Example app**: banner trạng thái attest (từ `stateChanges`) + 2 nút `/payment` (ensureTrust L4)
  và `/transfer` (L4 + `requireFresh`) — khớp demo Android `FormScreenViewModel.runSensitive`.
- **README**: mục 4 mới (Attestation), renumber SSL/Malware/Exceptions → 5/6/7; bảng tham số
  interceptor + mã lỗi `notReady`.

## iOS — chưa có attest v2

iOS embedded vẫn ký bằng `CompositeRequestSigner([AppAttest, NativeRsa])`, chưa có luồng
register/refresh v2 + trust level (đúng trạng thái "⏳ iOS embedded SDK" trong tài liệu gốc).
`attest.*` và `aip.forceRefresh` do đó rơi về `FlutterMethodNotImplemented`.

Dart xử lý bằng `_invokeOptional` (nuốt `MissingPluginException` → `null`): `state`/`ensureTrust`
trả `unavailable`, `currentTrustLevel` trả `unknown`, `forceRefresh` trả `false` — **không ném**, để
app dùng CHUNG một luồng cho cả hai nền tảng. Khi iOS có attest v2 → thêm `AttestBridge.swift`
mirror `AttestBridge.kt`, không cần sửa Dart.

> Trước đợt này `aip.forceRefresh` trên iOS làm `MissingPluginException` **nổ ra khỏi interceptor**
> giữa luồng retry 401 — đã vá cùng lúc.

## AAR

`example/android/app/libs/cshield-embedded-{debug,release}.aar` đã được build lại từ
`cshieldembeddedandroid` @ `5210065` (`assembleUatDebug` / `assembleUatRelease` → biến thể **uat**,
host `c-shield-license.cmccs.vn`). Bản AAR cũ (23/10) **không có** `TrustLevel`/`EnsureTrustResult`/
`ensureTrust` nên bridge mới không compile được. KH dùng gói **prod** cần AAR `assembleProd*`.

## Verify
- `flutter analyze` (plugin + example) → **No issues found**.
- `flutter test` → pass, gồm `test/attest_models_test.dart` (mirror `TrustLevelTest.kt`: map tên
  enum, so ngưỡng, `unknown` luôn thấp nhất, parse event).
- `flutter build apk --debug` (example) → compile `AttestBridge.kt` + plugin với AAR mới.
- **Chưa chạy trên máy thật** — luồng L3 → L4 (Play Integrity) cần thiết bị có GMS.

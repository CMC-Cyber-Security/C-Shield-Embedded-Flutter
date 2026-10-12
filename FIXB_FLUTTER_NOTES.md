# FIX B — hardening phía Flutter plugin (R1/R5 + ripple auto-seal)

**Ngày:** 2026-10-12

Tiếp theo đợt SDK lõi (R2/R4/H-3). Phần này vá **R5 (multi-host)**, **R1 (coverage)** và xử lý
**ripple của auto-seal (H-3)** cho tầng Flutter.

## R5 — Multi-host (bỏ 1-host exact-match)

Trước: cả stack chỉ pin **1 host** (`_hostname` / `uri.host == _hostname`). Giờ hỗ trợ nhiều host +
wildcard (`example.com`, `*.one-level`, `**.apex+multi`), khớp giống `PinningConfig` native.

Thay đổi theo lớp:
- **Dart API** `c_shield_ssl.dart`: thêm `configureHosts(pinsByHost: Map<String,List<String>>, allowRuntimeUpdates)`;
  `configure(pins, hostname, allowRuntimeUpdates)` giờ là convenience gói thành map 1 phần tử. Lưu
  `_pinsByHost` (thay `_pins`/`_hostname`). Thêm `_pinsForHost(host)` + `_hostMatches` (exact/`*.`/`**.`).
  `createHttpClient().badCertificateCallback` và `createDioAdapter()` dùng multi-host.
- **Platform interface + method channel**: `sslConfigure({pinsByHost, allowRuntimeUpdates})` (thay
  `{pins, hostname}`); truyền map qua channel.
- **Adapter** `c_shield_native_adapter.dart`: nhận `hostPatterns: Set<String>`, route sang native khi
  `uri.host` khớp BẤT KỲ pattern nào (HTTPS); còn lại delegate `IOHttpClientAdapter`.
- **Kotlin** `SslBridge.handleConfigure`: đọc `pinsByHost` (map) + `allowRuntimeUpdates`, gọi
  `CShieldSSL.configure(pinsByHost=…, allowRuntimeUpdates=…)`. Vẫn nhận đường cũ (pins+hostname) để
  an toàn tương thích.

## Ripple auto-seal (H-3 từ SDK)

SDK giờ **auto-seal sau configure** (mặc định). Hệ quả tầng Flutter:
- `sslConfigure` mặc định `allowRuntimeUpdates=false` → native seal. **Gọi configure lần 2 / `ssl.updatePins`
  sẽ ném** → `SslBridge` map thành lỗi `SSL_NOT_CONFIGURED` với message rõ.
- Đường `ssl.updatePins` + Dart `updatePins` vẫn còn, nhưng CHỈ chạy nếu configure ban đầu dùng
  `allowRuntimeUpdates=true`.

## R1 — Coverage (việc của APP, không phải plugin)

FIX B (native re-verify SPKI) **chỉ chạy trên đường Dio-adapter native** (`createDioAdapter()` →
`ssl.httpRequest` → interceptor OkHttp). Các đường `createIOClient()`/`createHttpClient()` dùng
pinning **leaf-only tầng Dart** (`badCertificateCallback`), KHÔNG qua FIX B.
→ App `ms` phải route request nhạy cảm (login/OTP) qua **Dio + `createDioAdapter()`**, không dùng
`http`/IOClient cho các endpoint đó.

## ⚠️ App `ms` cần migrate
1. **Cấu hình TẤT CẢ host trong 1 lần**: `CShieldSSL.configureHosts(pinsByHost: {...})` (hoặc 1 lần
   `configure`). KHÔNG gọi configure nhiều lần (lần 2 ném vì auto-seal). Nếu đang dùng `updatePins`
   runtime → hoặc bỏ, hoặc `configure(..., allowRuntimeUpdates: true)` (kém an toàn).
2. Route endpoint nhạy cảm qua `createDioAdapter()` (để FIX B áp dụng).
3. Mỗi host khai ≥1 backup pin (cho R2 ở SDK — tránh native kill khi rotate).

## Verify
- `dart analyze lib test` → **No issues found**.
- Kotlin `SslBridge`: build gradle (chưa chạy ở đây) — khớp signature SDK mới.
- Chưa làm: **R3** (native TLS, SDK). **Cov endpoint không-pin** (license/malware/trust-version) =
  quyết định app-side.

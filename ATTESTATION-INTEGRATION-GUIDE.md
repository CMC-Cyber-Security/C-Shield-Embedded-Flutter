# C-Shield Embedded (Flutter) — Hướng dẫn tích hợp attest: State, Error & các trường hợp dùng

_Cập nhật: 2026-10-29 · Package: `c_shield_embedded` · Góc nhìn: bên tích hợp (app Flutter)_

> Mục tiêu: KH **chọn đúng API theo nhu cầu**. Không phải dùng tất cả cùng lúc — đa số app chỉ cần 2–3 hàm.
> Cơ chế attestation tổng thể (trust L0–L5, enroll/refresh, keep-trust) xem `CSHIELD-ATTESTATION-GUIDE.md`.

---

## 1. Mô hình 1 phút
Thiết bị tự chứng minh an toàn bằng phần cứng → nhận **access token** có **trust level** → request được **ký** (interceptor tự lo) → server verify + chốt trust theo route.

**"Rẻ mặc định, đắt theo yêu cầu":** enroll/refresh thường chạy **KA-only/keep-trust** (0 Play Integrity) → đa số máy thật (TEE) dừng ở **L3**. Muốn **L4+** cho luồng nhạy thì app **chủ động** gọi `ensureTrust` — khi đó mới chạy Play Integrity.

---

## 2. Vòng đời attest & cơ chế (đọc kỹ để khỏi dùng sai)

`CShieldEmbedded.initialize(...)` **khởi động attest nền theo kiểu fire-and-forget**: hàm trả về NGAY, việc enroll KA-only chạy ở thread nền. App **không bị chặn**.

```
initialize()
  └─ bắt đầu 1 lần attest nền (single-flight), state = INITIALIZING → (READY|DEGRADED|UNAVAILABLE)
```

**`awaitReady` KHÔNG attest lại** — nó *bám vào* đúng lần attest mà `initialize` đã khởi động (single-flight) và **CHỜ** nó xong:
```
awaitReady(timeoutMs):
  1) đã READY? → trả ngay
  2) đã UNAVAILABLE (vĩnh viễn)? → trả ngay
  3) còn đang chạy → CHỜ chính lần attest đó tới khi xong / hết timeout
  4) trả state cuối
```
→ Dùng `initialize` để **bắt đầu** (không chặn); dùng `awaitReady` khi muốn **chờ cho xong** (vd splash). Hai cái bổ trợ, **không nhân đôi** attest. (`awaitReady` chỉ kích một lần thử MỚI nếu lần trước đã xong mà vẫn chưa ready — tức retry theo yêu cầu.)

> Trên Flutter, `awaitReady`/`ensureTrust` chạy nền phía native rồi trả về qua `await` → **không block UI isolate** (khác Android native phải tự đưa ra thread nền).

---

## 3. Bảng API — vai trò & khi nào gọi

| API | Vai trò | Bắt buộc? | Gọi khi |
|---|---|:---:|---|
| `initialize(license, {cloudProjectNumber?})` | Khởi động SDK + attest KA-only nền. `cloudProjectNumber` **nullable** — bỏ ⇒ TẮT Play Integrity (xem §8.1) | ✅ | 1 lần lúc `main` |
| *(interceptor)* `CShieldDioInterceptor` / `CShieldInterceptor` | Tự ký request + verify response | ✅ (để bảo vệ API) | gắn 1 lần vào client |
| `ensureTrust(minLevel, {requireFresh})` | Nâng/làm tươi trust TRƯỚC luồng ≥L4 | khi có luồng nhạy | ngay trước khi vào màn/API nhạy |
| `awaitReady(timeoutMs)` | **Chờ** attest xong | tùy chọn | splash / trước request đầu, nếu muốn chặn |
| `state()` | Đọc state 1 lần | tùy chọn | khi cần kiểm nhanh |
| `stateChanges` (Stream) | Theo dõi state realtime | tùy chọn | hiện banner/badge |
| `lastError()` | Mã lỗi ổn định gần nhất | tùy chọn | hiện lý do khi `unavailable` |
| `currentTrustLevel()` | Mức trust hiện tại | tùy chọn | điều hướng UI (ẩn/hiện nút) |
| `forceRefresh()` | Refresh keep-trust khi 401 | **hầu như không** | chỉ khi tự dựng HTTP client (interceptor đã tự làm) |

> Flutter theo dõi state bằng **Stream `stateChanges`** (tương đương `addStateListener`/`removeStateListener` của Android).

---

## 4. Chọn PROFILE theo nhu cầu (chọn 1, không dùng hết)

### Profile A — Tối thiểu (đa số app)
Chỉ cần request được ký; không quan tâm hiển thị trạng thái. Request đầu nếu attest chưa xong → interceptor xử lý theo `onNotReady`.
```dart
// main()
await CShieldEmbedded.initialize(license: '...', cloudProjectNumber: '970898117522');
await CShieldSSL.configure(pins: const [ /* ... */ ]);

// network setup
dio.httpClientAdapter = CShieldSSL.createDioAdapter();
dio.interceptors.add(CShieldDioInterceptor(dio: dio));
// XONG. Không cần awaitReady/state/listener.
```

### Profile B — Có UX chờ/hiển thị (thêm vào A)
Muốn splash chờ sẵn sàng + banner trạng thái.
```dart
// Splash: chờ attest xong rồi mới điều hướng
final s = await CShieldAttest.awaitReady(timeoutMs: 8000);
switch (s) {
  case CShieldState.ready:
  case CShieldState.degraded:     goHome();                      // cho vào; trust do server/ensureTrust lo
  case CShieldState.initializing: showRetry('Đang chuẩn bị bảo mật…');
  case CShieldState.unavailable:  showUnsupported(await CShieldAttest.lastError());
}

// Banner realtime (bất kỳ đâu)
CShieldAttest.stateChanges.listen((e) => setState(() => _state = e.state));
```

### Profile C — Có luồng nhạy ≥L4 (thêm vào A/B)
```dart
// Ngay TRƯỚC khi vào màn/thao tác nhạy:
switch (await CShieldAttest.ensureTrust(TrustLevel.l4, requireFresh: false)) {
  case EnsureTrustResult.satisfied:    goPayment();
  case EnsureTrustResult.insufficient: block('Thiết bị chưa đạt mức an toàn yêu cầu');
  case EnsureTrustResult.rateLimited:
  case EnsureTrustResult.timeout:      retryLater();
  case EnsureTrustResult.unavailable:  notSupported();
}
// Thao tác CỰC nhạy (server đặt maxTrustAgeSeconds): requireFresh: true
```

---

## 5. Use-case → dùng API nào

| Trường hợp | Dùng gì |
|---|---|
| Khởi động app | `initialize` |
| Gọi API thường | *(không gì — interceptor tự ký; 401 tự `forceRefresh`)* |
| Splash chờ sẵn sàng | `awaitReady` |
| Banner/badge trạng thái không chặn | `stateChanges` (+ `lastError`, `currentTrustLevel`) |
| Máy không hỗ trợ / bị chặn | `state()==unavailable` + `lastError()` |
| Vào màn/API ≥L4 | `ensureTrust(L4)` |
| Hành động cực nhạy (bằng chứng tươi) | `ensureTrust(L4, requireFresh:true)` |
| Tự dựng HTTP client (không interceptor) | `forceRefresh` thủ công |

---

## 6. STATE — `CShieldState`

| State | Nghĩa | App làm gì |
|---|---|---|
| `initializing` | đang enroll/refresh nền, chưa có token | tạm — chờ/retry; chưa ký được |
| `ready` | có token + key phần cứng | ký request bình thường |
| `degraded` | ký được nhưng **trust thấp (L0/L1)** | vẫn gửi; **server có thể từ chối** route trust cao |
| `unavailable` | không hỗ trợ / bị chặn vĩnh viễn / **iOS hiện tại** | **ĐỪNG retry**; báo "không hỗ trợ" |

> `degraded` **không chặn ở client** — server mới chốt trust theo route. Chỉ `unavailable` mới coi là "không chạy được".

---

## 7. ERROR — 3 tầng (dùng khác nhau)

**Tầng 1 — Readiness (vĩnh viễn):** `state()==unavailable` + `lastError()` → mã ổn định (`device_blocked`, `attestation_not_enabled`, `device_unsupported`, `network`, `rate_limited`…) → hiển thị lý do.

**Tầng 2 — Ký/verify request (`CShieldException`):** interceptor ném, Dio bọc trong `DioException.error`. Map ra message bằng mapper (mẫu `CShieldErrorMapper`):
```dart
final msg = CShieldErrorMapper.messageOf(error) ?? fallbackFromServer(error);
```
Code hay gặp (`CShieldErrorCode`): `sslPinMismatch`, `aipInvalidSignature`, `aipMissingHeader`, `aipTimestampExpired` (lệch giờ), `notReady` (attest chưa xong khi ký — kèm `retryable`/`state`), `notInitialized`.
> ⚠️ Mapper dùng `switch` **exhaustive** trên `CShieldErrorCode` → nâng cấp plugin thêm code mới (vd `notReady`) phải thêm case, nếu không **lỗi compile**.

**Tầng 3 — Nâng trust (`EnsureTrustResult`):** KHÔNG phải exception.
| Giá trị | Nghĩa | Xử lý |
|---|---|---|
| `satisfied` | đạt mức (+ tươi nếu requireFresh) | đi tiếp |
| `insufficient` | đã thử nâng nhưng không đạt | chặn / hạ cấp |
| `rateLimited` | PI giới hạn/quota | thử lại sau; trust không bị hạ |
| `timeout` | quá `timeoutMs` | thử lại sau |
| `unavailable` | chưa init / không hỗ trợ | báo không hỗ trợ |

**Tín hiệu server (403/401) ↔ hành động:**
| Server | Nghĩa | Client |
|---|---|---|
| `CSHIELD_DEVICE_NOT_ALLOWED` (403) | trust chưa đủ | `ensureTrust(mức)` + thử lại |
| `CSHIELD_TRUST_NOT_FRESH` (403) | trust đủ nhưng cũ | `ensureTrust(mức, requireFresh:true)` + thử lại |
| `CSHIELD_INVALID_ACCESS_TOKEN` (401) | token hết hạn | interceptor **tự** `forceRefresh` + retry 1 lần |

---

## 8. Threading & iOS
- **Threading:** trên Flutter các hàm `await` (awaitReady/ensureTrust) chạy nền native → an toàn gọi từ UI, không block isolate.
- **iOS (hiện tại):** chưa wire attest v2 ở bridge Flutter → `state()`=`unavailable`, `currentTrustLevel()`=`unknown`, `ensureTrust()`=`unavailable` (**trả giá trị, không ném**) → dùng **chung một luồng** 2 nền tảng, không cần `if (Platform.isIOS)`.

### 8.1 Không dùng Play Integrity — `initialize` KHÔNG truyền `cloudProjectNumber` (chỉ Android)
`cloudProjectNumber` là **tùy chọn (nullable)**. Bỏ trống = **chủ động không dùng Play Integrity** (chỉ ảnh hưởng Android; iOS vốn không dùng PI):
- Android: **không warm-up PI**, enroll/refresh **luôn KA-only**, KHÔNG gửi `cloud_project_number` lên BE.
- Thiết bị vẫn **ký request bình thường** + có trust KA tự động (vd TEE → **L3**); chỉ **không nâng/làm tươi trust** được.
- `ensureTrust` khi đó là thao tác không hợp lệ → **ném `CShieldException` code `playIntegrityNotConfigured`** — cả gọi trực tiếp **lẫn** qua interceptor `requiredLevel` (request bị reject với lỗi này).
- Truyền chuỗi KHÁC rỗng nhưng không phải số nguyên dương → native ném lỗi (bắt typo).

```dart
// Tắt PI: chỉ KA-only, KHÔNG gọi ensureTrust / KHÔNG đặt requiredLevel
await CShieldEmbedded.initialize(license: '...');          // cloudProjectNumber = null

// Nếu lỡ gọi ensureTrust khi PI tắt:
try {
  await CShieldAttest.ensureTrust(TrustLevel.l4);
} on CShieldException catch (e) {
  if (e.code == CShieldErrorCode.playIntegrityNotConfigured) {
    // Sai cấu hình: muốn ≥L4 phải truyền cloudProjectNumber ở initialize.
  }
}
```
> ⚠️ Tắt PI mà vẫn đặt `requiredLevel` ở interceptor ⇒ mỗi request nhạy bị reject với `playIntegrityNotConfigured`. Đã tắt PI thì **đừng đặt `requiredLevel`**.

---

## 9. Ví dụ đầy đủ — đăng nhập (send-otp/login cần L4 + tươi)
```dart
Future<void> _ensureFreshL4() async {
  final r = await CShieldAttest.ensureTrust(TrustLevel.l4, requireFresh: true, timeoutMs: 20000);
  if (r != EnsureTrustResult.satisfied) {
    throw Exception('Thiết bị chưa đạt mức an toàn yêu cầu (ensureTrust: ${r.name}).');
  }
}
Future<CommonResponse> sendOtp(String phone) async {
  await _ensureFreshL4();
  return appService.checkAccountIsExist(/* ... */); // POST /api/v2/send-otp (interceptor tự ký)
}
```
> Máy thật GMS+TEE: `ensureTrust` chạy PI → L4 → OK. Emulator/máy chưa đủ: `insufficient` → chặn (đúng thiết kế endpoint nhạy).

---

## 10. Interceptor — ký/verify tự động

Gắn **1 lần**, sau đó app gần như không đụng: interceptor tự **ký request** + **verify response** + **tự retry 1 lần khi 401 token hết hạn**.

### Luồng mỗi request
```
request → [nếu có requiredLevel] ensureTrust(mức) best-effort
        → KÝ (cs-proof: accessToken + chữ ký ECDSA hardware key) → gửi
response → VERIFY cs-signature:  2xx BẮT BUỘC có chữ ký (sai/thiếu → ném);  non-2xx thiếu → cho qua status thật
         → 401 CSHIELD_INVALID_ACCESS_TOKEN → forceRefresh → gửi lại ĐÚNG 1 lần
         → attest chưa sẵn sàng → xử lý theo onNotReady
```

### Tham số `CShieldDioInterceptor(...)` (Dio; `CShieldInterceptor` cho `http` tương tự)
| Tham số | Ý nghĩa | Mặc định |
|---|---|---|
| `dio` | Dio để gửi lại sau 401 (phải là chính Dio đang gắn). `null` → không auto-retry | `null` |
| `signWhen: (RequestOptions)->bool` | Ký request nào (`null` = ký tất cả). Không khớp → đi qua không ký/verify | `null` |
| `onNotReady` | Chính sách khi attest chưa sẵn sàng (xem dưới) | `failFast` |
| `requiredLevel: (RequestOptions)->TrustLevel?` | Nâng trust theo route (best-effort, KHÔNG fresh, KHÔNG chặn) | `null` |
| `verifyResponses` | Tắt verify nếu server không ký response nhóm này | `true` |

### `onNotReady` — 3 chính sách
| Chính sách | Hành vi | Dùng khi |
|---|---|---|
| `failFast` (mặc định) | Ném lỗi, KHÔNG gửi (fail-closed) | endpoint nhạy |
| `blockRetry` | Chờ ngắn (`awaitReady` ~2s) rồi ký lại 1 lần | muốn mượt lúc mới mở app |
| `passThrough` | Gửi KHÔNG ký | endpoint không nhạy (config công khai) |

### `requiredLevel` vs `ensureTrust` thủ công (dễ nhầm)
- `requiredLevel`: interceptor **chủ động** `ensureTrust(mức)` trước khi ký — **best-effort, KHÔNG requireFresh, KHÔNG chặn** (server mới chốt). Dùng cho route chỉ cần "đủ mức".
- Route **cần TƯƠI** (server đặt `maxTrustAgeSeconds`): `requiredLevel` KHÔNG làm tươi → phải `ensureTrust(L4, requireFresh:true)` **thủ công** trong flow (như cmc-ms ở send-otp/login).
- ⚠️ **PI tắt** (initialize không truyền `cloudProjectNumber`, chỉ Android): `requiredLevel` gọi `ensureTrust` → request bị **reject** với `CShieldException(playIntegrityNotConfigured)` (xem §8.1). Đã tắt PI thì **đừng đặt `requiredLevel`**.

### Mẫu
```dart
// Ký tất cả
dio.interceptors.add(CShieldDioInterceptor(dio: dio));

// Ký chọn lọc (chỉ /api/v2/*) — như cmc-ms
dio.interceptors.add(CShieldDioInterceptor(dio: dio, signWhen: (o) => o.uri.path.startsWith('/api/v2/')));

// Gắn mức theo route (proactive, không fresh)
dio.interceptors.add(CShieldDioInterceptor(
  dio: dio,
  requiredLevel: (o) => o.path == '/api/v2/payment' ? TrustLevel.l4 : null,
));
```

### Lưu ý
- **401 auto-retry** CHỈ cho `CSHIELD_INVALID_ACCESS_TOKEN`. 401 khác (chữ ký/replay) / 403 (trust) → không retry → app xử lý (403 → `ensureTrust` + thử lại thủ công).
- **Multipart**: phải hash theo field text sort+JSON (khớp `multipartBodyHasher` server). Interceptor mặc định của SDK ký body thô; nếu dùng interceptor custom chọn-lọc (như cmc-ms) nhớ chuẩn hoá multipart đúng.
- Có thể tự viết interceptor chọn-lọc (whitelist path) thay vì dùng `signWhen` — cmc-ms làm vậy để kiểm soát ký/verify + log.

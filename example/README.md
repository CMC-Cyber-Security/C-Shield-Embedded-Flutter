# c_shield_embedded_example

App ví dụ cho plugin **c_shield_embedded** — minh hoạ attestation (trust L0–L4 iOS / L0–L5 Android),
per-request signing, SSL pinning multi-host và anti-malware (chỉ Android).

## Định danh app (dùng chung 3 nền)

| | Giá trị |
|---|---|
| iOS bundle ID | `com.cmc.example.cshieldembedded` |
| Android applicationId | `com.cmc.example.cshieldembedded` |
| License (`example/lib/main.dart`) | **cùng một token** với native sample, pin `bundleId / packageId = com.cmc.example.cshieldembedded`, platforms `[IOS, ANDROID]`, environments `[PROD, DEV, STAGING]` |

> ⚠️ License **pin theo bundleId**. Đổi bundle ID ⇒ license fail validate ⇒ phải xin license mới.
> Bundle ID này **trùng** native iOS sample (`cshieldembeddedios`): trên App Store Connect là **CÙNG một app**.

---

## 1. Chạy local

### Android
`.aar` embedded **bị gitignore** (binary nặng + chứa key, như xcframework iOS). Phải tự build từ project CShieldEmbeddedAndroid rồi thả vào `android/app/libs/`.

### iOS
Các xcframework iOS **bị gitignore** (binary nặng, có key) nên repo không kèm. Phải tự build từ poẹct CShieldEmbeddedIOS rồi lần lượt thả vào Libs trong Runner (Mở project example/ios bằng XCode, tạo Libs nếu chưa có).

---

## 2. Build IPA → TestFlight (iOS)

Flow y hệt native iOS sample: **build `.ipa` → inject CShieldOS → upload**. GUI auto-upload KHÔNG dùng được
vì cần chen bước inject trước.

### Điều kiện tiên quyết
1. **Đã rebuild + thả xcframework iOS** (mục 1) — nếu chưa, không build nổi.
2. **Bản Release bắt buộc inject qua Injector.** Release bật oracle gate; không inject ⇒ `clientDataHash` bị
   poison ⇒ mọi API ký trả **`CSHIELD_SIGNATURE_MISMATCH`** (dù trust vẫn có thể lên L4). Đây là gate làm
   đúng việc, không phải bug.
3. **Build number phải tăng.** Khai ở `pubspec.yaml` → `version: 1.0.0+N` (phần sau `+` = build number).
   Mỗi lần upload bump `+N` → `+N+1`. App Store Connect từ chối build number trùng; vì bundle ID trùng native
   sample (cùng app ASC), phải chọn số **cao hơn** mọi build đã upload (xem ở **TestFlight → Builds**).

### Các bước
```bash
cd example

# 0) Bump version trong pubspec.yaml: version: 1.0.0+N  (N cao hơn build cao nhất đã upload)

# 1) Build IPA (KHÔNG auto-upload). Version đọc thẳng từ pubspec.
flutter build ipa --release --export-method app-store
#   → build/ios/ipa/*.ipa
#   (muốn override tạm không sửa pubspec: thêm --build-number=N, flag thắng pubspec)

# 2) Inject CShieldOS vào .ipa (+ re-sign). Muốn env ≠ DEV thì inject param env ở ĐÂY.
#    (dùng công cụ cshieldinjector như với native iOS sample)

# 3) Upload IPA ĐÃ inject lên TestFlight
xcrun altool --upload-app -f <ipa-đã-inject> -t ios -u <apple-id> -p <app-specific-password>
#    hoặc dùng app Transporter (kéo-thả .ipa)
```

### Lưu ý
- **Cùng app TestFlight với native sample** (bundle ID trùng): bản Flutter là *một build khác* của cùng app,
  không phải app riêng. Muốn tách app riêng → đổi bundle ID **+ xin license mới** cho bundle ID đó.
- **App Attest Keychain chung theo bundle ID**: credential/trust từ bản native (vd L4 production) sẽ được bản
  Flutter đọc lại. Muốn test sạch từ đầu: xoá credential (reinstall **không** xoá Keychain).
- **Realm/env phải khớp server**: env inject (mặc định DEV) quyết định realm; demo server phải cùng env.
  Env PROD + AAGUID develop (build dev-signed/Ad-Hoc) → `attestation_rejected`. TestFlight = production AAGUID
  → lên tới L4 nếu BE cho phép.

---

## 3. Build Android (APK/AAB)

```bash
flutter build apk --release        # hoặc: flutter build appbundle --release
```
Release Android cũng bật oracle gate → cần inject qua Injector. Tương tự env inject (mặc định DEV) cũng phải khớp với env của demo server.
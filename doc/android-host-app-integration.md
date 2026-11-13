# C-Shield Embedded Flutter SDK Integration - Android Host App

The `c_shield_embedded` plugin does not bundle the native Android SDK. The host app provides the
C-Shield AAR files (debug and release variants).

---

## Requirements

- `minSdk` 24
- `compileSdk` 34 or higher

---

## Step 1 - Obtain the AAR files from CMC CShield

The Android SDK is built per customer, using the certificate hash of your signed app. Contact CMC
CShield to receive the AAR files matching your app's signing certificate:

```
- cshield-embedded-debug.aar
- cshield-embedded-release.aar
```

---

## Step 2 - Place the AAR files in the project

Create a `libs/` folder under `android/app/` and copy both files into it:

```
your_app/
└── android/
    └── app/
        └── libs/
            ├── cshield-embedded-debug.aar
            └── cshield-embedded-release.aar
```

The plugin looks for the AARs at exactly this location and with exactly these file names. If they
are missing, the Gradle build stops with a message telling you where to put them.

---

## Step 3 - Declare the dependency in Gradle

Open `android/app/build.gradle.kts` (or `build.gradle`) and add:

```kotlin
android {
    compileSdk = 34           // or higher

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    debugImplementation(files("libs/cshield-embedded-debug.aar"))
    releaseImplementation(files("libs/cshield-embedded-release.aar"))
}
```

No other dependencies are needed. The SDK ships no native UI, so it does not pull in Compose or
Retrofit.

---

## Step 4 - Play Integrity (optional)

Attestation levels **L4 and L5** on Android require Play Integrity. To enable it, pass your Google
Cloud project number to `initialize`:

```dart
await CShieldEmbedded.initialize(
  license: 'your_c_shield_license',
  cloudProjectNumber: '123456789012',
);
```

Leave `cloudProjectNumber` out to run without Play Integrity. Requests are still signed and the
device still gets a hardware-based trust level (typically L3), but trust cannot be raised further.
See [attestation.md](attestation.md#running-without-play-integrity-android).

---

## Step 5 - Build

```bash
flutter build appbundle --release
```

---

## Feature-specific permissions

Only the malware scanner needs extra manifest entries, and only for scanning files on disk. See
[malware.md](malware.md#permissions).

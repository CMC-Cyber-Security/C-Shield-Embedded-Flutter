# Anti-Keylogger

Detects the two ways another app can capture what the user types:

1. A **third-party or untrusted keyboard** set as the active input method. A keyboard sees every
   keystroke.
2. **Untrusted accessibility services**, which can read text fields.

**Platforms:**

| | Android | iOS |
|---|:---:|:---:|
| `ThirdPartyKeyboardDetected` | ✅ | ✅ |
| `SuspiciousAccessibilityServiceDetected` | ✅ | — |
| `configure()` allowlists | ✅ | no-op |
| `runCheck()` | ✅ | no-op |

The guard starts by itself in `CShieldEmbedded.initialize()`. There is nothing to turn on.

---

## Reacting to detections

Detections arrive on the shared `CShieldEmbedded.events` stream. Subscribe after `initialize()`:

```dart
_sub = CShieldEmbedded.events.listen((event) {
  switch (event) {
    case ThirdPartyKeyboardDetected(:final label):
      _warnUser('Untrusted keyboard active: $label');
    case SuspiciousAccessibilityServiceDetected(:final packageNames):
      _warnUser('Suspicious accessibility service: $packageNames');
    default:
      break; // events from other features
  }
});

// Android: catch a threat that was already present at startup.
await CShieldAntiKeylogger.runCheck();
```

The guard fires automatically when the keyboard or the set of accessibility services changes. It
does not check the starting state on its own, which is why you call `runCheck()` once after
subscribing.

| Event | Fields | Notes |
|---|---|---|
| `ThirdPartyKeyboardDetected` | `inputMethodId`, `packageName`, `label` | On iOS the keyboard's identity is not available: `inputMethodId` and `packageName` are empty |
| `SuspiciousAccessibilityServiceDetected` | `packageNames` | Android only |

### Detected, not blocked

On Android the event means exactly what its name says. Android cannot stop the user's chosen system
keyboard from being used, so the guard only reports and your app decides what to do: warn the user,
or switch a sensitive field to an in-app keypad. iOS, by contrast, can refuse a third-party keyboard
extension.

---

## Allowlists (Android)

By default a keyboard is trusted if it is a system app or a well-known keyboard (Gboard, Samsung,
SwiftKey). To change that, configure and then re-evaluate:

```dart
await CShieldAntiKeylogger.configure(
  trustSystemKeyboards: true,
  trustedKeyboardPackages: ['com.company.internal_keyboard'],
  trustedAccessibilityPackages: ['com.company.internal_a11y'],
);
await CShieldAntiKeylogger.runCheck();
```

| Parameter | Default | Description |
|---|---|---|
| `trustSystemKeyboards` | `true` | Trust any keyboard shipped as a system app |
| `trustedKeyboardPackages` | `[]` | Third-party keyboard packages to trust. An empty list keeps the native default list |
| `trustedAccessibilityPackages` | `[]` | Accessibility-service packages to treat as legitimate |

---

## API reference

All methods are static on `CShieldAntiKeylogger`.

| Method | Android | iOS | Description |
|---|:---:|:---:|---|
| `configure({trustSystemKeyboards, trustedKeyboardPackages, trustedAccessibilityPackages})` | ✅ | no-op | Sets the trust allowlists |
| `runCheck()` | ✅ | no-op | Re-evaluates the current keyboard and accessibility state now, and re-emits any detection |

On iOS both calls complete without doing anything, so shared code needs no platform check.

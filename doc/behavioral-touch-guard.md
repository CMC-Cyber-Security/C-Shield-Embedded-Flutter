# Behavioral Touch Guard — Auto-Click Detection

A runtime guard that detects **machine-generated input** on your app's own sensitive screens (OTP,
money transfer, in-app purchase). It catches auto-clickers built on accessibility
`dispatchGesture`, ADB `input tap`, UiAutomator, and root-level `/dev/input` injection.

**Platforms:** Android only. The guard analyzes Android `MotionEvent`s. On iOS the calls are not
implemented, so guard them with `Platform.isAndroid`.

---

## How it works

The guard wraps the current Activity's window, below the Flutter engine, so it sees every raw touch.
Each touch gets a risk score from two kinds of evidence:

- **Per-tap properties:** tool type, event source, physical device id.
- **Behavior over recent taps:** coordinate jitter, tap rhythm and rate, uniformity of pressure and
  size.

When the score reaches the threshold, your app is notified. The touch is still delivered unless you
turn blocking on.

The guard decides **human or synthetic**. It does not identify who is tapping, so it is not
behavioral biometrics and stores no biometric profile.

---

## Protecting a screen

Opt in per screen: call `protect()` when the sensitive screen appears and `unprotect()` when you
leave it.

```dart
import 'dart:io' show Platform;

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';

class _OtpPageState extends State<OtpPage> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      // Observe only by default: suspicious taps are reported but still delivered.
      CShieldBehavioralTouchGuard.protect();
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      CShieldBehavioralTouchGuard.unprotect();
    }
    super.dispose();
  }

  // build() ...
}
```

### Tuning

All parameters are optional:

```dart
await CShieldBehavioralTouchGuard.protect(
  riskThreshold: 60,
  blockWhenDetected: true,
  includeAccessibilitySignal: true,
);
```

| Parameter | Default | Description |
|---|---|---|
| `riskThreshold` | native default | Score from 0 to 100 at or above which a touch is reported |
| `blockWhenDetected` | `false` | Also swallow the suspicious touch |
| `includeAccessibilitySignal` | `false` | Add a weak signal when a third-party accessibility service is enabled. Off by default because screen readers such as TalkBack would contribute |

---

## Reacting to events

Events arrive on the shared `CShieldEmbedded.events` stream:

```dart
late final StreamSubscription<CShieldEvent> _sub;

@override
void initState() {
  super.initState();
  _sub = CShieldEmbedded.events.listen((event) {
    switch (event) {
      case SuspiciousTouchDetected(:final riskScore, :final reasons):
        _showAutoClickWarning(riskScore, reasons);
      case TouchGuardCleared():
        _hideAutoClickWarning();
      default:
        break; // events from other features
    }
  });
}

@override
void dispose() {
  _sub.cancel();
  super.dispose();
}
```

| Event | Fields | Meaning |
|---|---|---|
| `SuspiciousTouchDetected` | `riskScore` | Confidence from 0 to 100 that the input is synthetic |
| | `reasons` | The signals behind the score, as native names such as `VIRTUAL_INPUT_DEVICE`, `ZERO_COORDINATE_JITTER`, `UNIFORM_TAP_INTERVAL` |
| `TouchGuardCleared` | — | Fires once when input looks human again |

---

## API reference

All methods are static on `CShieldBehavioralTouchGuard`.

| Method | Description |
|---|---|
| `protect({riskThreshold, blockWhenDetected = false, includeAccessibilitySignal = false})` | Guards the current screen and reports suspicious touches |
| `unprotect()` | Removes the guard and restores normal touch handling |

## Related

[anti-overlay.md](anti-overlay.md) can protect the same screen. When you use both, call the
`unprotect()` methods in the reverse order of the `protect()` calls.

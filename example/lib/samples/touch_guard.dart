// SAMPLE: Behavioral touch guard (auto-click detection). Android only.
//
// Scenario: a sensitive screen should notice taps produced by a machine: an
// auto-clicker, `adb shell input tap`, UiAutomator, injected events.
//
// You need: `protect()` when the screen appears, `unprotect()` when it goes
// away, and a listener on `CShieldEmbedded.events`.
//
// Guide: doc/behavioral-touch-guard.md.

import 'dart:async';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class TouchGuardSample extends StatefulWidget {
  const TouchGuardSample({super.key});

  @override
  State<TouchGuardSample> createState() => _TouchGuardSampleState();
}

class _TouchGuardSampleState extends State<TouchGuardSample> {
  // The guard exists on Android only; on iOS the calls are not implemented.
  static final _supported = defaultTargetPlatform == TargetPlatform.android;

  StreamSubscription<CShieldEvent>? _sub;
  String? _warning;
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    if (!_supported) return;

    // Observe only: suspicious taps are reported but still delivered. Pass
    // `blockWhenDetected: true` to swallow them as well.
    CShieldBehavioralTouchGuard.protect();

    _sub = CShieldEmbedded.events.listen((event) {
      switch (event) {
        case SuspiciousTouchDetected(:final riskScore, :final reasons):
          setState(() => _warning =
              'Suspected auto-click (score $riskScore): ${reasons.join(', ')}');
        case TouchGuardCleared():
          setState(() => _warning = null);
        default:
          break; // events of other features
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_supported) CShieldBehavioralTouchGuard.unprotect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Behavioral touch guard')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Tap the button by hand: nothing happens. Tap it with '
              '`adb shell input tap <x> <y>` or an auto-clicker: a warning appears.'),
          const SizedBox(height: 16),
          if (!_supported) const Text('Android only.'),
          if (_warning != null)
            Text(_warning!,
                style: const TextStyle(
                    color: Colors.deepOrange, fontWeight: FontWeight.bold)),
          FilledButton(
              onPressed: () => setState(() => _taps++),
              child: Text('Confirm OTP (taps: $_taps)')),
        ],
      ),
    );
  }
}

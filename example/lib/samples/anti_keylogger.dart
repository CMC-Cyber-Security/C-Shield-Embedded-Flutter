// SAMPLE: Anti-keylogger
//
// Scenario: warn the user when what they type could be captured by an
// untrusted keyboard or (Android) an untrusted accessibility service.
//
// You need: nothing to turn it on, the guard starts in `initialize()`.
// Listen on `CShieldEmbedded.events`, then call `runCheck()` once to catch a
// threat that was already present at startup.
//
// Platforms: the keyboard event is emitted on Android and iOS. The
// accessibility event, `configure()` and `runCheck()` are Android only (the
// calls do nothing on iOS, so no platform check is needed).
//
// Guide: doc/anti-keylogger.md.

import 'dart:async';

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';

class AntiKeyloggerSample extends StatefulWidget {
  const AntiKeyloggerSample({super.key});

  @override
  State<AntiKeyloggerSample> createState() => _AntiKeyloggerSampleState();
}

class _AntiKeyloggerSampleState extends State<AntiKeyloggerSample> {
  StreamSubscription<CShieldEvent>? _sub;
  String? _warning;

  @override
  void initState() {
    super.initState();
    _sub = CShieldEmbedded.events.listen((event) {
      switch (event) {
        case ThirdPartyKeyboardDetected(:final label, :final packageName):
          setState(() => _warning =
              'Untrusted keyboard: ${label.isNotEmpty ? label : packageName}');
        case SuspiciousAccessibilityServiceDetected(:final packageNames):
          setState(() => _warning =
              'Suspicious accessibility service: ${packageNames.join(', ')}');
        default:
          break; // events of other features
      }
    });

    // The guard reports changes, not the starting state: ask for it now.
    CShieldAntiKeylogger.runCheck();
  }

  /// Trust an extra keyboard (for example a company-internal one), then
  /// re-evaluate. An empty keyboard list keeps the native default list.
  Future<void> _trustInternalKeyboard() async {
    await CShieldAntiKeylogger.configure(
      trustedKeyboardPackages: ['com.company.internal_keyboard'],
    );
    setState(() => _warning = null);
    await CShieldAntiKeylogger.runCheck();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Anti-keylogger')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Switch to a third-party keyboard and come back: a warning appears. '
              'On Android the keyboard cannot be blocked, only reported.'),
          const SizedBox(height: 16),
          if (_warning != null)
            Text(_warning!,
                style: const TextStyle(
                    color: Colors.deepOrange, fontWeight: FontWeight.bold)),
          const TextField(
              decoration: InputDecoration(
                  labelText: 'Password', border: OutlineInputBorder())),
          FilledButton.tonal(
            onPressed: () {
              setState(() => _warning = null);
              CShieldAntiKeylogger.runCheck();
            },
            child: const Text('Check again (runCheck)'),
          ),
          FilledButton.tonal(
              onPressed: _trustInternalKeyboard,
              child: const Text('Trust an extra keyboard (configure)')),
        ],
      ),
    );
  }
}

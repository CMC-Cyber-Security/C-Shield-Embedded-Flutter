// C-Shield Embedded sample app.
//
// main() below is the part every integration needs. The rest of this file is
// a menu: each entry opens one self-contained sample from lib/samples/, and
// each sample file is complete on its own: it starts with a comment that says
// which scenario it covers and imports nothing from the other samples.

import 'package:c_shield_embedded/c_shield_embedded.dart';
import 'package:flutter/material.dart';

import 'demo_config.dart';
import 'samples/anti_keylogger.dart';
import 'samples/anti_overlay.dart';
import 'samples/basic_dio.dart';
import 'samples/basic_http.dart';
import 'samples/error_handling.dart';
import 'samples/malware_scan.dart';
import 'samples/manual_signing.dart';
import 'samples/required_level.dart';
import 'samples/selective_signing.dart';
import 'samples/sensitive_flow.dart';
import 'samples/startup_readiness.dart';
import 'samples/touch_guard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? startupError;
  try {
    // 1. Start the SDK, before runApp(). Device attestation begins in the
    //    background; this call does not wait for it.
    await CShieldEmbedded.initialize(
      license: DemoConfig.licenseUat,
      cloudProjectNumber: DemoConfig.cloudProjectNumber, // Android Play Integrity; null turns it off
    );

    // 2. Pin the API host. Declare EVERY pinned host in this one call: the pin
    //    set is sealed afterwards.
    await CShieldSSL.configureHosts(pinsByHost: {DemoConfig.pinnedHost: DemoConfig.pins});
  } on CShieldException catch (e) {
    // A failure here is a configuration problem (bad license, malformed pins).
    startupError = '${e.code.name}: ${e.message}';
  }

  runApp(SampleApp(startupError: startupError));
}

class SampleApp extends StatelessWidget {
  const SampleApp({super.key, this.startupError});

  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'C-Shield Embedded samples',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: startupError == null ? const SampleListPage() : _StartupErrorPage(message: startupError!),
    );
  }
}

class _StartupErrorPage extends StatelessWidget {
  const _StartupErrorPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('C-Shield failed to start.\n$message'),
        ),
      ),
    );
  }
}

/// One entry of the menu.
class _Sample {
  const _Sample(this.title, this.subtitle, this.builder, {this.enabled = true});

  final String title;
  final String subtitle;
  final WidgetBuilder builder;
  final bool enabled;
}

class SampleListPage extends StatelessWidget {
  const SampleListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final sections = <String, List<_Sample>>{
      'Protecting API calls': [
        _Sample('Basic setup (Dio)', 'Pinning + sign every request. Start here.', (_) => const BasicDioSample()),
        _Sample('Basic setup (http)', 'The same with package:http.', (_) => const BasicHttpSample()),
        _Sample('App start and readiness', 'Wait for attestation, status banner.', (_) => const StartupReadinessSample()),
        _Sample('Sensitive flow (ensureTrust)', 'Raise trust to L4 before payment / transfer.', (_) => const SensitiveFlowSample()),
        _Sample('Sensitive routes (requiredLevel)', 'Let the interceptor raise trust per route.', (_) => const RequiredLevelSample()),
        _Sample('Selective signing', 'Sign only some requests (signWhen).', (_) => const SelectiveSigningSample()),
        _Sample('Error handling', 'CShieldException, server rejections, messages.', (_) => const ErrorHandlingSample()),
        _Sample('Manual signing', 'Advanced: sign and verify without an interceptor.', (_) => const ManualSigningSample()),
      ],
      'Runtime guards': [
        _Sample('Anti-keylogger', 'Untrusted keyboard / accessibility service.', (_) => const AntiKeyloggerSample()),
        _Sample('Anti-overlay', 'Tapjacking guard. Android only.', (_) => const AntiOverlaySample()),
        _Sample('Behavioral touch guard', 'Auto-click detection. Android only.', (_) => const TouchGuardSample()),
        _Sample('Malware scan', 'Scan installed apps. Android only.', (_) => const AntiMalwareScanPage(), enabled: CShieldMalware.isSupported),
      ],
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('C-Shield Embedded samples'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: ListView(
        children: [
          for (final section in sections.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(section.key, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final sample in section.value)
              ListTile(
                title: Text(sample.title),
                subtitle: Text(sample.subtitle),
                trailing: const Icon(Icons.chevron_right),
                enabled: sample.enabled,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: sample.builder)),
              ),
          ],
        ],
      ),
    );
  }
}

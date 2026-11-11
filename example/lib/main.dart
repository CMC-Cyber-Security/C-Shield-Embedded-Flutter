import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:c_shield_embedded/c_shield_embedded.dart';

import 'anti_malware_scan_page.dart';

// Cấu hình Y HỆT Android sample: gọi demo-nodejs-server (Node SDK) + pin `**.onrender.com`.
const baseUrl = 'https://demo-nodejs-server.onrender.com';
// Pin cho *.onrender.com (leaf CN=onrender.com + 4 intermediate GTS WE1..WE4). Khớp Android ONRENDER_PINS.
const onrenderPins = [
  'sha256/8emdl/UmneUm0I4Y/vHzOTQzb9eJwG4voRHtMdNmBPk=', // leaf   CN=onrender.com (hết hạn 20/12/2026, cập nhật 09/11/2026)
  'sha256/kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=', // interm GTS WE1
  'sha256/vh78KSg1Ry4NaqGDV10w/cTb9VH3BQUZoCWNa93W/EY=', // interm GTS WE2
  'sha256/daBIAnKdRIX3bqM85I6We7wBUh0DPycNFBMvYkXGX2Q=', // interm GTS WE3
  'sha256/O5TQDB/wa4SkRjBrQL2Aq9CG317H9MDDgpTVcrpJDa4=', // interm GTS WE4
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize CShieldSdk.
  await CShieldEmbedded.initialize(
      cloudProjectNumber: '970898117522',
      license:
          'eyJraWQiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJhbGciOiJSUzI1NiJ9.eyJqdGkiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJpc3MiOiJwcm9tb24tbGljZW5zZSIsInN1YiI6IkNNQ0NTIiwiaWF0IjoxNzkxNzk1OTA0LCJuYmYiOjE3OTA4OTkyMDAsImV4cCI6NDEzMzk4MDc5OSwiYXBwbGljYXRpb25JZCI6ImNzaGllbGQtZW1iZWRkZWQtc2FtcGxlIiwicGFja2FnZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsImJ1bmRsZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsIm1vZHVsZXMiOlsiU0hJRUxEIl0sInBsYXRmb3JtcyI6WyJJT1MiLCJBTkRST0lEIl0sImVudmlyb25tZW50cyI6WyJQUk9EIiwiREVWIiwiU1RBR0lORyJdLCJvZmZsaW5lR3JhY2VEYXlzIjowLCJwbGFuIjoiU1RBTkRBUkQifQ.p7FVZPWlaQvw89sp8UdqACJres3UT9wPBCxxbTSQM5aPGMtz5ZhDVM9GX-laJUVyIR9tCM7o3tQlEFMWaxHks4d_YHqoqEjVyQSEdWYn3C0BMl_mtJV1Ja88yXJaw9s3za1Z3eiCv0NOdiepdeNzCao6dosRolZfqd9kgwHFFSuS4xUHJ1umpTbDxgTbi9rQga0iAJPc13oRTsRcnJ2C0dBOTfkWmHo9BDohGWB_wg54uAyswzi7toCChTdwxpdOeXsbmDBEbd75-lkcxzgJ8qNvqyFFpBfvDb_htHOvocOW9_L39MGFKov-QvzMIuSWpZ_S2ms99RsJUvgOtChe4A');
  try {
    await CShieldSSL.configureHosts(pinsByHost: {'**.onrender.com': onrenderPins});
  } on CShieldException catch (e) {
    // e.g. CShieldErrorCode.invalidArgument (bad pins/hostname) or a native
    // failure. Handle per e.code as needed; here we just log and continue.
    debugPrint('CShieldSSL.configure() failed: ${e.code.name} — ${e.message}');
  }
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const OtpPage(),
    );
  }
}

Dio buildDio() {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  try {
    dio.httpClientAdapter = CShieldSSL.createDioAdapter();
  } catch (e) {
    rethrow;
  }
  // Truyền `dio` để interceptor tự force-refresh + retry khi server 401 invalid-token.
  dio.interceptors.add(CShieldDioInterceptor(dio: dio));
  return dio;
}

/// Trích `code`/`message` của server từ [DioException] để hiển thị GỌN (vd `401: CSHIELD_SIGNATURE_MISMATCH`)
/// thay cho câu mặc định rất dài của Dio. Lưu ý: body lỗi (non-2xx) là **bytes thô** vì interceptor ép
/// `ResponseType.bytes` để verify chữ ký và response lỗi KHÔNG đi qua `onResponse` để decode như 2xx.
/// [CShieldException] (lỗi SDK: chưa sẵn sàng / pin mismatch…) được ưu tiên hiển thị.
String _serverError(DioException e) {
  final inner = e.error;
  if (inner is CShieldException) return '[${inner.code.name}] ${inner.message}';
  final status = e.response?.statusCode;
  final data = e.response?.data;
  Map<String, dynamic>? json;
  try {
    if (data is List<int>) {
      json = jsonDecode(utf8.decode(data, allowMalformed: true)) as Map<String, dynamic>;
    } else if (data is Map) {
      json = data.cast<String, dynamic>();
    } else if (data is String && data.isNotEmpty) {
      json = jsonDecode(data) as Map<String, dynamic>;
    }
  } catch (_) {}
  final code = json?['code'];
  if (code != null) {
    final msg = json?['message'];
    return '$status: $code${msg != null ? ' — $msg' : ''}';
  }
  return '${status ?? ''} ${e.message ?? e}'.trim();
}

class OtpPage extends StatefulWidget {
  const OtpPage({super.key});

  @override
  State<OtpPage> createState() => _OtpPageState();
}

class _OtpPageState extends State<OtpPage> {
  final _controller = TextEditingController();
  Dio? _dio;

  bool _loading = false;
  String _result = '';
  bool? _success;

  // Trạng thái attestation hiện tại (native đẩy lên qua stream, phát ngay state đầu tiên).
  AttestStateChanged? _attest;
  StreamSubscription<AttestStateChanged>? _attestSub;

  StreamSubscription<CShieldEvent>? _btgSub;
  String? _btgStatus;
  // Anti-Keylogger: detections arrive on the shared events stream.
  StreamSubscription<CShieldEvent>? _akSub;
  String? _akWarning;

  @override
  initState() {
    try {
      _dio = buildDio();
    } on CShieldException catch (e) {
      setState(() {
        _success = false;
        _result = '[${e.code.name}] ${e.message}';
      });
    }

    // Enroll chạy nền sau initialize → UI phản ánh INITIALIZING → READY/DEGRADED/UNAVAILABLE.
    _attestSub = CShieldAttest.stateChanges.listen((e) {
      if (mounted) setState(() => _attest = e);
    });

    // Behavioral Touch Guard: OTP là màn nhạy cảm — bật phát hiện auto-click.
    // Observe-only (blockWhenDetected: false); verdict tới qua CShieldEmbedded.events.
    CShieldBehavioralTouchGuard.protect(blockWhenDetected: false);
    _btgSub = CShieldEmbedded.events.listen((event) {
      if (!mounted) return;
      if (event is SuspiciousTouchDetected) {
        setState(() => _btgStatus =
            'Nghi ngờ auto-click (score=${event.riskScore}): ${event.reasons.join(', ')}');
      } else if (event is TouchGuardCleared) {
        setState(() => _btgStatus = null);
      }
    });
    // Listen for untrusted-keyboard / suspicious-accessibility detections.
    _akSub = CShieldEmbedded.events.listen((event) {
      switch (event) {
        case ThirdPartyKeyboardDetected(:final label, :final packageName):
          setState(() => _akWarning =
              'Untrusted keyboard: ${label.isNotEmpty ? label : packageName}');
        case SuspiciousAccessibilityServiceDetected(:final packageNames):
          setState(() =>
              _akWarning = 'Suspicious accessibility service: ${packageNames.join(', ')}');
        default:
          break; // license events, etc.
      }
    });
    // The guard doesn't auto-check at startup — pull the current posture now.
    CShieldAntiKeylogger.runCheck();

    super.initState();
  }

  @override
  void dispose() {
    _btgSub?.cancel();
    CShieldBehavioralTouchGuard.unprotect();
    _akSub?.cancel();
    _controller.dispose();
    _attestSub?.cancel();
    _dio?.close();
    super.dispose();
  }

  /// Luồng chuẩn cho endpoint nhạy: `ensureTrust(L4[, fresh])` TRƯỚC khi gọi API → đủ thì gọi,
  /// không đủ thì dừng ở client (server mới là chốt, nhưng client chủ động để khỏi tốn round-trip).
  Future<void> _runSensitive({required String path, required bool requireFresh}) async {
    setState(() {
      _loading = true;
      _result = '';
      _success = null;
    });
    try {
      final before = await CShieldAttest.currentTrustLevel();
      final ensured = await CShieldAttest.ensureTrust(TrustLevel.l4, requireFresh: requireFresh, timeoutMs: 20000);
      final after = await CShieldAttest.currentTrustLevel();
      final head = 'trust: ${before.id} → ${after.id} | '
          'ensureTrust(L4${requireFresh ? ', fresh' : ''})=${ensured.name}';

      if (ensured != EnsureTrustResult.satisfied) {
        setState(() {
          _success = false;
          _result = '$head\n$path: dừng ở client (chưa đạt trust yêu cầu)';
        });
        return;
      }

      final response = await _dio?.post(path);
      final data = (response?.data as Map).cast<String, dynamic>();
      setState(() {
        _success = data['code'] == 'OK';
        _result = '$head\n$path → ${data['code']}: ${data['message']}';
      });
    } on CShieldException catch (e) {
      setState(() {
        _success = false;
        _result = '$path lỗi: [${e.code.name}] ${e.message}';
      });
    } on DioException catch (e) {
      setState(() {
        _success = false;
        _result = '$path lỗi: ${_serverError(e)}';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final otp = _controller.text.trim();
    if (otp.isEmpty) return;

    setState(() {
      _loading = true;
      _result = '';
      _success = null;
    });

    if (_dio == null) {
      try {
        await Future.delayed(const Duration(milliseconds: 500));
        _dio = buildDio();
      } on CShieldException catch (e) {
        setState(() {
          _success = false;
          _result = '[${e.code.name}] ${e.message}';
        });
        return;
      } finally {
        setState(() => _loading = false);
      }
    }

    try {
      final response = await _dio?.post('/verify-otp', data: {'otp': otp});
      final data = response?.data as Map<String, dynamic>;
      setState(() {
        _success = data['code'] == 'OK';
        _result = '${data['message']}';
      });
    } on CShieldException catch (e) {
      setState(() {
        _success = false;
        _result = '[${e.code.name}] ${e.message}';
      });
    } on DioException catch (e) {
      setState(() {
        _success = false;
        _result = _serverError(e);
      });
    } catch (e) {
      setState(() {
        _success = false;
        _result = e.toString();
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OTP Verification'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard),
            tooltip: 'Re-check keyboard (Anti-Keylogger)',
            onPressed: () => CShieldAntiKeylogger.runCheck(),
          ),
          // Anti-malware chỉ có trên Android — ẩn nút trên iOS.
          if (CShieldMalware.isSupported)
            IconButton(
              icon: const Icon(Icons.security),
              tooltip: 'Anti-Malware Scan',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AntiMalwareScanPage()),
              ),
            ),
        ],
      ),
      // SingleChildScrollView: khi bàn phím nổi lên, body co lại → cho phép cuộn thay vì bottom overflow.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            AttestBanner(event: _attest),
            const SizedBox(height: 16),
            if (_btgStatus != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _btgStatus!,
                        style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            if (_akWarning != null) ...[
              const SizedBox(height: 16),
              _AntiKeyloggerBanner(
                message: _akWarning!,
                onDismiss: () => setState(() => _akWarning = null),
              ),
            ],
            const SizedBox(height: 32),
            TextField(
              controller: _controller,
              enabled: !_loading,
              decoration: const InputDecoration(labelText: 'OTP', hintText: 'Enter OTP', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Verify OTP'),
            ),
            const SizedBox(height: 24),
            // Route nhạy của demo server: /payment đòi L4; /transfer đòi L4 + attestation TƯƠI
            // (maxTrustAgeSeconds) → requireFresh=true. Cả hai đều tốn 1 lượt Play Integrity khi
            // phải nâng từ L3.
            OutlinedButton(
              onPressed: _loading ? null : () => _runSensitive(path: '/payment', requireFresh: false),
              child: const Text('Payment (ensureTrust L4)'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _loading ? null : () => _runSensitive(path: '/transfer', requireFresh: true),
              child: const Text('Transfer (ensureTrust L4 + fresh)'),
            ),
            if (_result.isNotEmpty) ...[const SizedBox(height: 24), ResultCard(message: _result, success: _success == true)],
          ],
        ),
      ),
    );
  }
}

class _AntiKeyloggerBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _AntiKeyloggerBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    const color = Colors.orange;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFE65100)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFFE65100), fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class ResultCard extends StatelessWidget {
  final String message;
  final bool success;

  const ResultCard({super.key, required this.message, required this.success});

  @override
  Widget build(BuildContext context) {
    final color = success ? Colors.green : Colors.red;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(success ? Icons.check_circle : Icons.error_outline, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hiển thị trạng thái attestation + trust level hiện tại (nguồn: [CShieldAttest.stateChanges]).
/// `UNAVAILABLE` là lỗi VĨNH VIỄN — app thật nên thông báo "thiết bị không hỗ trợ" và đừng retry;
/// `lastError` là mã lỗi ổn định (vd `device_blocked`, `attestation_not_enabled`).
class AttestBanner extends StatelessWidget {
  final AttestStateChanged? event;

  const AttestBanner({super.key, this.event});

  @override
  Widget build(BuildContext context) {
    final e = event;
    final (color, label) = switch (e?.state) {
      null => (Colors.grey, 'attest: …'),
      CShieldState.initializing => (Colors.orange, 'attest: INITIALIZING (đang enroll nền)'),
      CShieldState.ready => (Colors.green, 'attest: READY'),
      CShieldState.degraded => (Colors.orange, 'attest: DEGRADED (trust thấp)'),
      CShieldState.unavailable => (Colors.red, 'attest: UNAVAILABLE (đừng retry)'),
    };
    final detail = [
      if (e != null) 'trust=${e.trustLevel.id}',
      if (e?.lastError != null) 'lastError=${e!.lastError}',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail.isEmpty ? label : '$label · $detail',
              style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

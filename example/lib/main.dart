import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:c_shield_embedded/c_shield_embedded.dart';

import 'anti_malware_scan_page.dart';

const baseUrl = 'https://demo-spring-server.onrender.com';
const sslHostname = 'demo-spring-server.onrender.com';
const sslPins = ['sha256/kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4='];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize CShieldSdk.
  await CShieldEmbedded.initialize(
      license:
          'eyJraWQiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJhbGciOiJSUzI1NiJ9.eyJqdGkiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJpc3MiOiJwcm9tb24tbGljZW5zZSIsInN1YiI6IkNNQ0NTIiwiaWF0IjoxNzkwOTMyOTE4LCJuYmYiOjE3OTA4OTkyMDAsImV4cCI6NDEzMzk4MDc5OSwiYXBwbGljYXRpb25JZCI6ImNzaGllbGQtZW1iZWRkZWQtc2FtcGxlIiwicGFja2FnZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsImJ1bmRsZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsIm1vZHVsZXMiOlsiU0hJRUxEIl0sInBsYXRmb3JtcyI6WyJBTkRST0lEIiwiSU9TIl0sImVudmlyb25tZW50cyI6WyJQUk9EIiwiU1RBR0lORyIsIkRFViJdLCJvZmZsaW5lR3JhY2VEYXlzIjowfQ.FE-CTqKnXYnHoCH9YV9xdvM0ImggoqFbNEAHBvJk3HeWWbAs80BfQmnHHUdJnutZM1km_Sk2NX5Nv8SF-1NlAyCGv-ftYwBFq2DloraaiUR4v3JImPxf8h6xJS_Gfn_nbSikYt4GsvqDKsgp9zEFeMwZijC3RAGMdGXLzPF17judO4OucVV6DREv-UXlbhFTGnQTBCac0nR9eS94Sq7SVPA8csuRguc7Y1vxz_zH1q7GQyt91aYlEZ1AUOA-8n8BZt3PHO7WRZ2R53F3XQR30Oc-wxgeDPgYHV0vKC2SGTr6dpQtIoBM_bAWZyVtI-SQiMkqO7P_cwgURMAYFYsWZQ');
  try {
    await CShieldSSL.configure(pins: sslPins, hostname: sslHostname);
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
  dio.interceptors.add(const CShieldDioInterceptor());
  return dio;
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

    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    _dio?.close();
    super.dispose();
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
        final inner = e.error;
        if (inner is CShieldException) {
          _result = '[${inner.code.name}] ${inner.message}';
        } else {
          _result = e.message ?? e.toString();
        }
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
            icon: const Icon(Icons.security),
            tooltip: 'Anti-Malware Scan',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AntiMalwareScanPage()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            TextField(
              controller: _controller,
              enabled: !_loading,
              decoration: const InputDecoration(labelText: 'OTP', hintText: 'Enter OTP', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const SizedBox(
                      height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Verify OTP'),
            ),
            if (_result.isNotEmpty) ...[
              const SizedBox(height: 24),
              ResultCard(message: _result, success: _success == true)
            ],
          ],
        ),
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

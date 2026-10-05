// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:c_shield_embedded/c_shield_embedded.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('getPlatformVersion test', (WidgetTester tester) async {
    await CShieldEmbedded.initialize(
        license:
            'eyJraWQiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJhbGciOiJSUzI1NiJ9.eyJqdGkiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJpc3MiOiJwcm9tb24tbGljZW5zZSIsInN1YiI6IkNNQ0NTIiwiaWF0IjoxNzkwOTMyOTE4LCJuYmYiOjE3OTA4OTkyMDAsImV4cCI6NDEzMzk4MDc5OSwiYXBwbGljYXRpb25JZCI6ImNzaGllbGQtZW1iZWRkZWQtc2FtcGxlIiwicGFja2FnZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsImJ1bmRsZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsIm1vZHVsZXMiOlsiU0hJRUxEIl0sInBsYXRmb3JtcyI6WyJBTkRST0lEIiwiSU9TIl0sImVudmlyb25tZW50cyI6WyJQUk9EIiwiU1RBR0lORyIsIkRFViJdLCJvZmZsaW5lR3JhY2VEYXlzIjowfQ.FE-CTqKnXYnHoCH9YV9xdvM0ImggoqFbNEAHBvJk3HeWWbAs80BfQmnHHUdJnutZM1km_Sk2NX5Nv8SF-1NlAyCGv-ftYwBFq2DloraaiUR4v3JImPxf8h6xJS_Gfn_nbSikYt4GsvqDKsgp9zEFeMwZijC3RAGMdGXLzPF17judO4OucVV6DREv-UXlbhFTGnQTBCac0nR9eS94Sq7SVPA8csuRguc7Y1vxz_zH1q7GQyt91aYlEZ1AUOA-8n8BZt3PHO7WRZ2R53F3XQR30Oc-wxgeDPgYHV0vKC2SGTr6dpQtIoBM_bAWZyVtI-SQiMkqO7P_cwgURMAYFYsWZQ');
  });
}

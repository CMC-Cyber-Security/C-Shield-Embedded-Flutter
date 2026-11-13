/// Configuration of the demo app. Replace every value with your own when you
/// copy code from the samples.
abstract final class DemoConfig {
  /// The C-Shield license issued for this app's bundle id / application id.
  /// Choose license based on c-shield aar/xcframework builds (UAT vs PROD)
  static const licenseUat =
      "eyJraWQiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJhbGciOiJSUzI1NiJ9.eyJqdGkiOiJmOTE1NTUzOC02MzA4LTQ4MjctOTRiMy02NTA1ZGQ1YTZiZWUiLCJpc3MiOiJwcm9tb24tbGljZW5zZSIsInN1YiI6IkNNQ0NTIiwiaWF0IjoxNzkxNzk1OTA0LCJuYmYiOjE3OTA4OTkyMDAsImV4cCI6NDEzMzk4MDc5OSwiYXBwbGljYXRpb25JZCI6ImNzaGllbGQtZW1iZWRkZWQtc2FtcGxlIiwicGFja2FnZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsImJ1bmRsZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsIm1vZHVsZXMiOlsiU0hJRUxEIl0sInBsYXRmb3JtcyI6WyJJT1MiLCJBTkRST0lEIl0sImVudmlyb25tZW50cyI6WyJQUk9EIiwiREVWIiwiU1RBR0lORyJdLCJvZmZsaW5lR3JhY2VEYXlzIjowLCJwbGFuIjoiU1RBTkRBUkQifQ.p7FVZPWlaQvw89sp8UdqACJres3UT9wPBCxxbTSQM5aPGMtz5ZhDVM9GX-laJUVyIR9tCM7o3tQlEFMWaxHks4d_YHqoqEjVyQSEdWYn3C0BMl_mtJV1Ja88yXJaw9s3za1Z3eiCv0NOdiepdeNzCao6dosRolZfqd9kgwHFFSuS4xUHJ1umpTbDxgTbi9rQga0iAJPc13oRTsRcnJ2C0dBOTfkWmHo9BDohGWB_wg54uAyswzi7toCChTdwxpdOeXsbmDBEbd75-lkcxzgJ8qNvqyFFpBfvDb_htHOvocOW9_L39MGFKov-QvzMIuSWpZ_S2ms99RsJUvgOtChe4A";
  static const licenseProd =
      "eyJraWQiOiI1MzEwOTZlYS0xZTVjLTQzNmYtYWIzNC01Y2RjMmRmNjE2MDAiLCJhbGciOiJSUzI1NiJ9.eyJqdGkiOiI1MzEwOTZlYS0xZTVjLTQzNmYtYWIzNC01Y2RjMmRmNjE2MDAiLCJpc3MiOiJwcm9tb24tbGljZW5zZSIsInN1YiI6IkNNQ0NTIiwiaWF0IjoxNzk0NDc0NjMyLCJuYmYiOjE3OTQ0NDE2MDAsImV4cCI6NDEwMjQ0NDc5OSwiYXBwbGljYXRpb25JZCI6ImNzaGllbGQtZW1iZWRkZWQtc2FtcGxlIiwicGFja2FnZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsImJ1bmRsZUlkIjoiY29tLmNtYy5leGFtcGxlLmNzaGllbGRlbWJlZGRlZCIsIm1vZHVsZXMiOlsiU0hJRUxEIl0sInBsYXRmb3JtcyI6WyJBTkRST0lEIiwiSU9TIl0sImVudmlyb25tZW50cyI6WyJERVYiLCJTVEFHSU5HIiwiUFJPRCJdLCJvZmZsaW5lR3JhY2VEYXlzIjowLCJwbGFuIjoiUFJFTUlVTSJ9.ArZTuyrrGt_5EWO6tFEmnyMYc0vK4-J3NRHbP1Jef09xzhNjl1_8oY4zI4lXFenOrG3wDRNirdlv1Hq3nZ8Fl1qO9FUbTyx26RCMYDsY6WWX_YQKC9FGmayHGeVBwhyvj5_RQjUdVljXylJwY6eHMlGrSxShSAco_Rj8jNdUwjYd4knYVSvLDIMC9AUHFcbwXCgEwdqzto3dbaL-4Xb4jIL6r-S4gP4GK4hXGbhew9FQ65Ei5ZvjJQAMga_DalDLQzGGvLUNe9s-nwsIaEWp-i3h5mBry8z6Hz29ycW99_kZzG72Aw_QMWwtt00KsO5snzSax0oX42x9GQNbkYwt2A";

  /// Google Cloud project number for Play Integrity (Android). Run the app with
  /// `--dart-define=NO_PLAY_INTEGRITY=true` to start without it; see
  /// doc/attestation.md, "Running without Play Integrity".
  static const String? cloudProjectNumber = bool.fromEnvironment('NO_PLAY_INTEGRITY') ? null : '970898117522';

  /// The demo backend. It protects its routes with the C-Shield server SDK:
  ///
  /// - `POST /verify-otp`: signed request, default trust level.
  /// - `POST /payment`: requires trust level L4.
  /// - `POST /transfer`: requires L4 **and** fresh proof.
  static const baseUrl = 'https://demo-nodejs-server.onrender.com';

  /// Host pattern and pins for the demo backend: the leaf plus the issuing
  /// intermediates, so the app survives a leaf rotation.
  static const pinnedHost = '**.onrender.com';
  static const pins = [
    'sha256/8emdl/UmneUm0I4Y/vHzOTQzb9eJwG4voRHtMdNmBPk=', // leaf   CN=onrender.com (expires 2026-12-20)
    'sha256/kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=', // interm GTS WE1
    'sha256/vh78KSg1Ry4NaqGDV10w/cTb9VH3BQUZoCWNa93W/EY=', // interm GTS WE2
    'sha256/daBIAnKdRIX3bqM85I6We7wBUh0DPycNFBMvYkXGX2Q=', // interm GTS WE3
    'sha256/O5TQDB/wa4SkRjBrQL2Aq9CG317H9MDDgpTVcrpJDa4=', // interm GTS WE4
  ];
}

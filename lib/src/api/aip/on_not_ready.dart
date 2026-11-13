/// What an interceptor does when attestation is not ready at the moment a
/// request has to be signed (mirrors the native `OnNotReady`).
///
///  - [failFast] (default, fail-closed): throws a `CShieldException` with code
///    `CShieldErrorCode.notReady`. The request is **not sent**.
///  - [blockRetry]: if the error is retryable, waits briefly
///    (`CShieldAttest.awaitReady`) and tries to sign **once** more; throws if
///    that fails too.
///  - [passThrough]: sends the request **unsigned** and does not verify the
///    response. Use for non-sensitive endpoints only.
enum OnNotReady { failFast, blockRetry, passThrough }

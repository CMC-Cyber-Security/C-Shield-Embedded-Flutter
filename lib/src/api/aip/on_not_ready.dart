/// Hành vi của interceptor khi attestation CHƯA sẵn sàng lúc ký request (khớp native `OnNotReady`).
///
///  - [failFast] (mặc định, fail-closed): ném [CShieldException] mã
///    [CShieldErrorCode.notReady], **KHÔNG gửi** request.
///  - [blockRetry]: nếu lỗi `retryable` → chờ ngắn (`CShieldAttest.awaitReady`) rồi thử ký lại MỘT
///    lần; vẫn fail thì ném.
///  - [passThrough]: gửi request KHÔNG ký (và KHÔNG verify response) — CHỈ dùng cho endpoint
///    KHÔNG nhạy cảm.
enum OnNotReady { failFast, blockRetry, passThrough }

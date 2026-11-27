/// Safe, typed provider failures: transport errors never invalidate an account.
class ShelfApiException implements Exception {
  const ShelfApiException(this.message, {this.status, this.retryable = false});

  final String message;
  final int? status;
  final bool retryable;

  factory ShelfApiException.http(int status, {bool refreshing = false}) {
    if (status == 401 || (refreshing && status == 404)) {
      return const ShelfSignInRequired();
    }
    if (status == 429) {
      return ShelfApiException('轻书架请求过于频繁，请稍后重试。', status: status);
    }
    return ShelfApiException(
      status >= 500
          ? '轻书架服务暂时不可用（HTTP $status），请稍后重试。已保存的登录不会被清除。'
          : '轻书架暂时拒绝了请求（HTTP $status），请稍后重试。',
      status: status,
      retryable: const {500, 502, 503, 504}.contains(status),
    );
  }

  factory ShelfApiException.envelope(Map value) {
    final status = value['Status'] ?? value['status'];
    if (status == 401 || status == -100) return const ShelfSignInRequired();
    if (status is int && status >= 400) return ShelfApiException.http(status);
    // Do not expose arbitrary server text (which may contain request/session
    // details), or infer an expired account from an unrelated business error.
    return const ShelfApiException('轻书架未能完成请求，请稍后重试。');
  }

  @override
  String toString() => message;
}

class ShelfSignInRequired extends ShelfApiException {
  const ShelfSignInRequired()
    : super('轻书架需要登录，请在“我的 → 书源与账号”重新登录。', status: 401);
}

const shelfNetworkError = ShelfApiException(
  '轻书架连接中断，请检查网络后重试。已保存的登录不会被清除。',
  retryable: true,
);
const shelfTimeoutError = ShelfApiException(
  '轻书架响应超时，请稍后重试。已保存的登录不会被清除。',
  retryable: true,
);
const shelfInvalidResponse = ShelfApiException('轻书架返回的数据不完整，请稍后重试。');

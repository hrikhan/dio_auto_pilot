import 'dart:async';
import 'package:dio/dio.dart';

/// Callback to retrieve the current authentication token.
typedef TokenGetter = FutureOr<String?> Function();

/// Callback to execute the token refresh API call. Should return the new token, or null if failed.
typedef RefreshTokenCallback = Future<String?> Function();

/// Callback to evaluate if a response represents an unauthorized request (typically 401).
typedef UnauthorizedEvaluator = bool Function(Response response);

/// Optional callback triggered when a token has been successfully refreshed.
typedef TokenRefreshedCallback = FutureOr<void> Function(String token);

/// Formatter for the token value in the headers.
typedef HeaderBuilder = String Function(String token);

/// Configuration options for authentication and token refresh behavior.
class AuthOptions {
  /// Callback to retrieve the current token from cache/storage.
  final TokenGetter getToken;

  /// Callback to perform the actual token refresh network request.
  final RefreshTokenCallback refreshToken;

  /// Callback to check if a response indicates unauthorized status.
  final UnauthorizedEvaluator isUnauthorized;

  /// Callback to store or handle the newly refreshed token.
  final TokenRefreshedCallback? onTokenRefreshed;

  /// The header name for authorization, typically 'Authorization'.
  final String tokenHeaderName;

  /// Formatter for the authorization header, typically 'Bearer <token>'.
  final HeaderBuilder headerBuilder;

  AuthOptions({
    required this.getToken,
    required this.refreshToken,
    UnauthorizedEvaluator? isUnauthorized,
    this.onTokenRefreshed,
    this.tokenHeaderName = 'Authorization',
    HeaderBuilder? headerBuilder,
  })  : isUnauthorized = isUnauthorized ?? _defaultUnauthorizedEvaluator,
        headerBuilder = headerBuilder ?? _defaultHeaderBuilder;

  static bool _defaultUnauthorizedEvaluator(Response response) {
    return response.statusCode == 401;
  }

  static String _defaultHeaderBuilder(String token) {
    return 'Bearer $token';
  }
}

/// An interceptor that manages request authorization, detects unauthorized responses,
/// and executes a concurrency-safe token refresh flow.
class TokenRefreshInterceptor extends Interceptor {
  final Dio dio;
  final AuthOptions authOptions;

  Completer<String?>? _refreshCompleter;

  TokenRefreshInterceptor({
    required this.dio,
    required this.authOptions,
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    // If request specifies not to require authentication, skip attaching token
    if (options.extra['requiresAuth'] == false) {
      return handler.next(options);
    }

    // If a refresh is currently in progress, we must wait for it to complete
    // so we use the fresh token instead of the old/expired one.
    if (_refreshCompleter != null) {
      try {
        final newToken = await _refreshCompleter!.future;
        if (newToken != null) {
          options.headers[authOptions.tokenHeaderName] = authOptions.headerBuilder(newToken);
        }
      } catch (_) {
        // If the refresh failed, we proceed anyway (which will fail with 401 later)
      }
      return handler.next(options);
    }

    // Attach the current token
    try {
      final token = await authOptions.getToken();
      if (token != null) {
        options.headers[authOptions.tokenHeaderName] = authOptions.headerBuilder(token);
      }
    } catch (_) {
      // Proceed without token if retrieval fails
    }
    return handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;
    if (response == null || !authOptions.isUnauthorized(response)) {
      return handler.next(err);
    }

    final requestOptions = err.requestOptions;

    // Check if this request has already been retried due to token refresh
    final refreshRetryCount = requestOptions.extra['token_refresh_retry_count'] as int? ?? 0;
    if (refreshRetryCount >= 1) {
      // Already retried once after token refresh, let it fail to avoid infinite loops
      return handler.next(err);
    }

    String? newToken;
    final isInitiator = _refreshCompleter == null;

    if (isInitiator) {
      _refreshCompleter = Completer<String?>();
      try {
        newToken = await authOptions.refreshToken();
        if (newToken != null && authOptions.onTokenRefreshed != null) {
          await authOptions.onTokenRefreshed!(newToken);
        }
        _refreshCompleter!.complete(newToken);
      } catch (e, stackTrace) {
        _refreshCompleter!.completeError(e, stackTrace);
      } finally {
        _refreshCompleter = null;
      }
    } else {
      try {
        newToken = await _refreshCompleter!.future;
      } catch (e) {
        // Refresh failed for the initiator, propagate error
        return handler.next(err);
      }
    }

    if (newToken != null) {
      // Update header with the new token
      requestOptions.headers[authOptions.tokenHeaderName] = authOptions.headerBuilder(newToken);
      // Mark as retried
      requestOptions.extra['token_refresh_retry_count'] = refreshRetryCount + 1;

      try {
        // Retry the request
        final retryResponse = await dio.fetch(requestOptions);
        return handler.resolve(retryResponse);
      } on DioException catch (retryErr) {
        return handler.next(retryErr);
      }
    }

    return handler.next(err);
  }
}

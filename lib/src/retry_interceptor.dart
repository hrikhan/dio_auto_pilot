import 'dart:async';
import 'dart:math';
import 'package:dio/dio.dart';

/// Callback to evaluate if a request should be retried based on [DioException].
typedef RetryEvaluator = FutureOr<bool> Function(DioException error);

/// Configuration options for automatic retries.
class RetryOptions {
  /// The maximum number of retry attempts.
  final int maxAttempts;

  /// The initial delay before the first retry.
  final Duration initialDelay;

  /// The maximum delay between retries.
  final Duration maxDelay;

  /// The multiplier factor applied to the delay after each retry.
  final double backoffFactor;

  /// The random variance fraction added to delay (between 0.0 and 1.0).
  /// For example, 0.25 adds up to +/- 25% jitter.
  final double jitter;

  /// Callback to decide if a request should be retried.
  final RetryEvaluator retryEvaluator;

  const RetryOptions({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffFactor = 2.0,
    this.jitter = 0.25,
    RetryEvaluator? retryEvaluator,
  }) : retryEvaluator = retryEvaluator ?? _defaultRetryEvaluator;

  static bool _defaultRetryEvaluator(DioException error) {
    // Retry on network errors and timeouts
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return true;
    }
    // Retry on 5xx server status codes
    final statusCode = error.response?.statusCode;
    return statusCode != null && statusCode >= 500;
  }
}

/// An interceptor that adds automatic retries with exponential backoff and jitter.
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final RetryOptions retryOptions;

  RetryInterceptor({
    required this.dio,
    this.retryOptions = const RetryOptions(),
  });

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final requestOptions = err.requestOptions;

    // Check if the request has already been cancelled
    if (err.type == DioExceptionType.cancel) {
      return handler.next(err);
    }

    final currentAttempts = requestOptions.extra['retry_attempts'] as int? ?? 0;

    // Determine if we should retry
    if (currentAttempts < retryOptions.maxAttempts &&
        await retryOptions.retryEvaluator(err)) {
      final nextAttempts = currentAttempts + 1;
      requestOptions.extra['retry_attempts'] = nextAttempts;

      // Calculate exponential delay:
      // delay = initialDelay * (backoffFactor ^ (nextAttempts - 1))
      double delaySeconds = retryOptions.initialDelay.inMilliseconds / 1000.0 *
          pow(retryOptions.backoffFactor, nextAttempts - 1);

      // Apply jitter
      if (retryOptions.jitter > 0) {
        final random = Random();
        final minJitter = 1.0 - retryOptions.jitter;
        final maxJitter = 1.0 + retryOptions.jitter;
        final multiplier = minJitter + random.nextDouble() * (maxJitter - minJitter);
        delaySeconds *= multiplier;
      }

      var delay = Duration(milliseconds: (delaySeconds * 1000).round());
      if (delay > retryOptions.maxDelay) {
        delay = retryOptions.maxDelay;
      }

      await Future.delayed(delay);

      try {
        // Retry the request using the same method and options
        final response = await dio.fetch(requestOptions);
        return handler.resolve(response);
      } on DioException catch (retryErr) {
        // Let the subsequent error go through the error handling sequence (e.g. for further retries)
        return handler.next(retryErr);
      }
    }

    return handler.next(err);
  }
}

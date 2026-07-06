import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:dio_auto_pilot/dio_auto_pilot.dart';

class MockHttpClientAdapter implements HttpClientAdapter {
  int requestCount = 0;
  final Future<ResponseBody> Function(RequestOptions options, int requestCount) handler;

  MockHttpClientAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestCount++;
    return handler(options, requestCount);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('RetryInterceptor Tests', () {
    test('retries on 500 and succeeds eventually', () async {
      final client = DioAutoPilot(
        retryOptions: RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration.zero,
          backoffFactor: 1.0,
          jitter: 0.0,
          retryEvaluator: (error) => error.response?.statusCode == 500,
        ),
      );

      final adapter = MockHttpClientAdapter((options, count) async {
        if (count < 3) {
          return ResponseBody.fromString('', 500);
        }
        return ResponseBody.fromString('success', 200);
      });
      client.httpClientAdapter = adapter;

      final response = await client.get('/test');
      expect(response.statusCode, 200);
      expect(response.data, 'success');
      expect(adapter.requestCount, 3);
    });

    test('gives up after maxAttempts', () async {
      final client = DioAutoPilot(
        retryOptions: RetryOptions(
          maxAttempts: 2,
          initialDelay: Duration.zero,
          backoffFactor: 1.0,
          jitter: 0.0,
          retryEvaluator: (error) => error.response?.statusCode == 500,
        ),
      );

      final adapter = MockHttpClientAdapter((options, count) async {
        return ResponseBody.fromString('error', 500);
      });
      client.httpClientAdapter = adapter;

      await expectLater(
        client.get('/test'),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'statusCode', 500)),
      );

      // 1 original + 2 retries = 3 attempts total
      expect(adapter.requestCount, 3);
    });
  });

  group('TokenRefreshInterceptor Tests', () {
    test('successfully refreshes token on 401 and retries', () async {
      String currentToken = 'old_token';
      int refreshCount = 0;

      final client = DioAutoPilot(
        retryOptions: const RetryOptions(maxAttempts: 0),
        authOptions: AuthOptions(
          getToken: () => currentToken,
          refreshToken: () async {
            refreshCount++;
            currentToken = 'new_token';
            return 'new_token';
          },
          isUnauthorized: (response) => response.statusCode == 401,
        ),
      );

      final adapter = MockHttpClientAdapter((options, count) async {
        final authHeader = options.headers['Authorization'];
        if (authHeader == 'Bearer old_token') {
          return ResponseBody.fromString('Unauthorized', 401);
        }
        return ResponseBody.fromString('Authorized with: $authHeader', 200);
      });
      client.httpClientAdapter = adapter;

      final response = await client.get('/protected');
      expect(response.statusCode, 200);
      expect(response.data, 'Authorized with: Bearer new_token');
      expect(refreshCount, 1);
    });

    test('concurrency: multiple parallel 401s only trigger ONE refresh', () async {
      String currentToken = 'old_token';
      int refreshCount = 0;

      final client = DioAutoPilot(
        retryOptions: const RetryOptions(maxAttempts: 0),
        authOptions: AuthOptions(
          getToken: () => currentToken,
          refreshToken: () async {
            refreshCount++;
            await Future.delayed(const Duration(milliseconds: 50));
            currentToken = 'new_token';
            return 'new_token';
          },
          isUnauthorized: (response) => response.statusCode == 401,
        ),
      );

      final adapter = MockHttpClientAdapter((options, count) async {
        final authHeader = options.headers['Authorization'];
        if (authHeader == 'Bearer old_token') {
          return ResponseBody.fromString('Unauthorized', 401);
        }
        return ResponseBody.fromString('ok', 200);
      });
      client.httpClientAdapter = adapter;

      final responses = await Future.wait([
        client.get('/r1'),
        client.get('/r2'),
        client.get('/r3'),
      ]);

      for (final resp in responses) {
        expect(resp.statusCode, 200);
      }
      expect(refreshCount, 1);
    });

    test('failure: propagates original error when refresh fails', () async {
      final client = DioAutoPilot(
        retryOptions: const RetryOptions(maxAttempts: 0),
        authOptions: AuthOptions(
          getToken: () => 'old_token',
          refreshToken: () async => null,
          isUnauthorized: (response) => response.statusCode == 401,
        ),
      );

      final adapter = MockHttpClientAdapter((options, count) async {
        return ResponseBody.fromString('Unauthorized', 401);
      });
      client.httpClientAdapter = adapter;

      await expectLater(
        client.get('/protected'),
        throwsA(isA<DioException>().having((e) => e.response?.statusCode, 'statusCode', 401)),
      );
    });
  });
}

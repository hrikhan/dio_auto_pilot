## 0.1.0

* Initial release of `dio_auto_pilot`.
* Added `DioAutoPilot` client wrapper implementing `Dio`.
* Added automatic exponential-backoff retries with jitter support.
* Added a pluggable, concurrency-safe token-refresh mechanism to handle `401 Unauthorized` responses and queue concurrent requests.

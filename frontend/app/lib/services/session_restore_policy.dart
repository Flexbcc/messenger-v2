import 'api_client.dart';

/// Decides whether a failed server probe invalidates a locally valid session.
/// Availability failures must never rotate identity or force registration;
/// only an explicit authentication/device rejection can clear credentials.
class SessionRestorePolicy {
  const SessionRestorePolicy();

  bool shouldClear(Object error) =>
      error is ApiException &&
      (error.statusCode == 401 ||
          error.statusCode == 403 ||
          error.statusCode == 404);

  bool shouldRetain(Object error) => !shouldClear(error);
}

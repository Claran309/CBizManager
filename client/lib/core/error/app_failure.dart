sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.requestId});

  final String message;
  final String? requestId;

  @override
  String toString() => '$runtimeType(message: $message, requestId: $requestId)';
}

final class UnauthenticatedFailure extends AppFailure {
  const UnauthenticatedFailure(super.message, {super.requestId});
}

final class ForbiddenFailure extends AppFailure {
  const ForbiddenFailure(super.message, {super.requestId});
}

final class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, this.fields, {super.requestId});

  final Map<String, String> fields;
}

final class ConflictFailure extends AppFailure {
  const ConflictFailure(super.message, {super.requestId});
}

final class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message);
}

final class ServerFailure extends AppFailure {
  const ServerFailure(super.message, {super.requestId});
}

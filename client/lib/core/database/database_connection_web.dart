import 'package:drift/drift.dart';

Future<QueryExecutor> openDatabaseConnection() {
  return Future<QueryExecutor>.error(
    UnsupportedError('Web offline database is disabled in phase 1'),
  );
}

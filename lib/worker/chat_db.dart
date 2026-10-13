// SQLite database factory: sqflite on Android, iOS and macOS, sqflite's FFI
// implementation on Windows and Linux. The web has no SQLite (see
// chat_store.dart).

export 'chat_db_stub.dart' if (dart.library.ffi) 'chat_db_native.dart';

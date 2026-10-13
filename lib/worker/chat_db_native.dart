import 'dart:ffi';
import 'dart:io';

import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart';

/// Distributions ship libsqlite3.so.0; the unversioned name only comes with
/// the development package. Runs in the database isolate.
void _linuxInit() {
  open.overrideFor(OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open("libsqlite3.so.0");
    } catch (_) {
      return DynamicLibrary.open("libsqlite3.so");
    }
  });
}

DatabaseFactory chatDatabaseFactory() {
  if (Platform.isLinux) return createDatabaseFactoryFfi(ffiInit: _linuxInit);
  if (Platform.isWindows) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  return sqflite.databaseFactory;
}

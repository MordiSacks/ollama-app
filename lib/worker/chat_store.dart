// Chat storage.
//
// Chats live in a SQLite database: one row per chat, one row per message.
// Images are kept as files next to it instead of inline base64. The chat
// list is cached in memory ([chatList]) so the sidebar can be built
// synchronously; a chat's messages are read when it is opened, and saving a
// chat rewrites only that chat.
//
// The web has no SQLite; there every chat is its own SharedPreferences entry.
// If the database can't be opened (e.g. a Linux system without libsqlite3)
// the same fallback is used.
//
// Chats used to be one SharedPreferences string list ("chats"). They are
// moved into the store on first start, after a copy of the old list was
// written to chats-backup.json.
//
// Export and import keep that old format: a JSON list of encoded chats whose
// "messages" field is itself encoded JSON, system prompt first. Older
// exports import fine and newer exports still load in older versions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'chat_db.dart';

class ChatInfo {
  final String uuid;
  String title;
  String? model;
  String? provider;
  String? system;
  int createdAt;
  int updatedAt;

  ChatInfo(
      {required this.uuid,
      required this.title,
      this.model,
      this.provider,
      this.system,
      int? createdAt,
      int? updatedAt})
      : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory ChatInfo.fromMap(Map map) => ChatInfo(
      uuid: map["uuid"].toString(),
      title: map["title"]?.toString() ?? "",
      model: map["model"]?.toString(),
      provider: map["provider"]?.toString(),
      system: map["system"]?.toString(),
      createdAt: _int(map["created_at"]),
      updatedAt: _int(map["updated_at"]));

  Map<String, Object?> toMap() => {
        "uuid": uuid,
        "title": title,
        "model": model,
        "provider": provider,
        "system": system,
        "created_at": createdAt,
        "updated_at": updatedAt
      };
}

const String messageText = "text";
const String messageImage = "image";
const String messageFile = "file";

class StoredMessage {
  final String id;
  final String role; // "user" or "assistant"
  final String type; // messageText, messageImage or messageFile
  final String? name;
  final int? size;

  /// Text of a text message, extracted text of a file, base64 of an image.
  final String content;
  final int? createdAt;

  /// Everything else about the message: reasoning, usage statistics, ...
  final Map<String, dynamic>? meta;

  StoredMessage(
      {String? id,
      required this.role,
      this.type = messageText,
      this.name,
      this.size,
      required this.content,
      this.createdAt,
      this.meta})
      : id = id ?? const Uuid().v4();
}

int? _int(Object? value) =>
    value is int ? value : int.tryParse(value?.toString() ?? "");

Map<String, dynamic>? _meta(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String && value.isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  return null;
}

// ---------------------------------------------------------------------------
// backends

abstract class _Backend {
  Future<List<ChatInfo>> chats();
  Future<List<StoredMessage>> messages(String uuid);
  Future<void> putChat(ChatInfo chat);
  Future<void> putMessages(String uuid, List<StoredMessage> messages);
  Future<void> deleteChat(String uuid);
  Future<void> clear();
}

class _SqliteBackend implements _Backend {
  final Database db;
  final Directory images;

  _SqliteBackend(this.db, this.images);

  static Future<_SqliteBackend> open(
      DatabaseFactory factory, Directory directory) async {
    final db = await factory.openDatabase(
        "${directory.path}${Platform.pathSeparator}chats.db",
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, version) async {
              await db.execute("""
                CREATE TABLE chats (
                  uuid TEXT PRIMARY KEY,
                  title TEXT NOT NULL,
                  model TEXT,
                  provider TEXT,
                  system TEXT,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL)""");
              await db.execute("""
                CREATE TABLE messages (
                  chat_uuid TEXT NOT NULL,
                  position INTEGER NOT NULL,
                  id TEXT NOT NULL,
                  role TEXT NOT NULL,
                  type TEXT NOT NULL,
                  name TEXT,
                  size INTEGER,
                  content TEXT NOT NULL,
                  created_at INTEGER,
                  meta TEXT,
                  PRIMARY KEY (chat_uuid, position))""");
              await db.execute(
                  "CREATE INDEX chats_updated ON chats (updated_at DESC)");
            }));
    return _SqliteBackend(
        db, Directory("${directory.path}${Platform.pathSeparator}images"));
  }

  Directory _imageDir(String uuid) =>
      Directory("${images.path}${Platform.pathSeparator}$uuid");

  File _imageFile(String uuid, String id) => File(
      "${_imageDir(uuid).path}${Platform.pathSeparator}${id.replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "_")}");

  @override
  Future<List<ChatInfo>> chats() async =>
      (await db.query("chats", orderBy: "updated_at DESC"))
          .map(ChatInfo.fromMap)
          .toList();

  @override
  Future<List<StoredMessage>> messages(String uuid) async {
    final rows = await db.query("messages",
        where: "chat_uuid = ?", whereArgs: [uuid], orderBy: "position");
    final List<StoredMessage> result = [];
    for (final row in rows) {
      final type = row["type"].toString();
      var content = row["content"].toString();
      if (type == messageImage) {
        try {
          content = base64.encode(
              await _imageFile(uuid, row["id"].toString()).readAsBytes());
        } catch (_) {
          continue; // the image is gone; skip it rather than fail the chat
        }
      }
      result.add(StoredMessage(
          id: row["id"].toString(),
          role: row["role"].toString(),
          type: type,
          name: row["name"]?.toString(),
          size: _int(row["size"]),
          content: content,
          createdAt: _int(row["created_at"]),
          meta: _meta(row["meta"])));
    }
    return result;
  }

  @override
  Future<void> putChat(ChatInfo chat) async {
    final updated = await db.update("chats", chat.toMap(),
        where: "uuid = ?", whereArgs: [chat.uuid]);
    if (updated == 0) await db.insert("chats", chat.toMap());
  }

  @override
  Future<void> putMessages(String uuid, List<StoredMessage> messages) async {
    // images are written once; their file name is the message id
    final Set<String> keep = {};
    for (final message in messages) {
      if (message.type != messageImage) continue;
      final file = _imageFile(uuid, message.id);
      keep.add(file.path);
      if (await file.exists()) continue;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64.decode(message.content), flush: true);
    }

    await db.transaction((txn) async {
      await txn.delete("messages", where: "chat_uuid = ?", whereArgs: [uuid]);
      final batch = txn.batch();
      for (var i = 0; i < messages.length; i++) {
        final message = messages[i];
        batch.insert("messages", {
          "chat_uuid": uuid,
          "position": i,
          "id": message.id,
          "role": message.role,
          "type": message.type,
          "name": message.name,
          "size": message.size,
          "content": message.type == messageImage ? "" : message.content,
          "created_at": message.createdAt,
          "meta": (message.meta == null || message.meta!.isEmpty)
              ? null
              : jsonEncode(message.meta)
        });
      }
      await batch.commit(noResult: true);
    });

    // drop images of messages that were deleted from the chat
    final dir = _imageDir(uuid);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File && !keep.contains(entity.path)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
  }

  @override
  Future<void> deleteChat(String uuid) async {
    await db.transaction((txn) async {
      await txn.delete("messages", where: "chat_uuid = ?", whereArgs: [uuid]);
      await txn.delete("chats", where: "uuid = ?", whereArgs: [uuid]);
    });
    try {
      await _imageDir(uuid).delete(recursive: true);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    await db.transaction((txn) async {
      await txn.delete("messages");
      await txn.delete("chats");
    });
    try {
      await images.delete(recursive: true);
    } catch (_) {}
  }
}

/// One SharedPreferences entry per chat plus an index ("chatIndex").
class _PrefsBackend implements _Backend {
  final SharedPreferences prefs;

  _PrefsBackend(this.prefs);

  List<ChatInfo> _index() {
    try {
      return (jsonDecode(prefs.getString("chatIndex") ?? "[]") as List)
          .whereType<Map>()
          .map(ChatInfo.fromMap)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveIndex(List<ChatInfo> index) => prefs.setString(
      "chatIndex", jsonEncode(index.map((c) => c.toMap()).toList()));

  @override
  Future<List<ChatInfo>> chats() async =>
      _index()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<List<StoredMessage>> messages(String uuid) async {
    try {
      return (jsonDecode(prefs.getString("chat.$uuid") ?? "[]") as List)
          .whereType<Map>()
          .map((m) => StoredMessage(
              id: m["id"]?.toString(),
              role: m["role"].toString(),
              type: m["type"]?.toString() ?? messageText,
              name: m["name"]?.toString(),
              size: _int(m["size"]),
              content: m["content"]?.toString() ?? "",
              createdAt: _int(m["createdAt"]),
              meta: _meta(m["meta"])))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> putChat(ChatInfo chat) async {
    final index = _index()..removeWhere((c) => c.uuid == chat.uuid);
    await _saveIndex(index..add(chat));
  }

  @override
  Future<void> putMessages(String uuid, List<StoredMessage> messages) =>
      prefs.setString(
          "chat.$uuid",
          jsonEncode(messages
              .map((m) => {
                    "id": m.id,
                    "role": m.role,
                    "type": m.type,
                    if (m.name != null) "name": m.name,
                    if (m.size != null) "size": m.size,
                    "content": m.content,
                    if (m.createdAt != null) "createdAt": m.createdAt,
                    if (m.meta != null && m.meta!.isNotEmpty) "meta": m.meta
                  })
              .toList()));

  @override
  Future<void> deleteChat(String uuid) async {
    await prefs.remove("chat.$uuid");
    await _saveIndex(_index()..removeWhere((c) => c.uuid == uuid));
  }

  @override
  Future<void> clear() async {
    for (final chat in _index()) {
      await prefs.remove("chat.${chat.uuid}");
    }
    await prefs.remove("chatIndex");
  }
}

// ---------------------------------------------------------------------------
// store

/// All chats, most recently used first.
List<ChatInfo> chatList = [];

_Backend? _backend;

// Every database access runs in order, so a read sees all earlier saves.
Future<void> _queue = Future.value();

Future<T> _enqueue<T>(Future<T> Function(_Backend backend) task) {
  final result = _queue.then((_) => task(_backend!));
  _queue = result.then((_) {}, onError: (Object e) {
    debugPrint("chat store: $e");
  });
  return result;
}

/// Opens the store, moves chats out of the old SharedPreferences list and
/// loads [chatList]. [directory] and [factory] are for tests.
Future<void> initChatStore(SharedPreferences prefs,
    {Directory? directory, DatabaseFactory? factory}) async {
  _backend = null;
  if (!kIsWeb) {
    try {
      directory ??= await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      _backend = await _SqliteBackend.open(
          factory ?? chatDatabaseFactory(), directory);
    } catch (e) {
      debugPrint("chat store: SQLite unavailable ($e), using preferences");
    }
  }
  _backend ??= _PrefsBackend(prefs);
  _queue = Future.value();

  final legacy = prefs.getStringList("chats");
  if (legacy != null) {
    try {
      if (legacy.isNotEmpty && directory != null) {
        await File(
                "${directory.path}${Platform.pathSeparator}chats-backup.json")
            .writeAsString(jsonEncode(legacy), flush: true);
      }
      await _import(legacy, replace: false);
      await prefs.remove("chats");
    } catch (e) {
      // keep the old list; the next start tries again
      debugPrint("chat store: moving old chats failed ($e)");
    }
  }

  try {
    chatList = await _enqueue((b) => b.chats());
  } catch (e) {
    debugPrint("chat store: $e");
    chatList = [];
  }
}

ChatInfo? findChat(String? uuid) {
  for (final chat in chatList) {
    if (chat.uuid == uuid) return chat;
  }
  return null;
}

/// Adds an empty chat at the top of the list.
void createChat(String uuid, String title) {
  final chat = ChatInfo(uuid: uuid, title: title);
  chatList.insert(0, chat);
  _enqueue((b) => b.putChat(chat));
}

void renameChat(String uuid, String title) {
  final chat = findChat(uuid);
  if (chat == null) return;
  chat.title = title;
  _enqueue((b) => b.putChat(chat));
}

void removeChat(String uuid) {
  chatList.removeWhere((c) => c.uuid == uuid);
  _enqueue((b) => b.deleteChat(uuid));
}

/// Replaces the messages of chat [uuid] and moves it to the top.
Future<void> storeChat(String uuid, List<StoredMessage> messages,
    {String? model, String? provider, String? system}) async {
  final chat = findChat(uuid);
  if (chat == null) return;
  chat.model = model;
  chat.provider = provider;
  chat.system ??= system;
  chat.updatedAt = DateTime.now().millisecondsSinceEpoch;
  chatList
    ..remove(chat)
    ..insert(0, chat);
  final copy = List.of(messages);
  await _enqueue((b) async {
    await b.putChat(chat);
    await b.putMessages(uuid, copy);
  });
}

Future<List<StoredMessage>> chatMessages(String uuid) =>
    _enqueue((b) => b.messages(uuid));

// ---------------------------------------------------------------------------
// export / import

/// All chats in the export format.
Future<String> exportChats() async {
  final List<String> result = [];
  for (final chat in List.of(chatList)) {
    final messages = await chatMessages(chat.uuid);
    result.add(jsonEncode({
      "title": chat.title,
      "uuid": chat.uuid,
      "model": chat.model,
      "provider": chat.provider,
      "createdAt": chat.createdAt,
      "updatedAt": chat.updatedAt,
      "messages": jsonEncode([
        {"role": "system", "content": chat.system ?? ""},
        ...messages.map((m) => {
              "role": m.role,
              "content": m.content,
              if (m.type != messageText) "type": m.type,
              if (m.name != null) "name": m.name,
              if (m.size != null) "size": m.size.toString(),
              // read by older versions of the app
              if (m.meta?["thinking"] != null)
                "thinking": m.meta!["thinking"].toString(),
              if (m.meta?["thinkingMs"] != null)
                "thinkingMs": m.meta!["thinkingMs"].toString(),
              if (m.createdAt != null) "createdAt": m.createdAt,
              if (m.meta != null && m.meta!.isNotEmpty) "meta": m.meta
            })
      ])
    }));
  }
  return jsonEncode(result);
}

/// Imports an export. With [replace] all existing chats are deleted first,
/// otherwise chats are added and ones that already exist (same id) are
/// overwritten. Returns the number of chats imported; throws if [content]
/// isn't an export.
Future<int> importChats(String content, {required bool replace}) async {
  final decoded = jsonDecode(content);
  if (decoded is! List) throw const FormatException("not a chat export");
  final count = await _import(decoded, replace: replace);
  chatList = await _enqueue((b) => b.chats());
  return count;
}

Future<int> _import(List items, {required bool replace}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final List<(ChatInfo, List<StoredMessage>)> chats = [];
  for (var i = 0; i < items.length; i++) {
    final parsed = _parseExported(items[i], now - i);
    if (parsed != null) chats.add(parsed);
  }
  if (items.isNotEmpty && chats.isEmpty) {
    throw const FormatException("no chats found");
  }
  await _enqueue((b) async {
    if (replace) await b.clear();
    for (final (chat, messages) in chats) {
      await b.putChat(chat);
      await b.putMessages(chat.uuid, messages);
    }
  });
  return chats.length;
}

(ChatInfo, List<StoredMessage>)? _parseExported(
    Object? item, int fallbackTime) {
  try {
    final chat = item is String ? jsonDecode(item) : item;
    if (chat is! Map) return null;
    var history = chat["messages"];
    if (history is String) history = jsonDecode(history);
    if (history is! List) history = [];

    String? system;
    final List<StoredMessage> messages = [];
    for (final entry in history.whereType<Map>()) {
      final role = entry["role"]?.toString() ?? "user";
      if (role == "system") {
        system ??= entry["content"]?.toString();
        continue;
      }
      var meta = _meta(entry["meta"]);
      if (meta == null && (entry["thinking"]?.toString() ?? "").isNotEmpty) {
        meta = {
          "thinking": entry["thinking"].toString(),
          if (_int(entry["thinkingMs"]) != null)
            "thinkingMs": _int(entry["thinkingMs"])
        };
      }
      final type = entry["type"]?.toString() ?? messageText;
      final content = entry["content"]?.toString() ?? "";
      if (type == messageImage) {
        try {
          base64.decode(content);
        } catch (_) {
          continue;
        }
      }
      messages.add(StoredMessage(
          role: role == "assistant" ? "assistant" : "user",
          type: (type == messageImage || type == messageFile)
              ? type
              : messageText,
          name: entry["name"]?.toString(),
          size: _int(entry["size"]),
          content: content,
          createdAt: _int(entry["createdAt"]),
          meta: meta));
    }

    final updated = _int(chat["updatedAt"]) ?? fallbackTime;
    return (
      ChatInfo(
          uuid: chat["uuid"]?.toString() ?? const Uuid().v4(),
          title: chat["title"]?.toString() ?? "",
          model: chat["model"]?.toString(),
          provider: chat["provider"]?.toString(),
          system: system,
          createdAt: _int(chat["createdAt"]) ?? updated,
          updatedAt: updated),
      messages
    );
  } catch (_) {
    return null;
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/worker/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ollama_app/worker/chat_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final String png = base64.encode([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);

String legacyChat(String uuid, String title, {bool image = false}) =>
    jsonEncode({
      "title": title,
      "uuid": uuid,
      "model": "qwen3:8b",
      "provider": "ollama",
      "messages": jsonEncode([
        {"role": "system", "content": "You are a helpful assistant"},
        if (image)
          {
            "role": "user",
            "type": "image",
            "name": "cat.png",
            "size": "11",
            "content": png
          },
        {
          "role": "user",
          "type": "file",
          "name": "notes.txt",
          "size": "5",
          "content": "hello"
        },
        {"role": "user", "content": "Hi"},
        {
          "role": "assistant",
          "content": "Hello!",
          "thinking": "greet back",
          "thinkingMs": "1200"
        }
      ])
    });

void main() {
  for (final sqlite in [true, false]) {
    group(sqlite ? "sqlite" : "preferences fallback", () {
      tests(chatDatabaseFactory(), sqlite);
    });
  }
}

void tests(DatabaseFactory factory, bool sqlite) {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp("chat_store_test");
    // a directory where the database file should be: SQLite can't open it
    if (!sqlite) await Directory("${dir.path}/chats.db").create();
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<SharedPreferences> open(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    await initChatStore(prefs, directory: dir, factory: factory);
    return prefs;
  }

  test("moves the old chat list into the database", () async {
    final prefs = await open({
      "chats": [
        legacyChat("a", "Newest", image: true),
        legacyChat("b", "Older")
      ]
    });

    expect(prefs.getStringList("chats"), isNull);
    expect(File("${dir.path}/chats-backup.json").existsSync(), isTrue);
    expect(FileSystemEntity.isFileSync("${dir.path}/chats.db"), sqlite);
    expect(chatList.map((c) => c.uuid), ["a", "b"]);
    expect(chatList.first.model, "qwen3:8b");
    expect(chatList.first.system, "You are a helpful assistant");

    final messages = await chatMessages("a");
    expect(messages.map((m) => m.type), ["image", "file", "text", "text"]);
    expect(messages[0].content, png);
    expect(messages[1].content, "hello");
    expect(messages[3].meta, {"thinking": "greet back", "thinkingMs": 1200});
    // the image is a file, not a database value
    if (sqlite) {
      expect(Directory("${dir.path}/images/a").listSync(), hasLength(1));
    }
  });

  test("saving rewrites one chat and moves it to the top", () async {
    await open({
      "chats": [legacyChat("a", "A", image: true), legacyChat("b", "B")]
    });
    final messages = await chatMessages("b");
    await storeChat(
        "b",
        [
          ...messages,
          StoredMessage(
              role: "assistant", content: "more", meta: {"usage": 3})
        ],
        model: "llama3",
        provider: "ollama");

    expect(chatList.map((c) => c.uuid), ["b", "a"]);
    final saved = await chatMessages("b");
    expect(saved, hasLength(4));
    expect(saved.last.meta, {"usage": 3});

    // dropping the image message deletes its file
    final a = await chatMessages("a");
    await storeChat("a", a.where((m) => m.type != messageImage).toList());
    if (sqlite) {
      expect(Directory("${dir.path}/images/a").listSync(), isEmpty);
    }
  });

  test("survives a restart", () async {
    final prefs = await open({});
    createChat("x", "New chat");
    renameChat("x", "Renamed");
    await storeChat("x", [StoredMessage(role: "user", content: "hi")]);
    await initChatStore(prefs, directory: dir, factory: factory);
    expect(chatList.single.title, "Renamed");
    expect((await chatMessages("x")).single.content, "hi");
  });

  test("export and import round trip, merge and replace", () async {
    await open({
      "chats": [legacyChat("a", "A", image: true), legacyChat("b", "B")]
    });
    final export = await exportChats();

    // the export still reads like the old format
    final first = jsonDecode((jsonDecode(export) as List).first as String);
    expect(first["uuid"], "a");
    final history = jsonDecode(first["messages"]) as List;
    expect(history.first["role"], "system");
    expect(history.last["thinking"], "greet back");

    removeChat("b");
    createChat("c", "Local only");
    await storeChat("c", [StoredMessage(role: "user", content: "keep me")]);

    expect(await importChats(export, replace: false), 2);
    expect(chatList.map((c) => c.uuid).toSet(), {"a", "b", "c"});
    expect((await chatMessages("a")).first.content, png);

    expect(await importChats(export, replace: true), 2);
    expect(chatList.map((c) => c.uuid).toSet(), {"a", "b"});

    expect(() => importChats("{}", replace: true), throwsFormatException);
    expect(chatList, hasLength(2));
  });

  test("removing a chat deletes its messages and images", () async {
    await open({
      "chats": [legacyChat("a", "A", image: true)]
    });
    removeChat("a");
    expect(await chatMessages("a"), isEmpty);
    if (sqlite) {
      expect(Directory("${dir.path}/images/a").existsSync(), isFalse);
    }
  });
}

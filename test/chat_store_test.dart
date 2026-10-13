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

/// The bytes of an image message, wherever the store keeps them.
List<int> imageBytes(StoredMessage message) => message.dataPath != null
    ? File(message.dataPath!).readAsBytesSync()
    : base64.decode(message.content);

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
    expect(imageBytes(messages[0]), base64.decode(png));
    // on SQLite an image is a file, not a database value
    expect(messages[0].content, sqlite ? isEmpty : png);
    expect(messages[1].content, "hello");
    expect(messages[3].meta, {"thinking": "greet back", "thinkingMs": 1200});
    // the image is a file, not a database value
    if (sqlite) {
      expect(Directory("${dir.path}/attachments/a").listSync(), hasLength(1));
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
          StoredMessage(role: "assistant", content: "more", meta: {"usage": 3})
        ],
        model: "llama3",
        provider: "ollama");

    expect(chatList.map((c) => c.uuid), ["b", "a"]);
    final saved = await chatMessages("b");
    expect(saved, hasLength(4));
    expect(saved.last.meta, {"usage": 3});

    // dropping the image message keeps its file (for undo) until the
    // clean-up runs
    final a = await chatMessages("a");
    await storeChat("a", a.where((m) => m.type != messageImage).toList());
    if (sqlite) {
      expect(Directory("${dir.path}/attachments/a").listSync(), hasLength(1));
    }
    // undo: saving the old messages again brings the image back
    await storeChat("a", a);
    expect(imageBytes((await chatMessages("a")).first), base64.decode(png));

    await storeChat("a", a.where((m) => m.type != messageImage).toList());
    await cleanUpChatFiles("a");
    if (sqlite) {
      expect(Directory("${dir.path}/attachments/a").listSync(), isEmpty);
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
    expect(imageBytes((await chatMessages("a")).first), base64.decode(png));

    expect(await importChats(export, replace: true), 2);
    expect(chatList.map((c) => c.uuid).toSet(), {"a", "b"});

    expect(() => importChats("{}", replace: true), throwsFormatException);
    expect(chatList, hasLength(2));
  });

  test("keeps the original of an attached file", () async {
    await open({});
    final original = File("${dir.path}/picked.pdf")
      ..writeAsBytesSync([37, 80, 68, 70]);
    createChat("f", "File");
    final file = StoredMessage(
        role: "user",
        type: messageFile,
        name: "report.pdf",
        size: 4,
        content: "extracted text",
        dataPath: original.path);
    await storeChat("f", [file]);
    original.deleteSync(); // the picker's copy may vanish

    final loaded = (await chatMessages("f")).single;
    expect(loaded.content, "extracted text");
    if (sqlite) {
      expect(loaded.dataPath, endsWith(".pdf"));
      expect(File(loaded.dataPath!).readAsBytesSync(), [37, 80, 68, 70]);
      // saving again keeps it; deleting the message removes it
      await storeChat("f", [loaded]);
      expect(File(loaded.dataPath!).existsSync(), isTrue);
      await storeChat("f", [StoredMessage(role: "user", content: "x")]);
      expect(File(loaded.dataPath!).existsSync(), isTrue);
      await cleanUpChatFiles("f");
      expect(File(loaded.dataPath!).existsSync(), isFalse);
    } else {
      expect(loaded.dataPath, isNull);
    }
  });

  test("a chat emptied for undo keeps its files until the sweep", () async {
    await open({
      "chats": [legacyChat("a", "A", image: true)]
    });
    final messages = await chatMessages("a");
    removeChat("a", keepFiles: true);
    expect(chatList, isEmpty);

    // undo
    createChat("a", "A");
    await storeChat("a", messages);
    expect(imageBytes((await chatMessages("a")).first), base64.decode(png));

    // no undo: the sweep at the next start removes the folder
    removeChat("a", keepFiles: true);
    if (sqlite) {
      expect(Directory("${dir.path}/attachments/a").existsSync(), isTrue);
    }
    await sweepChatFiles();
    if (sqlite) {
      expect(Directory("${dir.path}/attachments/a").existsSync(), isFalse);
    }
  });

  test("moves the old images folder to attachments", () async {
    if (!sqlite) return;
    await open({
      "chats": [legacyChat("a", "A", image: true)]
    });
    final file = File((await chatMessages("a")).first.dataPath!);
    final prefs = await SharedPreferences.getInstance();
    await Directory("${dir.path}/attachments").rename("${dir.path}/images");
    await initChatStore(prefs, directory: dir, factory: factory);
    expect(Directory("${dir.path}/images").existsSync(), isFalse);
    expect(file.existsSync(), isTrue);
    expect((await chatMessages("a")).first.dataPath, file.path);
  });

  test("exports images inline, without paths", () async {
    await open({
      "chats": [legacyChat("a", "A", image: true)]
    });
    final export = await exportChats();
    expect(export, isNot(contains(dir.path)));
    final chat = jsonDecode((jsonDecode(export) as List).first as String);
    final image = (jsonDecode(chat["messages"]) as List)
        .firstWhere((m) => m["type"] == "image");
    expect(image["content"], png);
  });

  test("removing a chat deletes its messages and images", () async {
    await open({
      "chats": [legacyChat("a", "A", image: true)]
    });
    removeChat("a");
    expect(await chatMessages("a"), isEmpty);
    if (sqlite) {
      expect(Directory("${dir.path}/attachments/a").existsSync(), isFalse);
    }
  });
}

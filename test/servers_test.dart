import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/worker/servers.dart';

void main() {
  group("migration from the single host settings", () {
    test("keeps the Ollama host, its headers and the OpenAI server", () {
      final servers = legacyServers(
          host: "http://pc:11434",
          hostHeaders: '{"X-Token": "abc"}',
          openaiHost: "http://rig:8000/v1",
          openaiKey: " sk-1 ");
      expect(servers.map((s) => s.id), [legacyOllamaId, legacyOpenAiId]);
      expect(servers[0].isOllama, isTrue);
      expect(servers[0].headers, {"X-Token": "abc"});
      expect(servers[1].isOllama, isFalse);
      expect(servers[1].apiKey, "sk-1");
      expect(servers[1].authHeaders, {"Authorization": "Bearer sk-1"});
    });

    test("ignores unset values and broken header JSON", () {
      expect(legacyServers(), isEmpty);
      final servers =
          legacyServers(host: "http://pc:11434", hostHeaders: "not json");
      expect(servers.single.headers, isEmpty);
    });
  });

  test("survives a round trip through JSON", () {
    final server = LlmServer(
        name: "Rig",
        type: serverTypeOpenAi,
        url: "http://rig:8000",
        apiKey: "k",
        headers: {"A": "1"});
    final parsed =
        parseServers(jsonEncode([server.toJson(), {"url": ""}, "junk"]));
    expect(parsed.length, 1);
    expect(parsed.single.toJson(), server.toJson());
    expect(parsed.single.baseUrl, "http://rig:8000/v1");
    expect(parseServers("broken"), isEmpty);
  });

  test("resolves ids stored by older versions", () {
    final a = LlmServer(id: "a", url: "http://a:11434");
    final b = LlmServer(id: "b", type: serverTypeOpenAi, url: "http://b/v1");
    final servers = [b, a];
    expect(serverById("a", servers), same(a));
    expect(serverById(null, servers), same(a));
    expect(serverById(legacyOllamaId, servers), same(a));
    expect(serverById(legacyOpenAiId, servers), same(b));
    expect(serverById("gone", servers), isNull);
    expect(serverById(legacyOpenAiId, [a]), isNull);
  });

  test("names and URLs", () {
    expect(LlmServer(url: "http://pc:11434/").baseUrl, "http://pc:11434");
    expect(LlmServer(url: "http://pc:11434").displayName, "pc");
    expect(LlmServer(name: " Home ", url: "http://pc").displayName, "Home");
    expect(
        LlmServer(apiKey: "k", headers: {"Authorization": "x", "B": "2"})
            .authHeaders,
        {"Authorization": "Bearer k", "B": "2"});
  });

  test("model search matches every word in model or server name", () {
    final server = LlmServer(name: "Home PC", url: "http://pc:11434");
    final model = ServerModel(server, "qwen3:8b");
    expect(model.baseName, "qwen3");
    expect(model.tag, "8b");
    expect(ServerModel(server, "llama3:latest").tag, "");
    expect(model.matches("QWEN"), isTrue);
    expect(model.matches("qwen home"), isTrue);
    expect(model.matches("qwen rig"), isFalse);
    expect(model.matches(""), isTrue);
  });
}

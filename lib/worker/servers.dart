// LLM servers.
//
// Any number of servers can be configured. Each one is either an Ollama
// server (native /api) or a server that speaks the OpenAI chat-completions
// protocol (vLLM, LM Studio, llama.cpp, API proxies, ...), and has its own
// name, API key and extra request headers. The model picker lists the models
// of all servers; a selected model remembers the id of its server.
//
// Older versions had exactly one Ollama host ("host", "hostHeaders") and one
// optional OpenAI-compatible server ("openaiHost", "openaiKey"). Those are
// migrated once into the list with the ids "ollama" and "openai", which are
// also the values older versions stored as a chat's or model's "provider", so
// existing chats keep pointing at the right server.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:uuid/uuid.dart';

import '../main.dart';
import 'clients.dart';
import 'llm.dart';

const String serverTypeOllama = "ollama";
const String serverTypeOpenAi = "openai";

/// Ids the migrated legacy servers get; also the old "provider" values.
const String legacyOllamaId = "ollama";
const String legacyOpenAiId = "openai";

class LlmServer {
  final String id;
  String name;
  String type;
  String url;
  String apiKey;
  Map<String, String> headers;

  LlmServer(
      {String? id,
      this.name = "",
      this.type = serverTypeOllama,
      this.url = "",
      this.apiKey = "",
      Map<String, String>? headers})
      : id = id ?? const Uuid().v4(),
        headers = headers ?? {};

  factory LlmServer.fromJson(Map json) => LlmServer(
      id: json["id"]?.toString(),
      name: json["name"]?.toString() ?? "",
      type: json["type"]?.toString() == serverTypeOpenAi
          ? serverTypeOpenAi
          : serverTypeOllama,
      url: json["url"]?.toString() ?? "",
      apiKey: json["apiKey"]?.toString() ?? "",
      headers: json["headers"] is Map
          ? (json["headers"] as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()))
          : {});

  Map<String, dynamic> toJson() => {
        "id": id,
        "name": name,
        "type": type,
        "url": url,
        "apiKey": apiKey,
        "headers": headers,
      };

  bool get isOllama => type != serverTypeOpenAi;

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    final host = Uri.tryParse(url.trim())?.host ?? "";
    return host.isNotEmpty ? host : url.trim();
  }

  /// Ollama: the server root, without trailing slash.
  /// OpenAI-compatible: the base "/chat/completions" is appended to.
  String get baseUrl {
    if (!isOllama) return normalizeOpenAiBaseUrl(url);
    var value = url.trim();
    while (value.endsWith("/")) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// The user's headers plus the API key as a Bearer token.
  Map<String, String> get authHeaders => {
        ...headers,
        if (apiKey.trim().isNotEmpty) "Authorization": "Bearer ${apiKey.trim()}"
      };

  /// Headers for JSON requests.
  Map<String, String> get requestHeaders =>
      {"Content-Type": "application/json", ...authHeaders};
}

// ---------------------------------------------------------------------------
// configuration

List<LlmServer>? _cache;

/// All configured servers, in the order the user sees them.
List<LlmServer> get llmServers {
  if (useHost) {
    return [LlmServer(id: legacyOllamaId, name: "Ollama", url: fixedHost)];
  }
  if (prefs == null) return [];
  return _cache ??= _load();
}

void saveLlmServers(List<LlmServer> servers) {
  _cache = List.of(servers);
  prefs?.setString(
      "servers", jsonEncode(servers.map((s) => s.toJson()).toList()));
}

List<LlmServer> _load() {
  final stored = prefs?.getString("servers");
  if (stored != null) return parseServers(stored);
  final migrated = legacyServers(
      host: prefs?.getString("host"),
      hostHeaders: prefs?.getString("hostHeaders"),
      openaiHost: prefs?.getString("openaiHost"),
      openaiKey: prefs?.getString("openaiKey"));
  saveLlmServers(migrated);
  return migrated;
}

List<LlmServer> parseServers(String json) {
  try {
    final list = jsonDecode(json) as List;
    return list
        .whereType<Map>()
        .map(LlmServer.fromJson)
        .where((s) => s.url.trim().isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

/// Builds the server list from the settings of versions with one Ollama
/// host and one OpenAI-compatible server.
List<LlmServer> legacyServers(
    {String? host, String? hostHeaders, String? openaiHost, String? openaiKey}) {
  Map<String, String> headers = {};
  try {
    headers = (jsonDecode(hostHeaders ?? "{}") as Map)
        .map((key, value) => MapEntry(key.toString(), value.toString()));
  } catch (_) {}
  return [
    if ((host ?? "").trim().isNotEmpty)
      LlmServer(
          id: legacyOllamaId,
          name: "Ollama",
          type: serverTypeOllama,
          url: host!.trim(),
          headers: headers),
    if ((openaiHost ?? "").trim().isNotEmpty)
      LlmServer(
          id: legacyOpenAiId,
          name: "OpenAI-compatible",
          type: serverTypeOpenAi,
          url: openaiHost!.trim(),
          apiKey: (openaiKey ?? "").trim()),
  ];
}

/// The server with [id]. Chats and settings from older versions store
/// "ollama"/"openai" (or nothing, meaning Ollama); those fall back to the
/// first server of that type when the migrated server was removed.
LlmServer? serverById(String? id, [List<LlmServer>? servers]) {
  servers ??= llmServers;
  for (final server in servers) {
    if (server.id == id) return server;
  }
  if (id == null || id == legacyOllamaId) {
    for (final server in servers) {
      if (server.isOllama) return server;
    }
  } else if (id == legacyOpenAiId) {
    for (final server in servers) {
      if (!server.isOllama) return server;
    }
  }
  return null;
}

/// Server of the selected model.
LlmServer? get modelServer => serverById(modelProvider);

// ---------------------------------------------------------------------------
// models

class ServerModel {
  final LlmServer server;

  /// Full name as the server knows it, e.g. "llama3:latest".
  final String name;
  final bool vision;
  final bool thinking;

  const ServerModel(this.server, this.name,
      {this.vision = false, this.thinking = false});

  /// "llama3" for "llama3:latest".
  String get baseName => name.split(":").first;

  /// "8b" for "llama3:8b"; empty for ":latest" and untagged names.
  String get tag {
    final parts = name.split(":");
    if (parts.length < 2 || parts[1] == "latest") return "";
    return parts.sublist(1).join(":");
  }

  /// Whether every word of [query] appears in the model or server name.
  bool matches(String query) {
    final haystack = "$name ${server.displayName}".toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r"\s+"))
        .where((w) => w.isNotEmpty)
        .every(haystack.contains);
  }
}

Duration get _listTimeout => Duration(
    seconds: (10.0 * (prefs?.getDouble("timeoutMultiplier") ?? 1.0)).round());

/// Lists the models of [server]. Throws [LlmException] when it can't be
/// reached or doesn't answer like the configured server type.
Future<List<ServerModel>> listServerModels(LlmServer server,
    {bool details = true}) async {
  if (!server.isOllama) {
    final ids = await listOpenAiModels(server);
    // capabilities are unknown for OpenAI-compatible servers
    return ids.map((id) => ServerModel(server, id, vision: true)).toList();
  }

  final client = ollamaClientFor(server);
  final llama.ModelsResponse list;
  try {
    list = await client.listModels().timeout(_listTimeout);
  } on TimeoutException {
    throw LlmException(
        "${server.displayName}: no response within ${_listTimeout.inSeconds}s");
  } on llama.OllamaClientException catch (e) {
    throw LlmException("${server.displayName}: HTTP ${e.code ?? "error"}");
  } catch (e) {
    throw LlmException("${server.displayName}: ${describeNetworkError(e)}");
  }

  Future<ServerModel> describe(llama.Model model) async {
    final name = model.model!;
    bool vision = (model.details?.families ?? []).contains("clip");
    bool thinking = thinkingModels.contains(name);
    if (details) {
      try {
        final info = await client
            .showModelInfo(request: llama.ModelInfoRequest(model: name))
            .timeout(_listTimeout);
        final capabilities = info.capabilities ?? [];
        vision = vision || capabilities.contains(llama.Capability.vision);
        thinking = capabilities.contains(llama.Capability.thinking);
        rememberThinkingSupport(name, thinking);
      } catch (_) {}
    }
    return ServerModel(server, name, vision: vision, thinking: thinking);
  }

  final models = (list.models ?? []).where((m) => m.model != null).toList();
  return Future.wait(models.map(describe));
}

/// Asks Ollama to load [model] so the first answer comes quicker.
Future<void> preloadModel(LlmServer server, String model) async {
  final keepAlive = int.tryParse(prefs?.getString("keepAlive") ?? "300") ?? 300;
  // the ollama package can't load a model without sending a prompt
  await httpClient
      .post(Uri.parse("${server.baseUrl}/api/generate"),
          headers: server.requestHeaders,
          body: jsonEncode({"model": model, "keep_alive": keepAlive}))
      .timeout(_listTimeout)
      .then((response) {
    if (response.statusCode != 200) {
      throw LlmException(
          "HTTP ${response.statusCode}: ${extractServerError(response.body)}");
    }
  });
}

/// Connection test used by the settings: the number of models on [server].
Future<int> checkServer(LlmServer server) async =>
    (await listServerModels(server, details: false)).length;

/// Lists model ids of an OpenAI-compatible server.
Future<List<String>> listOpenAiModels(LlmServer server) async {
  final http.Response response;
  try {
    response = await http
        .get(Uri.parse("${server.baseUrl}/models"),
            headers: server.requestHeaders)
        .timeout(_listTimeout);
  } on TimeoutException {
    throw LlmException(
        "${server.displayName}: no response within ${_listTimeout.inSeconds}s");
  } catch (e) {
    throw LlmException("${server.displayName}: ${describeNetworkError(e)}");
  }
  if (response.statusCode != 200) {
    throw LlmException("${server.displayName}: HTTP ${response.statusCode}: "
        "${extractServerError(response.body)}");
  }
  final dynamic data;
  try {
    data = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    throw LlmException(
        "${server.displayName}: not an OpenAI-compatible model list");
  }
  final list = (data is Map ? data["data"] : data);
  if (list is! List) {
    throw LlmException(
        "${server.displayName}: not an OpenAI-compatible model list");
  }
  final ids = list
      .map((e) => (e is Map ? e["id"] : e)?.toString())
      .whereType<String>()
      .toList();
  ids.sort();
  return ids;
}

// Provider-agnostic chat client.
//
// Talks either to Ollama's native API (/api/chat) or to any server that
// speaks the OpenAI chat-completions protocol (vLLM, LM Studio, llama.cpp,
// API proxies, ...). Both paths stream, support cancellation, and use two
// separate timeouts: a generous one for the first response (a large model
// may need a while to load into VRAM) and a shorter one between chunks.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../main.dart';

const String providerOllama = "ollama";
const String providerOpenAi = "openai";

/// Provider of the currently selected [model].
String modelProvider = providerOllama;

// ---------------------------------------------------------------------------
// thinking

/// Ollama models that reported the "thinking" capability, remembered per
/// model so that opening an older chat knows about its model as well.
Set<String> get thinkingModels =>
    (prefs?.getStringList("thinkingModels") ?? []).toSet();

void setThinkingModels(Iterable<String> models) =>
    prefs?.setStringList("thinkingModels", models.toList());

void rememberThinkingSupport(String model, bool supported) {
  final models = thinkingModels;
  supported ? models.add(model) : models.remove(model);
  setThinkingModels(models);
}

/// Whether the selected model can be told to think or not. Only Ollama
/// exposes this; OpenAI-compatible servers just get whatever the model does.
bool modelCanThink([String? name, String? provider]) {
  name ??= model;
  provider ??= modelProvider;
  return provider == providerOllama &&
      name != null &&
      thinkingModels.contains(name);
}

/// User preference for models that [modelCanThink].
bool get thinkingEnabled => prefs?.getBool("thinking") ?? true;
set thinkingEnabled(bool value) => prefs?.setBool("thinking", value);

class LlmMessage {
  final String role; // system | user | assistant
  final String content;
  final List<String> images; // base64, no data: prefix

  const LlmMessage(this.role, this.content, [this.images = const []]);
}

class LlmDelta {
  final String content;
  final String thinking;

  /// Token counts and timings the server reported, usually with the last
  /// chunk. Keys: promptTokens, cachedTokens, tokens, reasoningTokens,
  /// promptMs, genMs,
  /// loadMs, serverMs, doneReason (all optional).
  final Map<String, dynamic>? usage;
  const LlmDelta({this.content = "", this.thinking = "", this.usage});
}

int? _ms(Object? nanoseconds) =>
    nanoseconds is num ? (nanoseconds / 1000000).round() : null;

Map<String, dynamic>? ollamaUsage(Map json) {
  final usage = <String, dynamic>{
    if (json["prompt_eval_count"] is num)
      "promptTokens": (json["prompt_eval_count"] as num).toInt(),
    if (json["prompt_eval_cached_count"] is num &&
        json["prompt_eval_cached_count"] > 0)
      "cachedTokens": (json["prompt_eval_cached_count"] as num).toInt(),
    if (json["eval_count"] is num)
      "tokens": (json["eval_count"] as num).toInt(),
    if (_ms(json["prompt_eval_duration"]) != null)
      "promptMs": _ms(json["prompt_eval_duration"]),
    if (_ms(json["eval_duration"]) != null) "genMs": _ms(json["eval_duration"]),
    if (_ms(json["load_duration"]) != null)
      "loadMs": _ms(json["load_duration"]),
    if (_ms(json["total_duration"]) != null)
      "serverMs": _ms(json["total_duration"]),
    if (json["done_reason"] != null)
      "doneReason": json["done_reason"].toString(),
  };
  return usage.isEmpty ? null : usage;
}

/// OpenAI "usage", plus llama.cpp's "timings" where a server sends them.
Map<String, dynamic>? openAiUsage(Map json) {
  final usage = json["usage"] is Map ? json["usage"] as Map : const {};
  final timings = json["timings"] is Map ? json["timings"] as Map : const {};
  final details = usage["completion_tokens_details"] is Map
      ? usage["completion_tokens_details"] as Map
      : const {};
  final promptDetails = usage["prompt_tokens_details"] is Map
      ? usage["prompt_tokens_details"] as Map
      : const {};
  num? n(Object? value) => value is num ? value : null;
  final result = <String, dynamic>{
    if (n(usage["prompt_tokens"] ?? timings["prompt_n"]) != null)
      "promptTokens": n(usage["prompt_tokens"] ?? timings["prompt_n"])!.toInt(),
    if (n(usage["completion_tokens"] ?? timings["predicted_n"]) != null)
      "tokens":
          n(usage["completion_tokens"] ?? timings["predicted_n"])!.toInt(),
    if (n(promptDetails["cached_tokens"]) != null &&
        promptDetails["cached_tokens"] > 0)
      "cachedTokens": n(promptDetails["cached_tokens"])!.toInt(),
    if (n(details["reasoning_tokens"]) != null &&
        details["reasoning_tokens"] > 0)
      "reasoningTokens": n(details["reasoning_tokens"])!.toInt(),
    if (n(timings["prompt_ms"]) != null)
      "promptMs": n(timings["prompt_ms"])!.round(),
    if (n(timings["predicted_ms"]) != null)
      "genMs": n(timings["predicted_ms"])!.round(),
  };
  return result.isEmpty ? null : result;
}

class LlmException implements Exception {
  final String message;
  const LlmException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// settings helpers

double get _timeoutMultiplier => prefs?.getDouble("timeoutMultiplier") ?? 1.0;

/// Time allowed until the server sends anything at all (includes model load).
Duration get firstResponseTimeout =>
    Duration(seconds: (120.0 * _timeoutMultiplier).round());

/// Time allowed between two streamed chunks once the answer is flowing.
Duration get idleTimeout =>
    Duration(seconds: (60.0 * _timeoutMultiplier).round());

Map<String, String> ollamaHeaders() => {
      "Content-Type": "application/json",
      ...(jsonDecode(prefs?.getString("hostHeaders") ?? "{}") as Map)
          .cast<String, String>()
    };

String? get openAiBaseUrl {
  var value = (prefs?.getString("openaiHost") ?? "").trim();
  if (value.isEmpty) return null;
  return normalizeOpenAiBaseUrl(value);
}

bool get openAiConfigured => openAiBaseUrl != null;

/// Accepts "http://rig:8000", "http://rig:8000/" or "http://rig:8000/v1" and
/// returns the base that "/chat/completions" and "/models" are appended to.
String normalizeOpenAiBaseUrl(String value) {
  value = value.trim();
  while (value.endsWith("/")) {
    value = value.substring(0, value.length - 1);
  }
  final uri = Uri.tryParse(value);
  if (uri != null && (uri.path.isEmpty || uri.path == "/")) {
    value = "$value/v1";
  }
  return value;
}

Map<String, String> openAiHeaders({String? apiKey}) {
  apiKey ??= prefs?.getString("openaiKey") ?? "";
  return {
    "Content-Type": "application/json",
    if (apiKey.trim().isNotEmpty) "Authorization": "Bearer ${apiKey.trim()}"
  };
}

// ---------------------------------------------------------------------------
// cancellation

http.Client? _activeClient;
bool _cancelRequested = false;

/// Aborts the request that is currently streaming, if any.
void cancelGeneration() {
  _cancelRequested = true;
  try {
    _activeClient?.close();
  } catch (_) {}
}

bool get generationCancelled => _cancelRequested;

// ---------------------------------------------------------------------------
// model listing

Future<List<String>> listOpenAiModels(
    {String? baseUrl, String? apiKey, Duration? timeout}) async {
  baseUrl ??= openAiBaseUrl;
  if (baseUrl == null) return [];
  final response = await http
      .get(Uri.parse("$baseUrl/models"), headers: openAiHeaders(apiKey: apiKey))
      .timeout(timeout ?? Duration(seconds: (10 * _timeoutMultiplier).round()));
  if (response.statusCode != 200) {
    throw LlmException(
        "HTTP ${response.statusCode}: ${extractServerError(response.body)}");
  }
  final data = jsonDecode(utf8.decode(response.bodyBytes));
  final list = (data is Map ? data["data"] : data) as List? ?? [];
  final ids = list
      .map((e) => (e is Map ? e["id"] : e)?.toString())
      .whereType<String>()
      .toList();
  ids.sort();
  return ids;
}

// ---------------------------------------------------------------------------
// chat

/// Streams the answer for [messages]. Throws [LlmException] with a readable
/// message on failure. When [cancelGeneration] is called the stream simply
/// ends; check [generationCancelled] to tell the difference.
///
/// Only a [cancellable] request is stopped by [cancelGeneration]; background
/// requests (titles, punctuation) leave the cancellation state alone so they
/// can't interfere with the answer that is currently streaming.
// Whether OpenAI-compatible servers are asked to report token usage.
bool _streamUsage = true;

Stream<LlmDelta> chatStream({
  required String model,
  required List<LlmMessage> messages,
  String? provider,
  bool cancellable = true,
}) async* {
  provider ??= modelProvider;
  final client = http.Client();
  if (cancellable) {
    _cancelRequested = false;
    _activeClient = client;
  }
  bool cancelled() => cancellable && _cancelRequested;
  void release() {
    client.close();
    if (identical(_activeClient, client)) _activeClient = null;
  }

  final bool openAi = provider == providerOpenAi;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic> body;

  if (openAi) {
    final base = openAiBaseUrl;
    if (base == null) {
      release();
      throw const LlmException("No OpenAI-compatible server is configured.");
    }
    uri = Uri.parse("$base/chat/completions");
    headers = openAiHeaders();
    body = {
      "model": model,
      "stream": true,
      if (_streamUsage) "stream_options": {"include_usage": true},
      "messages": messages.map(_toOpenAiMessage).toList(),
    };
  } else {
    if (host == null) {
      release();
      throw const LlmException("No Ollama host is configured.");
    }
    uri = Uri.parse("$host/api/chat");
    headers = ollamaHeaders();
    body = {
      "model": model,
      "stream": true,
      // background requests (titles, punctuation) never need to reason
      if (modelCanThink(model, provider))
        "think": cancellable && thinkingEnabled,
      "keep_alive": int.tryParse(prefs?.getString("keepAlive") ?? "300") ?? 300,
      "messages": messages
          .map((m) => {
                "role": m.role,
                "content": m.content,
                if (m.images.isNotEmpty) "images": m.images
              })
          .toList(),
    };
  }

  final request = http.Request("POST", uri)
    ..headers.addAll(headers)
    ..body = jsonEncode(body);

  http.StreamedResponse response;
  try {
    response = await client.send(request).timeout(firstResponseTimeout);
  } on TimeoutException {
    release();
    throw LlmException(_firstTimeoutMessage());
  } catch (e) {
    release();
    if (cancelled()) return;
    throw LlmException(
        "Couldn't reach ${uri.host}:${uri.port} (${describeNetworkError(e)})");
  }

  if (response.statusCode != 200) {
    String text = "";
    try {
      text = await response.stream.bytesToString().timeout(idleTimeout);
    } catch (_) {}
    release();
    // a few servers reject stream_options; ask them without it from now on
    if (openAi &&
        _streamUsage &&
        response.statusCode == 400 &&
        text.contains("stream_options")) {
      _streamUsage = false;
      yield* chatStream(
          model: model,
          messages: messages,
          provider: provider,
          cancellable: cancellable);
      return;
    }
    throw LlmException(
        "Server returned HTTP ${response.statusCode}: ${extractServerError(text)}");
  }

  final lines = _withTimeouts(
      response.stream.transform(utf8.decoder).transform(const LineSplitter()),
      firstResponseTimeout,
      idleTimeout);

  try {
    await for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (openAi) {
        if (!line.startsWith("data:")) continue;
        final payload = line.substring(5).trim();
        if (payload == "[DONE]") break;
        final json = _tryDecode(payload);
        if (json == null) continue;
        if (json["error"] != null) {
          throw LlmException(extractServerError(payload));
        }
        final usage = openAiUsage(json);
        if (usage != null) yield LlmDelta(usage: usage);
        final choices = json["choices"];
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)["delta"] as Map? ?? {};
        final content = delta["content"]?.toString() ?? "";
        final thinking =
            (delta["reasoning_content"] ?? delta["reasoning"])?.toString() ??
                "";
        if (content.isNotEmpty || thinking.isNotEmpty) {
          yield LlmDelta(content: content, thinking: thinking);
        }
      } else {
        final json = _tryDecode(line);
        if (json == null) continue;
        if (json["error"] != null) {
          throw LlmException(json["error"].toString());
        }
        final message = json["message"] as Map? ?? {};
        final content = message["content"]?.toString() ?? "";
        final thinking = message["thinking"]?.toString() ?? "";
        if (content.isNotEmpty || thinking.isNotEmpty) {
          yield LlmDelta(content: content, thinking: thinking);
        }
        if (json["done"] == true) {
          final usage = ollamaUsage(json);
          if (usage != null) yield LlmDelta(usage: usage);
          break;
        }
      }
    }
  } on _StreamTimeout catch (e) {
    throw LlmException(e.beforeFirstChunk
        ? _firstTimeoutMessage()
        : "The model stopped responding (no data for ${idleTimeout.inSeconds}s).");
  } on LlmException {
    rethrow;
  } catch (e) {
    if (cancelled()) return;
    throw LlmException("Connection lost: $e");
  } finally {
    release();
  }
}

/// Non-streaming convenience wrapper (titles, punctuation, ...).
Future<String> chatComplete({
  required String model,
  required List<LlmMessage> messages,
  String? provider,
}) async {
  final buffer = StringBuffer();
  await for (final delta in chatStream(
      model: model,
      messages: messages,
      provider: provider,
      cancellable: false)) {
    buffer.write(delta.content);
  }
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// internals

String _firstTimeoutMessage() =>
    "No response within ${firstResponseTimeout.inSeconds}s. If the model is "
    "large it may still be loading - try again, or raise the timeout "
    "multiplier in Settings > Interface.";

Map<String, dynamic> _toOpenAiMessage(LlmMessage m) {
  if (m.images.isEmpty) return {"role": m.role, "content": m.content};
  return {
    "role": m.role,
    "content": [
      if (m.content.isNotEmpty) {"type": "text", "text": m.content},
      for (final image in m.images)
        {
          "type": "image_url",
          "image_url": {"url": "data:${imageMimeType(image)};base64,$image"}
        }
    ]
  };
}

/// Guesses the mime type of a base64 encoded image from its magic bytes.
String imageMimeType(String base64Data) {
  if (base64Data.startsWith("/9j/")) return "image/jpeg";
  if (base64Data.startsWith("iVBOR")) return "image/png";
  if (base64Data.startsWith("R0lGOD")) return "image/gif";
  if (base64Data.startsWith("UklGR")) return "image/webp";
  return "image/png";
}

Map<String, dynamic>? _tryDecode(String text) {
  try {
    final value = jsonDecode(text);
    return value is Map<String, dynamic> ? value : null;
  } catch (_) {
    return null;
  }
}

/// Short reason of a failed connection, e.g. "Connection refused".
String describeNetworkError(Object error) {
  var message =
      error is http.ClientException ? error.message : error.toString();
  message = message.replaceFirst(RegExp(r"^\w+Exception: "), "");
  final details = message.indexOf(" (OS Error");
  if (details > 0) message = message.substring(0, details);
  final comma = message.indexOf(", address = ");
  if (comma > 0) message = message.substring(0, comma);
  return message;
}

String extractServerError(String body) {
  final json = _tryDecode(body);
  if (json != null) {
    final error = json["error"];
    if (error is Map && error["message"] != null) {
      return error["message"].toString();
    }
    if (error != null) return error.toString();
    if (json["message"] != null) return json["message"].toString();
    if (json["detail"] != null) return json["detail"].toString();
  }
  body = body.trim();
  if (body.isEmpty) return "no details";
  return body.length > 300 ? "${body.substring(0, 300)}..." : body;
}

class _StreamTimeout implements Exception {
  final bool beforeFirstChunk;
  const _StreamTimeout(this.beforeFirstChunk);
}

/// Like [Stream.timeout] but with a separate limit for the first event.
Stream<T> _withTimeouts<T>(Stream<T> source, Duration first, Duration idle) {
  late StreamController<T> controller;
  StreamSubscription<T>? subscription;
  Timer? timer;
  bool gotFirst = false;

  void arm() {
    timer?.cancel();
    timer = Timer(gotFirst ? idle : first, () {
      controller.addError(_StreamTimeout(!gotFirst));
      subscription?.cancel();
      controller.close();
    });
  }

  controller = StreamController<T>(
    onListen: () {
      arm();
      subscription = source.listen((event) {
        gotFirst = true;
        arm();
        controller.add(event);
      }, onError: (Object error, StackTrace stack) {
        timer?.cancel();
        controller.addError(error, stack);
      }, onDone: () {
        timer?.cancel();
        controller.close();
      });
    },
    onCancel: () {
      timer?.cancel();
      return subscription?.cancel();
    },
  );
  return controller.stream;
}

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

class LlmMessage {
  final String role; // system | user | assistant
  final String content;
  final List<String> images; // base64, no data: prefix

  const LlmMessage(this.role, this.content, [this.images = const []]);
}

class LlmDelta {
  final String content;
  final String thinking;
  const LlmDelta({this.content = "", this.thinking = ""});
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
        "HTTP ${response.statusCode}: ${_extractError(response.body)}");
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
    throw LlmException("Couldn't reach ${uri.host}:${uri.port} ($e)");
  }

  if (response.statusCode != 200) {
    String text = "";
    try {
      text = await response.stream.bytesToString().timeout(idleTimeout);
    } catch (_) {}
    release();
    throw LlmException(
        "Server returned HTTP ${response.statusCode}: ${_extractError(text)}");
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
          throw LlmException(_extractError(payload));
        }
        final choices = json["choices"];
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)["delta"] as Map? ?? {};
        final content = delta["content"]?.toString() ?? "";
        final thinking = (delta["reasoning_content"] ?? delta["reasoning"])
                ?.toString() ??
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
        if (json["done"] == true) break;
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

String _extractError(String body) {
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

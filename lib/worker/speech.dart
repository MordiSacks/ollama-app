// Speech engines.
//
// Speech recognition and text-to-speech can use the device (Android's
// recognition service and TTS engine) or any server that speaks the OpenAI
// audio API: POST /audio/transcriptions and POST /audio/speech (Speaches,
// vLLM, LocalAI, Kokoro-FastAPI, ...). Several servers can be configured;
// one engine is selected for each direction.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../main.dart';
import 'llm.dart';

const String speechEngineDevice = "device";

const List<String> speechAudioFormats = ["mp3", "wav", "opus", "flac"];

class SpeechServer {
  final String id;
  String name;
  String url;
  String apiKey;
  String sttModel;
  String sttLanguage; // empty = let the server detect it
  String ttsModel;
  String ttsVoice;
  String ttsFormat;

  SpeechServer(
      {String? id,
      this.name = "",
      this.url = "",
      this.apiKey = "",
      this.sttModel = "",
      this.sttLanguage = "",
      this.ttsModel = "",
      this.ttsVoice = "",
      this.ttsFormat = "mp3"})
      : id = id ?? const Uuid().v4();

  factory SpeechServer.fromJson(Map json) => SpeechServer(
      id: json["id"]?.toString(),
      name: json["name"]?.toString() ?? "",
      url: json["url"]?.toString() ?? "",
      apiKey: json["apiKey"]?.toString() ?? "",
      sttModel: json["sttModel"]?.toString() ?? "",
      sttLanguage: json["sttLanguage"]?.toString() ?? "",
      ttsModel: json["ttsModel"]?.toString() ?? "",
      ttsVoice: json["ttsVoice"]?.toString() ?? "",
      ttsFormat: json["ttsFormat"]?.toString() ?? "mp3");

  Map<String, String> toJson() => {
        "id": id,
        "name": name,
        "url": url,
        "apiKey": apiKey,
        "sttModel": sttModel,
        "sttLanguage": sttLanguage,
        "ttsModel": ttsModel,
        "ttsVoice": ttsVoice,
        "ttsFormat": ttsFormat
      };

  String get displayName =>
      name.trim().isNotEmpty ? name.trim() : (Uri.tryParse(url)?.host ?? url);

  String get _base => normalizeOpenAiBaseUrl(url);

  Map<String, String> get _authHeaders => {
        if (apiKey.trim().isNotEmpty) "Authorization": "Bearer ${apiKey.trim()}"
      };
}

// ---------------------------------------------------------------------------
// configuration

List<SpeechServer> loadSpeechServers() {
  try {
    final list = jsonDecode(prefs?.getString("speechServers") ?? "[]") as List;
    return list.whereType<Map>().map(SpeechServer.fromJson).toList();
  } catch (_) {
    return [];
  }
}

void saveSpeechServers(List<SpeechServer> servers) {
  prefs?.setString(
      "speechServers", jsonEncode(servers.map((s) => s.toJson()).toList()));
}

SpeechServer? _selected(String key) {
  final id = prefs?.getString(key) ?? speechEngineDevice;
  if (id == speechEngineDevice) return null;
  for (final server in loadSpeechServers()) {
    if (server.id == id) return server;
  }
  return null;
}

/// Server selected for speech recognition, or null for the device.
SpeechServer? get sttServer => _selected("sttEngine");

/// Server selected for text-to-speech, or null for the device.
SpeechServer? get ttsServer => _selected("ttsEngine");

// ---------------------------------------------------------------------------
// requests

/// Transcribes the audio file at [path] with [server].
Future<String> transcribe(SpeechServer server, String path) async {
  final request = http.MultipartRequest(
      "POST", Uri.parse("${server._base}/audio/transcriptions"))
    ..headers.addAll(server._authHeaders)
    ..fields["response_format"] = "json"
    ..files.add(await http.MultipartFile.fromPath("file", path,
        filename: path.split("/").last));
  if (server.sttModel.trim().isNotEmpty) {
    request.fields["model"] = server.sttModel.trim();
  }
  if (server.sttLanguage.trim().isNotEmpty) {
    request.fields["language"] = server.sttLanguage.trim();
  }

  final http.Response response;
  try {
    response = await http.Response.fromStream(
        await request.send().timeout(firstResponseTimeout));
  } on TimeoutException {
    throw LlmException(
        "${server.displayName}: no response within ${firstResponseTimeout.inSeconds}s.");
  } catch (e) {
    throw LlmException(
        "Couldn't reach ${server.displayName} (${describeNetworkError(e)})");
  }
  final body = utf8.decode(response.bodyBytes, allowMalformed: true);
  if (response.statusCode != 200) {
    throw LlmException(
        "${server.displayName} returned HTTP ${response.statusCode}: ${extractServerError(body)}");
  }
  try {
    final json = jsonDecode(body);
    if (json is Map && json["text"] != null) {
      return json["text"].toString().trim();
    }
  } catch (_) {}
  return body.trim();
}

/// Generates speech for [text] with [server]; returns the encoded audio.
Future<Uint8List> synthesize(SpeechServer server, String text) async {
  final http.Response response;
  try {
    response = await http
        .post(Uri.parse("${server._base}/audio/speech"),
            headers: {
              "Content-Type": "application/json",
              ...server._authHeaders
            },
            body: jsonEncode({
              if (server.ttsModel.trim().isNotEmpty)
                "model": server.ttsModel.trim(),
              if (server.ttsVoice.trim().isNotEmpty)
                "voice": server.ttsVoice.trim(),
              "input": text,
              "response_format": server.ttsFormat,
            }))
        .timeout(firstResponseTimeout);
  } on TimeoutException {
    throw LlmException(
        "${server.displayName}: no response within ${firstResponseTimeout.inSeconds}s.");
  } catch (e) {
    throw LlmException(
        "Couldn't reach ${server.displayName} (${describeNetworkError(e)})");
  }
  if (response.statusCode != 200) {
    throw LlmException(
        "${server.displayName} returned HTTP ${response.statusCode}: ${extractServerError(utf8.decode(response.bodyBytes, allowMalformed: true))}");
  }
  if ((response.headers["content-type"] ?? "").contains("json")) {
    throw LlmException(
        "${server.displayName}: ${extractServerError(utf8.decode(response.bodyBytes, allowMalformed: true))}");
  }
  return response.bodyBytes;
}

// ---------------------------------------------------------------------------
// recording

final AudioRecorder _recorder = AudioRecorder();
String? _recordingPath;

Future<bool> recordingPermission() => _recorder.hasPermission();

/// Starts recording 16 kHz mono WAV, which every Whisper server accepts.
Future<void> startRecording() async {
  if (await _recorder.isRecording()) await _recorder.cancel();
  final dir = await getTemporaryDirectory();
  _recordingPath =
      "${dir.path}/speech_${DateTime.now().millisecondsSinceEpoch}.wav";
  await _recorder.start(
      const RecordConfig(
          encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
      path: _recordingPath!);
}

/// Stops recording and returns the file, or null if nothing was recording.
Future<String?> stopRecording() async {
  if (!await _recorder.isRecording()) return null;
  return await _recorder.stop() ?? _recordingPath;
}

Future<void> cancelRecording() async {
  try {
    await _recorder.cancel();
  } catch (_) {}
}

Future<bool> isRecording() => _recorder.isRecording();

/// Records one utterance: waits for speech and stops after a pause.
///
/// Returns the file, or null when nothing was said within [waitForSpeech]
/// or [keepGoing] turned false before anything was heard. If [keepGoing]
/// turns false after speech started, the recording so far is returned.
Future<String?> recordUtterance(
    {required bool Function() keepGoing,
    Duration waitForSpeech = const Duration(seconds: 8),
    Duration pause = const Duration(milliseconds: 1500),
    Duration maxLength = const Duration(minutes: 2)}) async {
  await startRecording();
  final started = DateTime.now();
  DateTime lastLoud = started;
  bool heard = false;
  double? floor;

  final levels = _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      .listen((amplitude) {
    final level = amplitude.current;
    if (level.isNaN || level.isInfinite) return;
    // track the background noise level, rising only slowly
    floor = (floor == null)
        ? level
        : (level < floor! ? level : floor! + (level - floor!) * 0.01);
    if (level > (floor! + 12).clamp(-45.0, -10.0)) {
      heard = true;
      lastLoud = DateTime.now();
    }
  });

  try {
    while (true) {
      await Future.delayed(const Duration(milliseconds: 100));
      final now = DateTime.now();
      if (!keepGoing()) break;
      if (!heard && now.difference(started) > waitForSpeech) break;
      if (heard && now.difference(lastLoud) > pause) break;
      if (now.difference(started) > maxLength) break;
    }
  } finally {
    await levels.cancel();
  }

  if (!heard) {
    await cancelRecording();
    return null;
  }
  return await stopRecording();
}

// ---------------------------------------------------------------------------
// playback

final AudioPlayer _player = AudioPlayer();
Completer<void>? _playing;

/// Plays encoded audio and completes when it ended or [stopPlayback] ran.
Future<void> playAudio(Uint8List bytes, String format) async {
  await stopPlayback();
  final dir = await getTemporaryDirectory();
  final file = File(
      "${dir.path}/speech_out_${DateTime.now().microsecondsSinceEpoch}.${format == "opus" ? "ogg" : format}");
  await file.writeAsBytes(bytes);

  final done = Completer<void>();
  _playing = done;
  final subscription = _player.onPlayerComplete.listen((_) {
    if (!done.isCompleted) done.complete();
  });
  try {
    await _player.play(DeviceFileSource(file.path));
    await done.future;
  } finally {
    await subscription.cancel();
    if (identical(_playing, done)) _playing = null;
    try {
      await file.delete();
    } catch (_) {}
  }
}

Future<void> stopPlayback() async {
  final playing = _playing;
  _playing = null;
  if (playing != null && !playing.isCompleted) playing.complete();
  try {
    await _player.stop();
  } catch (_) {}
}

// Read assistant messages aloud with the selected text-to-speech engine
// (the device's, or a speech server, see speech.dart).

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../main.dart';
import 'speech.dart';

/// Id of the message currently being read, or null.
String? speakingMessageId;

/// Called whenever [speakingMessageId] changes so the UI can update.
void Function()? onReadAloudChanged;

int _session = 0;

/// Strips markdown and other noise so the TTS engine reads natural text.
String speakableText(String markdown) {
  var text = markdown;
  // reasoning blocks some models put in the answer
  text = text.replaceAll(
      RegExp(r"<think>.*?</think>", dotAll: true, caseSensitive: false), " ");
  // fenced code blocks
  text = text.replaceAll(RegExp(r"```.*?```", dotAll: true), " (code) ");
  // images and links
  text = text.replaceAll(RegExp(r"!\[([^\]]*)\]\([^)]*\)"), r" ");
  text = text.replaceAllMapped(
      RegExp(r"\[([^\]]+)\]\([^)]*\)"), (m) => m.group(1) ?? "");
  // inline code, html tags
  text = text.replaceAllMapped(RegExp(r"`([^`]*)`"), (m) => m.group(1) ?? "");
  text = text.replaceAll(RegExp(r"<[^>]+>"), " ");
  // headings, quotes, list bullets, table pipes, rules
  text = text.replaceAll(RegExp(r"^\s{0,3}#{1,6}\s*", multiLine: true), "");
  text = text.replaceAll(RegExp(r"^\s*>\s?", multiLine: true), "");
  text = text.replaceAll(RegExp(r"^\s*[-*+]\s+", multiLine: true), "");
  text = text.replaceAll(RegExp(r"^\s*([-*_]\s*){3,}$", multiLine: true), "");
  text = text.replaceAll(RegExp(r"^\s*\|?[\s:-]+\|[\s|:-]*$", multiLine: true), "");
  text = text.replaceAll("|", ", ");
  // emphasis markers
  text = text.replaceAll(RegExp(r"[*_~]{1,3}"), "");
  text = text.replaceAll(RegExp(r"[ \t]+"), " ");
  return text.trim();
}

/// Picks a TTS language for [text] based on its script, falling back to the
/// language chosen for voice mode, or the device language.
String _languageFor(String text) {
  final sample = text.length > 400 ? text.substring(0, 400) : text;
  int count(RegExp r) => r.allMatches(sample).length;
  final letters = count(RegExp(r"\p{L}", unicode: true));
  if (letters > 0) {
    if (count(RegExp(r"[֐-׿]")) * 3 > letters) return "he-IL";
    if (count(RegExp(r"[؀-ۿ]")) * 3 > letters) {
      return (prefs?.getString("voiceLanguage") ?? "").startsWith("fa")
          ? "fa-IR"
          : "ar";
    }
    if (count(RegExp(r"[Ѐ-ӿ]")) * 3 > letters) return "ru-RU";
    if (count(RegExp(r"[一-鿿]")) * 3 > letters) return "zh-CN";
  }
  final preferred = prefs?.getString("voiceLanguage");
  if (preferred == null || preferred.isEmpty) {
    return ui.PlatformDispatcher.instance.locale.toLanguageTag();
  }
  return preferred.replaceAll("_", "-");
}

/// Splits text into pieces short enough for every TTS engine.
List<String> _chunks(String text, {int max = 3000}) {
  final sentences = text.split(RegExp(r"(?<=[.!?\n])\s+"));
  final chunks = <String>[];
  var current = StringBuffer();
  for (var sentence in sentences) {
    while (sentence.length > max) {
      chunks.add(sentence.substring(0, max));
      sentence = sentence.substring(max);
    }
    if (current.length + sentence.length + 1 > max) {
      chunks.add(current.toString());
      current = StringBuffer();
    }
    current.write("$sentence ");
  }
  if (current.toString().trim().isNotEmpty) chunks.add(current.toString());
  return chunks;
}

Future<void> stopReadAloud() async {
  _session++;
  speakingMessageId = null;
  onReadAloudChanged?.call();
  try {
    await voice.stop();
  } catch (_) {}
  await stopPlayback();
}

/// Speaks [markdown] with the selected engine. Completes when it was read to
/// the end (true) or was stopped by [stopReadAloud] or another call (false).
/// [language] only applies to the device engine; by default it is guessed
/// from the text. Errors of a speech server are thrown.
Future<bool> speakText(String markdown,
    {String? language, double? rate}) async {
  final session = ++_session;
  final text = speakableText(markdown);
  if (text.isEmpty) return true;

  final server = ttsServer;
  if (server != null) {
    // short pieces so the first one is ready quickly; fetch the next piece
    // while the current one plays
    final chunks = _chunks(text, max: 400);
    Future<Uint8List> next = synthesize(server, chunks.first);
    for (var i = 0; i < chunks.length; i++) {
      final Uint8List audio;
      try {
        audio = await next;
      } catch (e) {
        if (session != _session) return false;
        rethrow;
      }
      if (i + 1 < chunks.length) {
        next = synthesize(server, chunks[i + 1]);
      }
      if (session != _session) {
        if (i + 1 < chunks.length) next.ignore();
        return false;
      }
      await playAudio(audio, server.ttsFormat);
      if (session != _session) {
        if (i + 1 < chunks.length) next.ignore();
        return false;
      }
    }
    return true;
  }

  try {
    // voice mode installs its own completion handler, neutralize it
    voice.setCompletionHandler(() {});
    await voice.awaitSpeakCompletion(true);
    language ??= _languageFor(text);
    final available = await voice.isLanguageAvailable(language);
    if (available == true || available == 1) {
      await voice.setLanguage(language);
    }
    await voice.setSpeechRate(rate ?? prefs?.getDouble("readAloudRate") ?? 0.5);

    for (final chunk in _chunks(text)) {
      if (session != _session) return false;
      await voice.speak(chunk);
    }
  } catch (_) {}
  return session == _session;
}

/// Reads [markdown] aloud; calling it for the message that is already being
/// read stops it instead.
Future<void> toggleReadAloud(String messageId, String markdown) async {
  if (speakingMessageId == messageId) {
    await stopReadAloud();
    return;
  }
  await stopReadAloud();
  speakingMessageId = messageId;
  onReadAloudChanged?.call();
  final session = _session + 1; // the one speakText is about to start

  try {
    await speakText(markdown);
  } catch (e) {
    if (mainContext != null && mainContext!.mounted) {
      ScaffoldMessenger.of(mainContext!).showSnackBar(SnackBar(
          content: Text(e.toString()),
          showCloseIcon: true,
          duration: const Duration(seconds: 8)));
    }
  }

  if (session == _session) {
    speakingMessageId = null;
    onReadAloudChanged?.call();
  }
}

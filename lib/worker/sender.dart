import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'chat_store.dart';
import 'composer.dart';
import 'haptic.dart';
import 'llm.dart';
import 'setter.dart';
import 'thinking.dart';
import '../main.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:uuid/uuid.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

/// Id of the assistant message that is currently streaming, if any.
String? streamingMessageId;

String systemPrompt([String? addToSystem]) {
  var system = prefs?.getString("system") ?? "You are a helpful assistant";
  if (prefs!.getBool("noMarkdown") ?? false) {
    system +=
        "\nYou must not use markdown or any other formatting language in any way!";
  }
  if (addToSystem != null) {
    system += "\n$addToSystem";
  }
  return system;
}

Future<String> _imageBase64(types.ImageMessage message) async {
  if (message.uri.startsWith("data:")) {
    return message.uri.substring(message.uri.indexOf(",") + 1);
  }
  return base64.encode(await File(message.uri).readAsBytes());
}

/// Builds the request history from the visible chat ([messages] is stored
/// newest first). Images and files are attached to the user message that
/// follows them.
Future<List<LlmMessage>> getHistory([String? addToSystem]) async {
  final List<LlmMessage> history = (prefs!.getBool("useSystem") ?? true)
      ? [LlmMessage("system", systemPrompt(addToSystem))]
      : [];

  List<String> images = [];
  List<types.FileMessage> files = [];

  String withFiles(String text) {
    if (files.isEmpty) return text;
    final buffer = StringBuffer();
    for (final file in files) {
      buffer.writeln("<file name=\"${file.name}\">");
      buffer.writeln(file.metadata?["text"]?.toString() ?? "");
      buffer.writeln("</file>");
      buffer.writeln();
    }
    buffer.write(text);
    return buffer.toString();
  }

  for (final message in messages.reversed) {
    if (message is types.ImageMessage) {
      try {
        images.add(await _imageBase64(message));
      } catch (_) {}
    } else if (message is types.FileMessage) {
      files.add(message);
    } else if (message is types.TextMessage) {
      if (message.author.id == user.id) {
        history.add(LlmMessage("user", withFiles(message.text), images));
        images = [];
        files = [];
      } else {
        history.add(LlmMessage("assistant", message.text));
      }
    }
  }
  if (images.isNotEmpty || files.isNotEmpty) {
    history.add(LlmMessage("user", withFiles(""), images));
  }
  return history;
}

/// The stored chat [uuid] as plain role/content pairs, for title generation.
Future<List> getHistoryString([String? uuid]) async {
  uuid ??= chatUuid!;
  final List messages = (await chatMessages(uuid))
      .map((m) => {
            "role": m.role,
            "content": m.content,
            if (m.type != messageText) "type": m.type,
            if (m.name != null) "name": m.name
          })
      .toList();

  if (messages.isNotEmpty && messages[0]["role"] == "system") {
    messages.removeAt(0);
  }
  for (var i = 0; i < messages.length; i++) {
    if (messages[i]["type"] == "image") {
      messages[i] = {
        "role": messages[i]["role"]!,
        "content": "<${messages[i]["role"]} inserted an image>"
      };
    } else if (messages[i]["type"] == "file") {
      messages[i] = {
        "role": messages[i]["role"]!,
        "content": "<${messages[i]["role"]} attached ${messages[i]["name"]}>"
      };
    }
  }

  return messages;
}

Future<String> getTitleAi(List history) async {
  var title = await chatComplete(model: model!, messages: [
    const LlmMessage("system",
        "Generate a three to six word title for the conversation provided by the user. If an object or person is very important in the conversation, put it in the title as well; keep the focus on the main subject. You must not put the assistant in the focus and you must not put the word 'assistant' in the title! Do preferably use title case. Use a formal tone, don't use dramatic words, like 'mystery' Use spaces between words, do not use camel case! You must not use markdown or any other formatting language! You must not use emojis or any other symbols! You must not use general clauses like 'assistance', 'help' or 'session' in your title! \n\n~~User Introduces Themselves~~ -> User Introduction\n~~User Asks for Help with a Problem~~ -> Problem Help\n~~User has a _**big**_ Problem~~ -> Big Problem"),
    LlmMessage("user", "```\n${jsonEncode(history)}\n```")
  ]);
  title = title.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), "");
  title = title.replaceAll("\n", " ");

  var terms = [
    "\"",
    "'",
    "*",
    "_",
    ".",
    ",",
    "!",
    "?",
    ":",
    ";",
    "(",
    ")",
    "[",
    "]",
    "{",
    "}"
  ];
  for (var i = 0; i < terms.length; i++) {
    title = title.replaceAll(terms[i], "");
  }

  title = title.replaceAll(RegExp(r'<.*?>', dotAll: true), "");
  if (title.split(":").length == 2) {
    title = title.split(":")[1];
  }

  while (title.contains("  ")) {
    title = title.replaceAll("  ", " ");
  }
  return title.trim();
}

Future<void> setTitleAi(List history, String uuid) async {
  try {
    var title = await getTitleAi(history);
    if (title.isEmpty) return;
    renameChat(uuid, title);
  } catch (_) {}
}

/// Sends [value] (plus [attachments]) and streams the answer into the chat.
///
/// If the request fails before any answer arrived, the message is taken out
/// of the chat again and put back into the input field together with its
/// attachments, and a snackbar offers to retry. Nothing the user wrote is
/// lost.
Future<String> send(String value, BuildContext context, Function setState,
    {void Function(String currentText, bool done)? onStream,
    String? addToSystem,
    List<PendingAttachment> attachments = const []}) async {
  selectionHaptic();
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final bool fromComposer = onStream == null;

  void abort(String text) {
    messenger
        .showSnackBar(SnackBar(content: Text(text), showCloseIcon: true));
    if (onStream != null) onStream("", true);
  }

  if (modelProvider == providerOpenAi ? !openAiConfigured : host == null) {
    abort(modelProvider == providerOpenAi
        ? l10n.noOpenAiHostSelected
        : l10n.noHostSelected);
    return "";
  }
  if (!chatAllowed || model == null) {
    if (model == null) {
      abort(l10n.noModelSelected);
    } else if (onStream != null) {
      onStream("", true);
    }
    return "";
  }

  if (value.trim().isEmpty && attachments.isEmpty) {
    if (onStream != null) onStream("", true);
    return "";
  }

  // the composer's text and attachments now belong to this request
  if (fromComposer) {
    inputController.clear();
    pendingAttachments = [];
    refreshComposer?.call();
  }

  bool newChat = false;
  if (chatUuid == null) {
    newChat = true;
    chatUuid = const Uuid().v4();
    createChat(chatUuid!, l10n.newChatTitle);
  }
  final String uuid = chatUuid!;

  // attachments can be sent without any text
  final List<types.Message> sentMessages = [
    ...attachments.map((a) => a.toMessage()),
    if (value.trim().isNotEmpty)
      types.TextMessage(
          author: user,
          id: const Uuid().v4(),
          createdAt: DateTime.now().millisecondsSinceEpoch,
          text: value.trim())
  ];
  for (final message in sentMessages) {
    messages.insert(0, message);
  }

  final history = await getHistory(addToSystem);
  saveChat(uuid, setState);

  chatAllowed = false;
  final String newId = const Uuid().v4();
  streamingMessageId = newId;
  setState(() {});

  final bool streamUi = (prefs!.getString("requestType") ?? "stream") == "stream";
  String raw = ""; // answer as streamed, may contain inline <think> tags
  String fieldThinking = ""; // reasoning delivered in its own field
  String text = "";
  String thinking = "";
  final stopwatch = Stopwatch();
  int? thinkingMs;
  String? error;
  // statistics shown by the message's info button
  final String usedModel = model!;
  final String usedProvider = modelProvider;
  final clock = Stopwatch()..start();
  int? firstTokenMs;
  Map<String, dynamic> serverUsage = {};

  void update() {
    final split = splitThinking(raw);
    text = split.answer;
    thinking = [fieldThinking.trim(), split.thinking]
        .where((t) => t.isNotEmpty)
        .join("\n\n");
    if (thinking.isNotEmpty && !stopwatch.isRunning && thinkingMs == null) {
      stopwatch.start();
    }
    if (text.trim().isNotEmpty && stopwatch.isRunning) {
      stopwatch.stop();
      thinkingMs = stopwatch.elapsedMilliseconds;
    }
  }

  Map<String, dynamic> usage({required bool stopped}) => {
        "model": usedModel,
        "provider": usedProvider,
        ...serverUsage,
        if (firstTokenMs != null) "firstTokenMs": firstTokenMs,
        "totalMs": clock.elapsedMilliseconds,
        if (stopped) "stopped": true,
      };

  void showAnswer({bool done = false, bool stopped = false}) {
    messages.removeWhere((m) => m.id == newId);
    if (done && stopwatch.isRunning) {
      stopwatch.stop();
      thinkingMs = stopwatch.elapsedMilliseconds;
    }
    if (chatUuid == uuid) {
      messages.insert(
          0,
          types.TextMessage(
              author: assistant,
              id: newId,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              text: text,
              metadata: {
                ...?thinkingMetadata(thinking, thinkingMs),
                if (done) "usage": usage(stopped: stopped)
              }));
    }
  }

  try {
    await for (final delta in chatStream(model: model!, messages: history)) {
      if (delta.usage != null) serverUsage = delta.usage!;
      if (firstTokenMs == null &&
          (delta.content.isNotEmpty || delta.thinking.isNotEmpty)) {
        firstTokenMs = clock.elapsedMilliseconds;
      }
      raw += delta.content;
      fieldThinking += delta.thinking;
      update();
      if (streamUi) {
        showAnswer();
        if (onStream != null) onStream(text, false);
        setState(() {});
        heavyHaptic();
      }
    }
  } catch (e) {
    error = e.toString();
  }
  final bool cancelled = generationCancelled;
  clock.stop();
  streamingMessageId = null;
  chatAllowed = true;

  if (text.trim().isEmpty && (error != null || cancelled)) {
    // nothing came back: undo the send and give the text back
    messages.removeWhere(
        (m) => m.id == newId || sentMessages.any((s) => s.id == m.id));
    if (messages.isEmpty && chatUuid == uuid) {
      removeChat(uuid);
      chatUuid = null;
    } else {
      saveChat(uuid, setState);
    }

    if (fromComposer) {
      inputController.text = value;
      inputController.selection =
          TextSelection.collapsed(offset: inputController.text.length);
      pendingAttachments = [...attachments, ...pendingAttachments];
      refreshComposer?.call();
    }
    setState(() {});

    if (error != null) {
      messenger.showSnackBar(SnackBar(
          content: Text(error),
          duration: const Duration(seconds: 12),
          showCloseIcon: true,
          action: fromComposer
              ? SnackBarAction(
                  label: l10n.retry,
                  onPressed: () {
                    if (!chatAllowed) return;
                    final retryAttachments = [...pendingAttachments];
                    final retryText = inputController.text.trim();
                    if (retryText.isEmpty && retryAttachments.isEmpty) {
                      return;
                    }
                    send(retryText, mainContext ?? context, setState,
                        attachments: retryAttachments);
                  })
              : null));
    }
    if (onStream != null) onStream("", true);
    return "";
  }

  // got an answer (possibly partial)
  showAnswer(done: true, stopped: cancelled || error != null);
  if (onStream != null) onStream(text, true);
  saveChat(uuid, setState);
  setState(() {});
  heavyHaptic();

  if (error != null) {
    messenger.showSnackBar(SnackBar(
        content: Text(error),
        duration: const Duration(seconds: 8),
        showCloseIcon: true));
  }

  if (newChat && (prefs!.getBool("generateTitles") ?? true)) {
    void setTitle() async {
      await setTitleAi(await getHistoryString(uuid), uuid);
      setState(() {});
    }

    setTitle();
  }

  return text;
}

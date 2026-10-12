import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'composer.dart';
import 'haptic.dart';
import 'llm.dart';
import 'setter.dart';
import '../main.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:dartx/dartx.dart';
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

List getHistoryString([String? uuid]) {
  uuid ??= chatUuid!;
  List messages = [];
  for (var i = 0; i < (prefs!.getStringList("chats") ?? []).length; i++) {
    if (jsonDecode((prefs!.getStringList("chats") ?? [])[i])["uuid"] == uuid) {
      messages = jsonDecode(
          jsonDecode((prefs!.getStringList("chats") ?? [])[i])["messages"]);
      break;
    }
  }

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
    var tmp = (prefs!.getStringList("chats") ?? []);
    for (var i = 0; i < tmp.length; i++) {
      if (jsonDecode(tmp[i])["uuid"] == uuid) {
        var tmp2 = jsonDecode(tmp[i]);
        tmp2["title"] = title;
        tmp[i] = jsonEncode(tmp2);
        break;
      }
    }
    prefs!.setStringList("chats", tmp);
  } catch (_) {}
}

void _removeChatEntry(String uuid) {
  var tmp = (prefs!.getStringList("chats") ?? []);
  for (var i = 0; i < tmp.length; i++) {
    if (jsonDecode(tmp[i])["uuid"] == uuid) {
      tmp.removeAt(i);
      prefs!.setStringList("chats", tmp);
      break;
    }
  }
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
    prefs!.setStringList(
        "chats",
        (prefs!.getStringList("chats") ?? []).append([
          jsonEncode({
            "title": l10n.newChatTitle,
            "uuid": chatUuid,
            "messages": []
          })
        ]).toList());
  }
  final String uuid = chatUuid!;

  final List<types.Message> sentMessages = [
    ...attachments.map((a) => a.toMessage()),
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
  String text = "";
  String thinking = "";
  String? error;

  void showAnswer({bool done = false}) {
    messages.removeWhere((m) => m.id == newId);
    // reasoning models think before answering; show a placeholder meanwhile
    final shown =
        (!done && text.isEmpty && thinking.isNotEmpty) ? "_…_" : text;
    if (chatUuid == uuid) {
      messages.insert(
          0, types.TextMessage(author: assistant, id: newId, text: shown));
    }
  }

  try {
    await for (final delta in chatStream(model: model!, messages: history)) {
      text += delta.content;
      thinking += delta.thinking;
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
  streamingMessageId = null;
  chatAllowed = true;

  if (text.trim().isEmpty && (error != null || cancelled)) {
    // nothing came back: undo the send and give the text back
    messages.removeWhere(
        (m) => m.id == newId || sentMessages.any((s) => s.id == m.id));
    if (messages.isEmpty && chatUuid == uuid) {
      _removeChatEntry(uuid);
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
                    if (retryText.isEmpty) return;
                    send(retryText, mainContext ?? context, setState,
                        attachments: retryAttachments);
                  })
              : null));
    }
    if (onStream != null) onStream("", true);
    return "";
  }

  // got an answer (possibly partial)
  showAnswer(done: true);
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
      await setTitleAi(getHistoryString(uuid), uuid);
      setState(() {});
    }

    setTitle();
  }

  return text;
}

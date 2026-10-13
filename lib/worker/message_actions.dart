// What a long press on a chat message offers: copy, edit, delete (just that
// message or it and everything after it, with undo). Tapping an image opens
// it full screen; tapping a file opens it in the app the system picks.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import '../main.dart';
import 'chat_store.dart';
import 'haptic.dart';
import 'setter.dart';

/// Text that "Copy" puts on the clipboard, or null if there is none.
String? _copyText(types.Message message) {
  if (message is types.TextMessage) return message.text;
  if (message is types.FileMessage) {
    final text = message.metadata?["text"]?.toString() ?? "";
    return text.isEmpty ? null : text;
  }
  return null;
}

void showMessageActions(
    BuildContext context, types.Message message, Function setState) {
  if (!chatAllowed || chatUuid == null) return;
  final l10n = AppLocalizations.of(context)!;
  final copyText = _copyText(message);
  final canEdit = message is types.TextMessage &&
      (prefs!.getBool("enableEditing") ?? true);
  final isLast = messages.isNotEmpty && messages.first.id == message.id;

  showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        Widget action(IconData icon, String label, VoidCallback onTap) =>
            ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () {
                  selectionHaptic();
                  Navigator.of(sheetContext).pop();
                  onTap();
                });

        return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (copyText != null)
                  action(Icons.copy_rounded, l10n.copyMessage, () {
                    Clipboard.setData(ClipboardData(text: copyText));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(l10n.copiedToClipboard),
                        showCloseIcon: true));
                  }),
                if (canEdit)
                  action(Icons.edit_rounded, l10n.messageActionEdit,
                      () => _editMessage(context, message, setState)),
                action(Icons.delete_outline_rounded, l10n.messageActionDelete,
                    () => _deleteMessages(context, message, setState)),
                if (!isLast)
                  action(
                      Icons.delete_sweep_rounded,
                      l10n.messageActionDeleteBelow,
                      () => _deleteMessages(context, message, setState,
                          andBelow: true)),
              ]),
            ));
      });
}

void _editMessage(
    BuildContext context, types.TextMessage message, Function setState) async {
  final text = message.text;
  final input = await prompt(
    context,
    title: AppLocalizations.of(context)!.dialogEditMessageTitle,
    value: text,
    keyboard: TextInputType.multiline,
    maxLines: (text.length >= 100) ? 10 : ((text.length >= 50) ? 5 : 3),
  );
  if (input == "" || input == text) return;
  final index = messages.indexWhere((m) => m.id == message.id);
  if (index == -1) return;
  messages[index] = message.copyWith(text: input);
  if (chatUuid != null) saveChat(chatUuid!, setState);
  setState(() {});
}

/// Removes [message] (and with [andBelow] every newer one) and offers to
/// undo it.
void _deleteMessages(
    BuildContext context, types.Message message, Function setState,
    {bool andBelow = false}) {
  final index = messages.indexWhere((m) => m.id == message.id);
  final uuid = chatUuid;
  if (index == -1 || uuid == null || !chatAllowed) return;
  final chat = findChat(uuid);
  final title = chat?.title ?? "";
  final before = List.of(messages);

  // newest first: everything below the message has a smaller index
  if (andBelow) {
    messages.removeRange(0, index + 1);
  } else {
    messages.removeAt(index);
  }
  // an emptied chat is deleted by saveChat
  saveChat(uuid, setState);
  setState(() {});

  final l10n = AppLocalizations.of(context)!;
  final removed = before.length - messages.length;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(l10n.messagesDeleted(removed)),
      duration: const Duration(seconds: 6),
      showCloseIcon: true,
      action: SnackBarAction(
          label: l10n.undo,
          onPressed: () {
            if (!chatAllowed) return;
            // the chat is no longer open; restore it in the background
            if (chatUuid != uuid && chatUuid != null) return;
            if (findChat(uuid) == null) createChat(uuid, title);
            chatUuid = uuid;
            messages = before;
            saveChat(uuid, setState);
            setState(() {});
          })));
}

// ---------------------------------------------------------------------------
// opening attachments

/// Hands [path] to the app the system picks; false if none could open it.
Future<bool> _openWithSystem(String path) async {
  if (kIsWeb) return false;
  try {
    final result = await OpenFilex.open(path);
    return result.type == ResultType.done;
  } catch (_) {
    return false;
  }
}

/// Opens an attached file. Without an original (attachments sent before
/// originals were kept, or no app for the type) its text is shown.
void openFileMessage(BuildContext context, types.FileMessage message) async {
  final text = message.metadata?["text"]?.toString() ?? "";
  final hasOriginal =
      !kIsWeb && message.uri != message.name && File(message.uri).existsSync();
  if (hasOriginal && await _openWithSystem(message.uri)) return;
  if (!context.mounted) return;
  if (hasOriginal) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.attachmentNoApp),
        showCloseIcon: true));
  }
  Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => _TextViewer(title: message.name, text: text)));
}

class _TextViewer extends StatelessWidget {
  final String title;
  final String text;

  const _TextViewer({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
        appBar: AppBar(
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                  tooltip: l10n.copyMessage,
                  onPressed: () {
                    selectionHaptic();
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(l10n.copiedToClipboard),
                        showCloseIcon: true));
                  },
                  icon: const Icon(Icons.copy_rounded))
            ]),
        body: SafeArea(
            top: false,
            child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(text.isEmpty ? "—" : text,
                    style: const TextStyle(
                        fontFamily: "monospace", fontSize: 13)))));
  }
}

/// Writes an image to a temporary file and opens it in another app (to
/// save, share or edit it).
Future<void> _openImageWithSystem(
    BuildContext context, types.ImageMessage message) async {
  try {
    final uri = message.uri;
    String path;
    if (uri.startsWith("data:")) {
      final dir = Directory(
          "${(await getTemporaryDirectory()).path}/attachments/${message.id}");
      await dir.create(recursive: true);
      var name = message.name.replaceAll(RegExp(r'[/\\]'), "_");
      if (!name.contains(".")) name += ".png";
      final file = File("${dir.path}/$name");
      if (!await file.exists()) {
        await file.writeAsBytes(
            base64.decode(uri.substring(uri.indexOf(",") + 1)),
            flush: true);
      }
      path = file.path;
    } else {
      path = uri;
    }
    if (await _openWithSystem(path)) return;
  } catch (_) {}
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.attachmentNoApp),
      showCloseIcon: true));
}

// ---------------------------------------------------------------------------
// image viewer

ImageProvider imageProvider(types.ImageMessage message) {
  final uri = message.uri;
  if (uri.startsWith("data:")) {
    return MemoryImage(base64.decode(uri.substring(uri.indexOf(",") + 1)));
  }
  if (uri.startsWith("http://") || uri.startsWith("https://")) {
    return NetworkImage(uri);
  }
  return FileImage(File(uri));
}

void openImageViewer(BuildContext context, types.ImageMessage message) {
  Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (context, animation, secondaryAnimation) => FadeTransition(
          opacity: animation, child: _ImageViewer(message: message))));
}

class _ImageViewer extends StatelessWidget {
  final types.ImageMessage message;

  const _ImageViewer({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
            backgroundColor: Colors.black54,
            foregroundColor: Colors.white,
            title: Text(message.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            leading: IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () {
                  selectionHaptic();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.close_rounded)),
            actions: [
              if (!kIsWeb)
                IconButton(
                    tooltip: AppLocalizations.of(context)!.attachmentOpenWith,
                    onPressed: () {
                      selectionHaptic();
                      _openImageWithSystem(context, message);
                    },
                    icon: const Icon(Icons.open_in_new_rounded))
            ]),
        body: InteractiveViewer(
            minScale: 1,
            maxScale: 8,
            child: SizedBox.expand(
                child: Image(
                    image: imageProvider(message),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Center(
                        child: Icon(Icons.broken_image_rounded,
                            color: Colors.white54, size: 48))))));
  }
}

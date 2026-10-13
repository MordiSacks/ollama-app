// Message composer: text input, attachments, dictation, send/stop.
//
// Replaces the stock flutter_chat_ui input so that we can
//  * keep (and restore) the text of a message whose request failed,
//  * attach any file, not only images,
//  * dictate with the device's speech recognition,
//  * stop a running generation,
//  * switch reasoning on or off for models that support it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import '../main.dart';
import 'desktop.dart';
import 'haptic.dart';
import 'llm.dart';
import 'speech.dart';

// ---------------------------------------------------------------------------
// shared state

/// Text of the message being written. Global so that a failed request can
/// put the text back.
final TextEditingController inputController = TextEditingController();

/// Attachments waiting to be sent with the next message.
List<PendingAttachment> pendingAttachments = [];

/// Rebuilds the composer from outside (e.g. after restoring a draft).
void Function()? refreshComposer;

/// Maximum characters of a text file that is sent to the model.
const int maxAttachmentChars = 150000;

class PendingAttachment {
  final String name;
  final int size;
  final String? imageBase64; // set for images
  final String? text; // set for text/pdf files
  final bool truncated;

  const PendingAttachment(
      {required this.name,
      required this.size,
      this.imageBase64,
      this.text,
      this.truncated = false});

  bool get isImage => imageBase64 != null;

  types.Message toMessage() {
    if (isImage) {
      return types.ImageMessage(
          author: user,
          id: const Uuid().v4(),
          createdAt: DateTime.now().millisecondsSinceEpoch,
          name: name,
          size: size,
          uri: "data:image/png;base64,$imageBase64");
    }
    return types.FileMessage(
        author: user,
        id: const Uuid().v4(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        name: name,
        size: size,
        mimeType: "text/plain",
        uri: name,
        metadata: {"text": text ?? ""});
  }

  /// Rebuilds an attachment from a chat message (used to restore a draft).
  static Future<PendingAttachment?> fromMessage(types.Message message) async {
    if (message is types.ImageMessage) {
      String data;
      if (message.uri.startsWith("data:")) {
        data = message.uri.substring(message.uri.indexOf(",") + 1);
      } else {
        try {
          data = base64.encode(await File(message.uri).readAsBytes());
        } catch (_) {
          return null;
        }
      }
      return PendingAttachment(
          name: message.name, size: message.size.toInt(), imageBase64: data);
    }
    if (message is types.FileMessage) {
      return PendingAttachment(
          name: message.name,
          size: message.size.toInt(),
          text: message.metadata?["text"]?.toString() ?? "");
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// reading files

const _imageExtensions = {"png", "jpg", "jpeg", "gif", "webp", "bmp"};

String _extractPdfText(Uint8List bytes) {
  final document = PdfDocument(inputBytes: bytes);
  try {
    return PdfTextExtractor(document).extractText();
  } finally {
    document.dispose();
  }
}

/// Turns picked file bytes into an attachment, or null if unsupported.
Future<PendingAttachment?> attachmentFromBytes(
    String name, Uint8List bytes) async {
  final ext = name.contains(".") ? name.split(".").last.toLowerCase() : "";

  if (_imageExtensions.contains(ext)) {
    return PendingAttachment(
        name: name, size: bytes.length, imageBase64: base64.encode(bytes));
  }

  String? text;
  if (ext == "pdf") {
    try {
      text = await compute(_extractPdfText, bytes);
    } catch (_) {
      return null;
    }
  } else {
    try {
      text = const Utf8Decoder(allowMalformed: false).convert(bytes);
      if (text.contains("\u0000")) text = null; // binary file
    } catch (_) {
      text = null;
    }
  }
  if (text == null) return null;

  bool truncated = false;
  if (text.length > maxAttachmentChars) {
    text = text.substring(0, maxAttachmentChars);
    truncated = true;
  }
  return PendingAttachment(
      name: name, size: bytes.length, text: text, truncated: truncated);
}

// ---------------------------------------------------------------------------
// widget

class ChatComposer extends StatefulWidget {
  /// Called with the trimmed text when the user sends.
  final void Function(String text) onSend;

  /// Whether an answer is currently being generated.
  final bool generating;

  /// Opens voice mode; null hides the option.
  final VoidCallback? onVoiceMode;

  /// Whether the selected model is known to understand images.
  final bool imagesSupported;

  /// Whether the selected model can be told to think or not.
  final bool thinkingSupported;

  const ChatComposer(
      {super.key,
      required this.onSend,
      required this.generating,
      this.onVoiceMode,
      this.imagesSupported = true,
      this.thinkingSupported = false});

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final FocusNode focusNode = FocusNode();
  final stt.SpeechToText dictation = speech;
  bool listening = false;
  String dictationBase = "";

  /// Dictation goes to a speech server: [listening] means recording.
  bool remoteDictation = false;
  bool transcribing = false;

  @override
  void initState() {
    super.initState();
    refreshComposer = () {
      if (mounted) setState(() {});
    };
    inputController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    inputController.removeListener(_onTextChanged);
    if (listening) {
      remoteDictation ? cancelRecording() : dictation.stop();
    }
    focusNode.dispose();
    refreshComposer = null;
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  bool get canSend =>
      inputController.text.trim().isNotEmpty &&
      !widget.generating &&
      !transcribing &&
      !(listening && remoteDictation);

  void _send() {
    if (!canSend) return;
    if (listening) _stopDictation();
    widget.onSend(inputController.text.trim());
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text), showCloseIcon: true));
  }

  // --- attachments ---------------------------------------------------------

  void _addAttachment(PendingAttachment attachment) {
    setState(() => pendingAttachments.add(attachment));
    if (attachment.isImage && !widget.imagesSupported) {
      _snack(AppLocalizations.of(context)!.attachmentImageMaybeUnsupported);
    }
    if (attachment.truncated) {
      _snack(AppLocalizations.of(context)!.attachmentTruncated);
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.any, allowMultiple: true, withData: true);
    if (result == null) return;
    for (final file in result.files) {
      Uint8List? bytes = file.bytes;
      if (bytes == null && !kIsWeb && file.path != null) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (_) {}
      }
      if (bytes == null) continue;
      final attachment = await attachmentFromBytes(file.name, bytes);
      if (!mounted) return;
      if (attachment == null) {
        _snack(AppLocalizations.of(context)!.attachmentUnsupported(file.name));
      } else {
        _addAttachment(attachment);
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final result = await ImagePicker()
        .pickImage(source: source, maxWidth: 2048, imageQuality: 85);
    if (result == null) return;
    final bytes = await result.readAsBytes();
    if (!mounted) return;
    _addAttachment(PendingAttachment(
        name: result.name,
        size: bytes.length,
        imageBase64: base64.encode(bytes)));
  }

  void _openAttachMenu() {
    selectionHaptic();
    final l10n = AppLocalizations.of(context)!;
    final bool mobile = !desktopFeature(web: true);
    showModalBottomSheet(
        context: context,
        builder: (sheetContext) {
          Widget option(IconData icon, String label, VoidCallback action) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                      onPressed: () {
                        selectionHaptic();
                        Navigator.of(sheetContext).pop();
                        action();
                      },
                      icon: Icon(icon),
                      label: Text(label))),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (widget.onVoiceMode != null)
                  option(Icons.headphones_rounded, l10n.settingsTitleVoice,
                      widget.onVoiceMode!),
                if (mobile)
                  option(Icons.photo_camera_rounded, l10n.takeImage,
                      () => _pickImage(ImageSource.camera)),
                if (mobile)
                  option(Icons.image_rounded, l10n.uploadImage,
                      () => _pickImage(ImageSource.gallery)),
                option(Icons.attach_file_rounded, l10n.attachFile, _pickFiles),
              ]),
            ),
          );
        });
  }

  // --- dictation -----------------------------------------------------------

  Future<void> _toggleDictation() async {
    selectionHaptic();
    if (listening) {
      _stopDictation();
      return;
    }
    final l10n = AppLocalizations.of(context)!;

    final server = sttServer;
    if (server != null) {
      await _startRemoteDictation(server);
      return;
    }

    if (!kIsWeb) {
      final status = await Permission.microphone.request();
      if (!mounted) return;
      if (!status.isGranted) {
        _snack(l10n.dictationPermissionDenied);
        return;
      }
    }
    bool available = false;
    try {
      available = await dictation.initialize();
    } catch (_) {}
    if (!mounted) return;
    if (!available) {
      _snack(l10n.dictationUnavailable);
      return;
    }

    final current = inputController.text;
    dictationBase = (current.isEmpty || current.endsWith(" ") ||
            current.endsWith("\n"))
        ? current
        : "$current ";
    setState(() => listening = true);

    final language = prefs?.getString("voiceLanguage");
    await dictation.listen(
        localeId: (language == null || language.isEmpty) ? null : language,
        listenFor: const Duration(minutes: 5),
        pauseFor: const Duration(seconds: 10),
        listenOptions: stt.SpeechListenOptions(
            listenMode: stt.ListenMode.dictation, partialResults: true),
        onResult: (result) {
          final text = dictationBase + result.recognizedWords;
          inputController.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length));
          if (result.finalResult) {
            dictationBase = "$text ";
          }
        });

    // The plugin may stop on its own (silence, errors); keep the UI in sync.
    while (listening && mounted) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (!dictation.isListening) {
        if (mounted) setState(() => listening = false);
      }
    }
  }

  void _stopDictation() {
    if (remoteDictation) {
      _finishRemoteDictation();
      return;
    }
    dictation.stop();
    if (mounted) setState(() => listening = false);
  }

  Future<void> _startRemoteDictation(SpeechServer server) async {
    final l10n = AppLocalizations.of(context)!;
    if (!await recordingPermission()) {
      if (mounted) _snack(l10n.dictationPermissionDenied);
      return;
    }
    try {
      await startRecording();
    } catch (e) {
      if (mounted) _snack(e.toString());
      return;
    }
    if (!mounted) {
      cancelRecording();
      return;
    }
    setState(() {
      remoteDictation = true;
      listening = true;
    });
  }

  Future<void> _finishRemoteDictation() async {
    final server = sttServer;
    setState(() {
      listening = false;
      transcribing = true;
    });
    String? text;
    String? error;
    try {
      final path = await stopRecording();
      if (path != null && server != null) {
        try {
          text = await transcribe(server, path);
        } finally {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      transcribing = false;
      remoteDictation = false;
    });
    if (error != null) {
      _snack(error);
    } else if (text != null && text.isNotEmpty) {
      final current = inputController.text;
      final joined = (current.isEmpty ||
              current.endsWith(" ") ||
              current.endsWith("\n"))
          ? "$current$text"
          : "$current $text";
      inputController.value = TextEditingValue(
          text: joined,
          selection: TextSelection.collapsed(offset: joined.length));
    }
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final bool showMic = !desktopFeature(web: true);

    Widget attachmentChip(PendingAttachment attachment) {
      return InputChip(
        avatar: Icon(attachment.isImage
            ? Icons.image_rounded
            : Icons.description_rounded),
        label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(attachment.name, overflow: TextOverflow.ellipsis)),
        onDeleted: () {
          selectionHaptic();
          setState(() => pendingAttachments.remove(attachment));
        },
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8, top: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (pendingAttachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children:
                        pendingAttachments.map(attachmentChip).toList()),
              ),
            ),
          Container(
            decoration: BoxDecoration(
                color: scheme.onSurface.withAlpha(
                    Theme.of(context).brightness == Brightness.light
                        ? 10
                        : 40),
                borderRadius: BorderRadius.circular(28)),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                      tooltip: l10n.tooltipAttachment,
                      onPressed: widget.generating ? null : _openAttachMenu,
                      icon: const Icon(Icons.add_rounded)),
                  if (widget.thinkingSupported)
                    IconButton(
                        tooltip: thinkingEnabled
                            ? l10n.thinkingToggleOn
                            : l10n.thinkingToggleOff,
                        onPressed: widget.generating
                            ? null
                            : () {
                                selectionHaptic();
                                setState(
                                    () => thinkingEnabled = !thinkingEnabled);
                              },
                        color: thinkingEnabled ? scheme.primary : null,
                        isSelected: thinkingEnabled,
                        selectedIcon: const Icon(Icons.lightbulb_rounded),
                        icon: const Icon(Icons.lightbulb_outline_rounded)),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (desktopFeature(web: true) &&
                            event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _send();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: inputController,
                        focusNode: focusNode,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        minLines: 1,
                        maxLines: 6,
                        decoration: InputDecoration(
                            hintText: transcribing
                                ? l10n.dictationTranscribing
                                : listening
                                ? l10n.dictationListening
                                : l10n.messageInputPlaceholder,
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 12)),
                      ),
                    ),
                  ),
                  if (showMic && transcribing)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              semanticsLabel: l10n.dictationTranscribing)),
                    )
                  else if (showMic)
                    IconButton(
                        tooltip: listening
                            ? l10n.dictationStop
                            : l10n.dictationStart,
                        onPressed: widget.generating ? null : _toggleDictation,
                        color: listening ? scheme.error : null,
                        icon: Icon(listening
                            ? Icons.stop_circle_rounded
                            : Icons.mic_none_rounded)),
                  widget.generating
                      ? IconButton(
                          tooltip: l10n.stopGenerating,
                          onPressed: () {
                            heavyHaptic();
                            cancelGeneration();
                          },
                          icon: const Icon(Icons.stop_rounded))
                      : IconButton(
                          tooltip: l10n.tooltipSend,
                          onPressed: canSend ? _send : null,
                          icon: const Icon(Icons.arrow_upward_rounded)),
                ]),
          ),
        ]),
      ),
    );
  }
}

import 'dart:io';
import 'dart:convert';
import 'package:universal_html/html.dart' as html;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../main.dart';
import '../worker/chat_store.dart';
import '../worker/haptic.dart';
import '../worker/setter.dart';
import '../worker/desktop.dart';
import '../screen_settings.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:intl/intl.dart';
import 'package:dynamic_color/dynamic_color.dart';

class ScreenSettingsExport extends StatefulWidget {
  const ScreenSettingsExport({super.key});

  @override
  State<ScreenSettingsExport> createState() => _ScreenSettingsExportState();
}

class _ScreenSettingsExportState extends State<ScreenSettingsExport> {
  @override
  Widget build(BuildContext context) {
    return WindowBorder(
      color: Theme.of(context).colorScheme.surface,
      child: Scaffold(
          appBar: AppBar(
              title: Row(children: [
                Text(AppLocalizations.of(context)!.settingsTitleExport),
                Expanded(child: SizedBox(height: 200, child: MoveWindow()))
              ]),
              actions: desktopControlsActions(context)),
          body: SafeArea(
              top: false,
              child: Center(
            child: Container(
                constraints: const BoxConstraints(maxWidth: 1000),
                padding: const EdgeInsets.only(left: 16, right: 16),
                child: Column(children: [
                  Expanded(
                    child: ListView(children: [
                      // const SizedBox(height: 8),
                      button(AppLocalizations.of(context)!.settingsExportChats,
                          Icons.upload_rounded, () async {
                        selectionHaptic();
                        var name =
                            "ollama-export-${DateFormat('yyyy-MM-dd-H-m-s').format(DateTime.now())}.json";
                        var content = await exportChats();
                        if (kIsWeb) {
                          // web fallback
                          final bytes = utf8.encode(content);
                          final blob = html.Blob([bytes]);
                          final url = html.Url.createObjectUrlFromBlob(blob);
                          final anchor = html.document.createElement("a")
                              as html.AnchorElement
                            ..href = url
                            ..style.display = "none"
                            ..download = name;
                          html.document.body!.children.add(anchor);

                          anchor.click();

                          html.document.body!.children.remove(anchor);
                          html.Url.revokeObjectUrl(url);
                        } else {
                          String? path = "";
                          try {
                            path = (await file_selector
                                    .getSaveLocation(acceptedTypeGroups: [
                              const file_selector.XTypeGroup(
                                  label: "Ollama App File",
                                  extensions: ["json"])
                            ], suggestedName: name))
                                ?.path;
                          } catch (_) {
                            path = await FilePicker.platform.saveFile(
                                type: FileType.custom,
                                allowedExtensions: ["json"],
                                fileName: name,
                                bytes: utf8.encode(content));
                          }
                          selectionHaptic();
                          if (path == null) return;
                          if (desktopFeature()) {
                            File(path).writeAsString(content);
                          }
                        }
                        // ignore: use_build_context_synchronously
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            // ignore: use_build_context_synchronously
                            content: Text(AppLocalizations.of(context)!
                                .settingsExportChatsSuccess),
                            showCloseIcon: true));
                      }),
                      allowMultipleChats
                          ? button(
                              AppLocalizations.of(context)!.settingsImportChats,
                              Icons.download_rounded, () async {
                              selectionHaptic();
                              final l10n = AppLocalizations.of(context)!;
                              final messenger = ScaffoldMessenger.of(context);
                              final bool? replace = await showDialog<bool>(
                                  context: context,
                                  builder: (context) {
                                    return AlertDialog(
                                        title: Text(l10n
                                            .settingsImportChatsTitle),
                                        content: Text(l10n
                                            .settingsImportChatsChoice),
                                        actions: [
                                          TextButton(
                                              onPressed: () {
                                                selectionHaptic();
                                                Navigator.of(context).pop();
                                              },
                                              child: Text(l10n
                                                  .settingsImportChatsCancel)),
                                          TextButton(
                                              onPressed: () {
                                                selectionHaptic();
                                                Navigator.of(context)
                                                    .pop(true);
                                              },
                                              child: Text(l10n
                                                  .settingsImportChatsReplace)),
                                          FilledButton.tonal(
                                              onPressed: () {
                                                selectionHaptic();
                                                Navigator.of(context)
                                                    .pop(false);
                                              },
                                              child: Text(l10n
                                                  .settingsImportChatsMerge)),
                                        ]);
                                  });
                              if (replace == null) return;

                              final content = await _pickExport();
                              if (content == null) return;
                              int count;
                              try {
                                count = await importChats(content,
                                    replace: replace);
                              } catch (_) {
                                messenger.showSnackBar(SnackBar(
                                    content: Text(
                                        l10n.settingsImportChatsFailed),
                                    showCloseIcon: true));
                                return;
                              }
                              // the open chat may have been replaced
                              final refresh = setGlobalState ?? setState;
                              if (replace || findChat(chatUuid) == null) {
                                messages = [];
                                chatUuid = null;
                              } else if (chatUuid != null) {
                                loadChat(chatUuid!, refresh);
                              }
                              refresh(() {});
                              messenger.showSnackBar(SnackBar(
                                  content: Text(
                                      l10n.settingsImportChatsCount(count)),
                                  showCloseIcon: true));
                            })
                          : const SizedBox.shrink()
                    ]),
                  ),
                  const SizedBox(height: 8),
                  button(AppLocalizations.of(context)!.settingsExportInfo,
                      Icons.info_rounded, null,
                      color: Colors.grey.harmonizeWith(
                          Theme.of(context).colorScheme.primary)),
                  button(AppLocalizations.of(context)!.settingsImportChatsMergeInfo,
                      Icons.warning_rounded, null,
                      color: Colors.orange
                          .harmonizeWith(Theme.of(context).colorScheme.primary))
                ])),
          ))),
    );
  }
}

/// Lets the user pick an export file; returns its content or null.
Future<String?> _pickExport() async {
  try {
    if (kIsWeb) throw Exception("web must use file picker");
    final result = await file_selector.openFile(acceptedTypeGroups: [
      const file_selector.XTypeGroup(
          label: "Ollama App File", extensions: ["json"])
    ]);
    return await result?.readAsString();
  } catch (_) {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ["json"]);
    if (result == null) return null;
    try {
      return await File(result.files.single.path!).readAsString();
    } catch (_) {
      // web fallback
      return utf8.decode(result.files.single.bytes as List<int>);
    }
  }
}

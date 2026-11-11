import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'chat_store.dart';
import 'composer.dart';
import 'desktop.dart';
import 'haptic.dart';
import '../main.dart';
import 'sender.dart';
import 'clients.dart';
import 'llm.dart';
import 'model_picker.dart';
import 'servers.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:dartx/dartx.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:http/http.dart' as http;

void setModel(BuildContext context, Function setState) {
  if (useModel) return;
  selectionHaptic();
  desktopTitleVisible = false;
  setState(() {});
  showModelPicker(context,
      onSelected: (picked) => selectModel(context, setState, picked),
      onPull: (server) => addModel(context, setState, server),
      onClosed: () => setState(() => desktopTitleVisible = true));
}

/// Makes [picked] the model of the current (or, if wanted, a new) chat.
void selectModel(
    BuildContext context, Function setState, ServerModel picked) async {
  final changed = picked.name != model || picked.server.id != modelServer?.id;
  if (changed &&
      (prefs!.getBool("resetOnModelSelect") ?? true) &&
      allowMultipleChats) {
    messages = [];
    chatUuid = null;
  }
  setState(() {
    model = picked.name;
    modelProvider = picked.server.id;
    multimodal = picked.vision;
    chatAllowed = true;
  });
  prefs?.setString("model", picked.name);
  prefs?.setString("modelProvider", picked.server.id);
  prefs?.setBool("multimodal", multimodal);

  if (!changed ||
      !picked.server.isOllama ||
      int.parse(prefs!.getString("keepAlive") ?? "300") == 0 ||
      !(prefs!.getBool("preloadModel") ?? true)) {
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final failedText = AppLocalizations.of(context)!.settingsHostInvalid("timeout");
  try {
    await preloadModel(picked.server, picked.name);
  } catch (_) {
    // another model was picked meanwhile
    if (model != picked.name || modelProvider != picked.server.id) return;
    messenger.showSnackBar(
        SnackBar(content: Text(failedText), showCloseIcon: true));
    setState(() {
      model = null;
      chatAllowed = false;
    });
  }
}

void addModel(
    BuildContext context, Function setState, LlmServer server) async {
  final ollamaClient = ollamaClientFor(server);
  bool canceled = false;
  bool networkError = false;
  bool ratelimitError = false;
  bool alreadyExists = false;
  final String invalidText =
      AppLocalizations.of(context)!.modelDialogAddPromptInvalid;
  final networkErrorText =
      AppLocalizations.of(context)!.settingsHostInvalid("other");
  final timeoutErrorText =
      AppLocalizations.of(context)!.settingsHostInvalid("timeout");
  final ratelimitErrorText =
      AppLocalizations.of(context)!.settingsHostInvalid("ratelimit");
  final alreadyExistsText =
      AppLocalizations.of(context)!.modelDialogAddPromptAlreadyExists;
  final downloadSuccessText =
      AppLocalizations.of(context)!.modelDialogAddDownloadSuccess;
  final downloadFailedText =
      AppLocalizations.of(context)!.modelDialogAddDownloadFailed;
  var requestedModel = await prompt(
    context,
    title: AppLocalizations.of(context)!.modelDialogAddPromptTitle,
    description: AppLocalizations.of(context)!.modelDialogAddPromptDescription,
    placeholder: "llama3:latest",
    enableSuggestions: false,
    validator: (content) async {
      var model = content.trim();
      model = model.removeSuffix(":latest");
      if (model == "") return false;
      canceled = false;
      networkError = false;
      ratelimitError = false;
      alreadyExists = false;
      try {
        var request = await ollamaClient.listModels().timeout(Duration(
            seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
        for (var element in request.models!) {
          var localModel = element.model!.removeSuffix(":latest");
          if (localModel == model) {
            alreadyExists = true;
          }
        }
        if (alreadyExists) return false;
      } catch (_) {
        networkError = true;
        return false;
      }
      var endpoint = "https://ollama.com/library/";
      if (kIsWeb) {
        if (!(prefs!.getBool("allowWebProxy") ?? false)) {
          bool returnValue = false;
          await showDialog(
              context: mainContext!,
              barrierDismissible: false,
              builder: (context) {
                return AlertDialog(
                    title: Text(AppLocalizations.of(context)!
                        .modelDialogAddAllowanceTitle),
                    content: SizedBox(
                      width: 640,
                      child: Text(AppLocalizations.of(context)!
                          .modelDialogAddAllowanceDescription),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () {
                            canceled = true;
                            Navigator.of(context).pop();
                          },
                          child: Text(AppLocalizations.of(context)!
                              .modelDialogAddAllowanceDeny)),
                      TextButton(
                          onPressed: () {
                            returnValue = true;
                            Navigator.of(context).pop();
                          },
                          child: Text(AppLocalizations.of(context)!
                              .modelDialogAddAllowanceAllow))
                    ]);
              });
          if (!returnValue) return false;
          prefs!.setBool("allowWebProxy", true);
        }
        endpoint = "https://end.jhubi1.com/ollama-proxy/";
      }
      http.Response response;
      try {
        response = await httpClient
            .get(Uri.parse("$endpoint${Uri.encodeComponent(model)}"))
            .timeout(Duration(
                seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                    .round()));
      } catch (_) {
        networkError = true;
        return false;
      }
      if (response.statusCode == 200) {
        bool returnValue = false;
        await showDialog(
            context: mainContext!,
            barrierDismissible: false,
            builder: (context) {
              return AlertDialog(
                  title: Text(AppLocalizations.of(context)!
                      .modelDialogAddAssuranceTitle(model)),
                  content: SizedBox(
                    width: 640,
                    child: Text(AppLocalizations.of(context)!
                        .modelDialogAddAssuranceDescription(model)),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () {
                          canceled = true;
                          Navigator.of(context).pop();
                        },
                        child: Text(AppLocalizations.of(context)!
                            .modelDialogAddAssuranceCancel)),
                    TextButton(
                        onPressed: () {
                          returnValue = true;
                          Navigator.of(context).pop();
                        },
                        child: Text(AppLocalizations.of(context)!
                            .modelDialogAddAssuranceAdd))
                  ]);
            });
        return returnValue;
      }
      if (response.statusCode == 429) {
        ratelimitError = true;
      }
      return false;
    },
    validatorErrorCallback: (content) {
      if (networkError) return networkErrorText;
      if (ratelimitError) return ratelimitErrorText;
      if (alreadyExists) return alreadyExistsText;
      if (canceled) return null;
      return invalidText;
    },
  );
  if (requestedModel == "") return;
  requestedModel = requestedModel.removeSuffix(":latest");
  double? percent;
  Function? setDialogState;
  showModalBottomSheet(
      context: mainContext!,
      builder: (context) {
        return StatefulBuilder(builder: (context, setLocalState) {
          setDialogState = setLocalState;
          return SafeArea(
              top: false,
              child: PopScope(
              canPop: false,
              child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: desktopLayout(context) ? 16 : 0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        percent == null
                            ? AppLocalizations.of(context)!
                                .modelDialogAddDownloadPercentLoading
                            : AppLocalizations.of(context)!
                                .modelDialogAddDownloadPercent(
                                    (percent * 100).round().toString()),
                      ),
                      const Padding(padding: EdgeInsets.only(top: 8)),
                      LinearProgressIndicator(value: percent),
                    ],
                  ))));
        });
      });
  try {
    final stream = ollamaClient
        .pullModelStream(request: llama.PullModelRequest(model: requestedModel))
        .timeout(Duration(
            seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
    bool alreadyProgressed = false;
    await for (final res in stream) {
      double tmpPercent =
          ((res.completed ?? 0).toInt() / (res.total ?? 100).toInt());
      if ((tmpPercent * 100).round() == 0) {
        if (!alreadyProgressed) {
          percent = null;
        }
      } else {
        percent = tmpPercent;
        alreadyProgressed = true;
      }
      setDialogState!(() {});
    }
    // done downloading
    if (prefs!.getBool("resetOnModelSelect") ?? true && allowMultipleChats) {
      messages = [];
      chatUuid = null;
    }
    model = requestedModel;
    if (model!.split(":").length == 1) {
      model = "$model:latest";
    }
    bool exists = false;
    try {
      var request = await ollamaClient.listModels().timeout(Duration(
          seconds:
              (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0)).round()));
      for (var element in request.models!) {
        if (element.model == model) {
          exists = true;
          multimodal = (element.details!.families ?? []).contains("clip");
          try {
            final details = await ollamaClient.showModelInfo(
                request: llama.ModelInfoRequest(model: model!));
            final capabilities = details.capabilities ?? [];
            multimodal =
                multimodal || capabilities.contains(llama.Capability.vision);
            rememberThinkingSupport(
                model!, capabilities.contains(llama.Capability.thinking));
          } catch (_) {}
        }
      }
      if (!exists) {
        throw Exception();
      }
    } catch (_) {
      setState(() {
        model = null;
        multimodal = false;
        chatAllowed = false;
      });
      prefs?.remove("model");
      prefs?.setBool("multimodal", multimodal);
      Navigator.of(mainContext!).pop();
      if (!exists) {
        ScaffoldMessenger.of(mainContext!).showSnackBar(
            SnackBar(content: Text(downloadFailedText), showCloseIcon: true));
      } else {
        ScaffoldMessenger.of(mainContext!).showSnackBar(
            SnackBar(content: Text(timeoutErrorText), showCloseIcon: true));
      }
      return;
    }
    modelProvider = server.id;
    prefs?.setString("model", model!);
    prefs?.setString("modelProvider", modelProvider);
    prefs?.setBool("multimodal", multimodal);
    setState(() {
      chatAllowed = true;
    });
    Navigator.of(mainContext!).pop();
    ScaffoldMessenger.of(mainContext!).showSnackBar(
        SnackBar(content: Text(downloadSuccessText), showCloseIcon: true));
  } catch (_) {
    Navigator.of(mainContext!).pop();
    ScaffoldMessenger.of(mainContext!).showSnackBar(
        SnackBar(content: Text(downloadFailedText), showCloseIcon: true));
  }
}

/// Converts a chat bubble into its stored form; null if it can't be stored.
StoredMessage? storedMessage(types.Message message) {
  final role = (message.author == user) ? "user" : "assistant";
  if (message is types.TextMessage) {
    return StoredMessage(
        id: message.id,
        role: role,
        content: message.text,
        createdAt: message.createdAt,
        meta: message.metadata);
  } else if (message is types.FileMessage) {
    return StoredMessage(
        id: message.id,
        role: role,
        type: messageFile,
        name: message.name,
        size: message.size.toInt(),
        content: message.metadata?["text"]?.toString() ?? "",
        createdAt: message.createdAt,
        dataPath: (!kIsWeb && message.uri != message.name)
            ? message.uri
            : null);
  } else if (message is types.ImageMessage) {
    final uri = message.uri;
    final inline = uri.startsWith("data:");
    return StoredMessage(
        id: message.id,
        role: role,
        type: messageImage,
        name: message.name,
        size: message.size.toInt(),
        content: inline ? uri.substring(uri.indexOf(",") + 1) : "",
        createdAt: message.createdAt,
        dataPath: inline ? null : uri);
  }
  return null;
}

/// Converts a stored message back into a chat bubble.
types.Message chatMessage(StoredMessage message) {
  final author = (message.role == "user") ? user : assistant;
  switch (message.type) {
    case messageFile:
      return types.FileMessage(
          author: author,
          id: message.id,
          createdAt: message.createdAt,
          name: message.name ?? "file",
          size: message.size ?? 0,
          mimeType: attachmentMimeType(message.name ?? ""),
          uri: message.dataPath ?? message.name ?? "file",
          metadata: {"text": message.content});
    case messageImage:
      return types.ImageMessage(
          author: author,
          id: message.id,
          createdAt: message.createdAt,
          name: message.name ?? "image",
          size: message.size ?? 0,
          uri: message.dataPath ?? "data:image/png;base64,${message.content}");
    default:
      return types.TextMessage(
          author: author,
          id: message.id,
          createdAt: message.createdAt,
          text: message.content,
          metadata: message.meta);
  }
}

/// Saves the visible chat ([messages]) as chat [uuid].
void saveChat(String uuid, Function setState) async {
  if (findChat(uuid) == null) return;
  if (messages.isEmpty && uuid == chatUuid) {
    // an emptied chat is deleted, but its files stay for a possible undo
    removeChat(uuid, keepFiles: true);
    chatUuid = null;
    return;
  }
  // newest first on screen, oldest first in the store
  final snapshot = messages.reversed.toList();
  final storedModel = model;
  final storedProvider = modelProvider;
  final List<StoredMessage> stored = [];
  for (final message in snapshot) {
    final converted = storedMessage(message);
    if (converted != null) stored.add(converted);
  }
  var system = prefs?.getString("system") ?? "You are a helpful assistant";
  if (prefs!.getBool("noMarkdown") ?? false) {
    system +=
        " You must not use markdown or any other formatting language in any way!";
  }
  await storeChat(uuid, stored,
      model: storedModel, provider: storedProvider, system: system);
  setState(() {});
}

void loadChat(String uuid, Function setState) async {
  final chat = findChat(uuid);
  if (chat == null) return;
  messages = [];
  model = null;
  setState(() {});
  final stored = await chatMessages(uuid);
  // another chat was opened meanwhile
  if (chatUuid != uuid) return;
  messages = stored.reversed.map(chatMessage).toList();
  model = chat.model;
  // chats of older versions store "ollama", "openai" or nothing
  modelProvider =
      serverById(chat.provider)?.id ?? chat.provider ?? legacyOllamaId;
  setState(() {});
  refreshThinkingSupport(setState);
}

/// Asks Ollama whether the selected model can think, so the composer shows
/// the thinking toggle even before the model list was ever opened.
void refreshThinkingSupport(Function setState) async {
  final name = model;
  final server = modelServer;
  if (name == null || server == null || !server.isOllama) return;
  try {
    final details = await ollamaClientFor(server)
        .showModelInfo(request: llama.ModelInfoRequest(model: name))
        .timeout(Duration(
            seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
    final supported =
        (details.capabilities ?? []).contains(llama.Capability.thinking);
    if (supported == modelCanThink(name, server.id)) return;
    rememberThinkingSupport(name, supported);
    setState(() {});
  } catch (_) {}
}

Future<bool> deleteChatDialog(BuildContext context, Function setState,
    {bool takeAction = true,
    bool? additionalCondition,
    String? uuid,
    bool popSidebar = false}) async {
  additionalCondition ??= true;
  uuid ??= chatUuid;

  bool returnValue = false;
  void delete(BuildContext context) {
    returnValue = true;
    if (takeAction) {
      removeChat(uuid!);
      if (chatUuid == uuid) {
        messages = [];
        chatUuid = null;
        if (!desktopLayoutRequired(context) &&
            Navigator.of(context).canPop() &&
            popSidebar) {
          Navigator.of(context).pop();
        }
      }
    }
  }

  if ((prefs!.getBool("askBeforeDeletion") ?? false) && additionalCondition) {
    await showDialog(
        context: context,
        builder: (context) {
          return StatefulBuilder(builder: (context, setLocalState) {
            return AlertDialog(
                title: Text(AppLocalizations.of(context)!.deleteDialogTitle),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(AppLocalizations.of(context)!.deleteDialogDescription),
                ]),
                actions: [
                  TextButton(
                      onPressed: () {
                        selectionHaptic();
                        Navigator.of(context).pop();
                      },
                      child: Text(
                          AppLocalizations.of(context)!.deleteDialogCancel)),
                  TextButton(
                      onPressed: () {
                        selectionHaptic();
                        Navigator.of(context).pop();
                        delete(context);
                      },
                      child: Text(
                          AppLocalizations.of(context)!.deleteDialogDelete))
                ]);
          });
        });
  } else {
    delete(context);
  }
  setState(() {});
  return returnValue;
}

Future<String> prompt(BuildContext context,
    {String description = "",
    String value = "",
    String title = "",
    String? valueIfCanceled,
    TextInputType keyboard = TextInputType.text,
    bool autocorrect = true,
    Iterable<String> autofillHints = const [],
    bool enableSuggestions = true,
    Icon? prefixIcon,
    int maxLines = 1,
    String? uuid,
    Future<bool> Function(String content)? validator,
    String? validatorError,
    String? Function(String content)? validatorErrorCallback,
    String? placeholder,
    bool prefill = true}) async {
  var returnText = (valueIfCanceled != null) ? valueIfCanceled : value;
  final TextEditingController controller =
      TextEditingController(text: prefill ? value : "");
  bool loading = false;
  String? error;
  await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, setLocalState) {
          void submit() async {
            selectionHaptic();
            if (validator != null) {
              setLocalState(() {
                error = null;
                loading = true;
              });
              bool valid = await validator(controller.text);
              setLocalState(() {
                loading = false;
              });
              if (!valid) {
                setLocalState(() {
                  if (validatorError != null) {
                    error = validatorError;
                  } else if (validatorErrorCallback != null) {
                    error = validatorErrorCallback(controller.text);
                  } else {
                    error = null;
                  }
                });
                return;
              }
            }
            returnText = controller.text;
            // ignore: use_build_context_synchronously
            Navigator.of(context).pop();
          }

          return PopScope(
              child: Container(
                  padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 16,
                      bottom: desktopFeature(web: true)
                          ? 12
                          : MediaQuery.of(context).viewInsets.bottom +
                              MediaQuery.of(context).padding.bottom),
                  width: double.infinity,
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        (title != "")
                            ? Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))
                            : const SizedBox.shrink(),
                        (title != "")
                            ? const Divider()
                            : const SizedBox.shrink(),
                        (description != "")
                            ? Text(description)
                            : const SizedBox.shrink(),
                        const SizedBox(height: 8),
                        TextField(
                            controller: controller,
                            autofocus: true,
                            keyboardType: keyboard,
                            autocorrect: autocorrect,
                            autofillHints: autofillHints,
                            enableSuggestions: enableSuggestions,
                            maxLines: maxLines,
                            onSubmitted: (_) => submit(),
                            decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                hintText: placeholder,
                                errorText: error,
                                suffixIcon: IconButton(
                                    enableFeedback: false,
                                    tooltip: AppLocalizations.of(context)!
                                        .tooltipSave,
                                    onPressed: submit,
                                    icon: const Icon(Icons.save_rounded)),
                                prefixIcon: (title ==
                                            AppLocalizations.of(context)!
                                                .dialogEnterNewTitle &&
                                        uuid != null)
                                    ? IconButton(
                                        enableFeedback: false,
                                        tooltip: AppLocalizations.of(context)!
                                            .tooltipLetAIThink,
                                        onPressed: () async {
                                          selectionHaptic();
                                          setLocalState(() {
                                            loading = true;
                                          });

                                          try {
                                            var title = await getTitleAi(
                                                await getHistoryString(uuid));
                                            controller.text = title;
                                            setLocalState(() {
                                              loading = false;
                                            });
                                          } catch (_) {
                                            try {
                                              setLocalState(() {
                                                loading = false;
                                              });
                                              // ignore: use_build_context_synchronously
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(SnackBar(
                                                      content: Text(
                                                          AppLocalizations.of(
                                                                  // ignore: use_build_context_synchronously
                                                                  context)!
                                                              .settingsHostInvalid(
                                                                  "timeout")),
                                                      showCloseIcon: true));
                                            } catch (_) {}
                                          }
                                        },
                                        icon: const Icon(
                                            Icons.auto_awesome_rounded))
                                    : prefixIcon)),
                        SizedBox(
                            height: 3,
                            child: (loading)
                                ? const LinearProgressIndicator()
                                : const SizedBox.shrink()),
                        (MediaQuery.of(context).viewInsets.bottom != 0)
                            ? const SizedBox(height: 16)
                            : const SizedBox.shrink()
                      ])));
        });
      });
  return returnText;
}

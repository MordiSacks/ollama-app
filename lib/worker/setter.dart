import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'chat_store.dart';
import 'composer.dart';
import 'desktop.dart';
import 'haptic.dart';
import '../main.dart';
import 'sender.dart';
import 'theme.dart';
import 'clients.dart';
import 'llm.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:dartx/dartx.dart';
import 'package:ollama_dart/ollama_dart.dart' as llama;
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:http/http.dart' as http;

void setModel(BuildContext context, Function setState) {
  List<String> models = [];
  List<String> modelsReal = [];
  List<bool> modal = [];
  List<String> providers = [];
  int usedIndex = -1;
  int oldIndex = -1;
  int addIndex = -1;
  bool loaded = false;
  Function? setModalState;
  desktopTitleVisible = false;
  setState(() {});
  void load() async {
    try {
      bool anyServerReachable = false;
      if (host != null) {
        try {
          var list = await ollamaClient.listModels().timeout(Duration(
              seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                  .round()));
          anyServerReachable = true;
          for (var i = 0; i < list.models!.length; i++) {
            bool vision = (list.models![i].details!.families ?? [])
                .contains("clip");
            try {
              var details = await ollamaClient.showModelInfo(
                  request:
                      llama.ModelInfoRequest(model: list.models![i].model!));
              final capabilities = details.capabilities ?? [];
              vision = vision ||
                  capabilities.contains(llama.Capability.vision);
              rememberThinkingSupport(list.models![i].model!,
                  capabilities.contains(llama.Capability.thinking));
            } catch (_) {}
            models.add(list.models![i].model!.split(":")[0]);
            modelsReal.add(list.models![i].model!);
            modal.add(vision);
            providers.add(providerOllama);
          }
        } catch (_) {}
      }
      if (openAiConfigured) {
        try {
          var list = await listOpenAiModels();
          anyServerReachable = true;
          for (var id in list) {
            models.add(id);
            modelsReal.add(id);
            // capabilities are unknown for OpenAI-compatible servers
            modal.add(true);
            providers.add(providerOpenAi);
          }
        } catch (_) {}
      }
      if (!anyServerReachable) throw Exception("no server reachable");

      addIndex = models.length;
      // ignore: use_build_context_synchronously
      models.add(AppLocalizations.of(context)!.modelDialogAddModel);
      // ignore: use_build_context_synchronously
      modelsReal.add(AppLocalizations.of(context)!.modelDialogAddModel);
      modal.add(false);
      providers.add(providerOllama);

      for (var i = 0; i < modelsReal.length; i++) {
        if (modelsReal[i] == model && providers[i] == modelProvider) {
          usedIndex = i;
          oldIndex = usedIndex;
        }
      }
      if (prefs!.getBool("modelTags") == null) {
        List duplicateFinder = [];
        for (var model in models) {
          if (duplicateFinder.contains(model)) {
            prefs!.setBool("modelTags", true);
            break;
          } else {
            duplicateFinder.add(model);
          }
        }
      }
      loaded = true;
      setModalState!(() {});
    } catch (_) {
      setState(() {
        desktopTitleVisible = true;
      });
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop();
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              // ignore: use_build_context_synchronously
              AppLocalizations.of(context)!.settingsHostInvalid("timeout")),
          showCloseIcon: true));
    }
  }

  if (useModel) return;
  selectionHaptic();

  load();

  var content = StatefulBuilder(builder: (context, setLocalState) {
    setModalState = setLocalState;
    return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (!loaded) return;
          loaded = false;
          bool preload = false;
          if (usedIndex >= 0 &&
              (modelsReal[usedIndex] != model ||
                  providers[usedIndex] != modelProvider)) {
            preload = true;
            if (prefs!.getBool("resetOnModelSelect") ??
                true && allowMultipleChats) {
              messages = [];
              chatUuid = null;
            }
          }
          model = (usedIndex >= 0) ? modelsReal[usedIndex] : null;
          chatAllowed = !(model == null);
          multimodal = (usedIndex >= 0) ? modal[usedIndex] : false;
          modelProvider =
              (usedIndex >= 0) ? providers[usedIndex] : providerOllama;
          if (model != null) {
            prefs?.setString("model", model!);
          } else {
            prefs?.remove("model");
          }
          prefs?.setBool("multimodal", multimodal);
          prefs?.setString("modelProvider", modelProvider);

          if (model != null &&
              preload &&
              modelProvider == providerOllama &&
              int.parse(prefs!.getString("keepAlive") ?? "300") != 0 &&
              (prefs!.getBool("preloadModel") ?? true)) {
            setLocalState(() {});
            try {
              // don't use llama client, package doesn't support just loading without content
              await httpClient
                  .post(
                    Uri.parse("$host/api/generate"),
                    headers: {
                      "Content-Type": "application/json",
                      ...(jsonDecode(prefs!.getString("hostHeaders") ?? "{}")
                          as Map)
                    }.cast<String, String>(),
                    body: jsonEncode({
                      "model": model!,
                      "keep_alive":
                          int.parse(prefs!.getString("keepAlive") ?? "300")
                    }),
                  )
                  .timeout(Duration(
                      seconds: (10.0 *
                              (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                          .round()));
            } catch (_) {
              // ignore: use_build_context_synchronously
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  // ignore: use_build_context_synchronously
                  content: Text(AppLocalizations.of(context)!
                      .settingsHostInvalid("timeout")),
                  showCloseIcon: true));
              setState(() {
                model = null;
                chatAllowed = false;
              });
            }
            setState(() {
              desktopTitleVisible = true;
            });
            // ignore: use_build_context_synchronously
            Navigator.of(context).pop();
          } else {
            setState(() {
              desktopTitleVisible = true;
            });
            try {
              Navigator.of(context).pop();
            } catch (_) {}
          }
        },
        child: Container(
            width: desktopLayout(context) ? null : double.infinity,
            padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: desktopLayout(context) ? 16 : 0),
            child: (!loaded)
                ? SizedBox(
                    width: desktopLayout(context) ? 300 : double.infinity,
                    child: const LinearProgressIndicator())
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: desktopLayout(context) ? 300 : double.infinity,
                        constraints: BoxConstraints(
                            maxHeight:
                                MediaQuery.of(context).size.height * 0.4),
                        child: SingleChildScrollView(
                            scrollDirection: Axis.vertical,
                            child: Wrap(
                              spacing: desktopLayout(context) ? 10.0 : 5.0,
                              runSpacing:
                                  desktopFeature(web: true) ? 10.0 : 0.0,
                              alignment: WrapAlignment.center,
                              children: List<Widget>.generate(
                                models.length,
                                (int index) {
                                  return ChoiceChip(
                                    label: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(models[index]),
                                          ((prefs!.getBool("modelTags") ??
                                                      false) &&
                                                  modelsReal[index]
                                                          .split(":")
                                                          .length >
                                                      1)
                                              ? Text(
                                                  ":${modelsReal[index].split(":")[1]}",
                                                  style: const TextStyle(
                                                      color: Colors.grey))
                                              : const SizedBox.shrink()
                                        ]),
                                    selected: usedIndex == index,
                                    avatar: (usedIndex == index)
                                        ? null
                                        : (addIndex == index)
                                            ? const Icon(Icons.add_rounded)
                                            : (providers[index] ==
                                                    providerOpenAi)
                                                ? const Icon(Icons.dns_rounded)
                                                : ((recommendedModels
                                                    .contains(models[index]))
                                                ? const Icon(Icons.star_rounded)
                                                : ((modal[index])
                                                    ? const Icon(Icons
                                                        .collections_rounded)
                                                    : null)),
                                    checkmarkColor: (usedIndex == index &&
                                            !(prefs?.getBool(
                                                    "useDeviceTheme") ??
                                                false))
                                        ? ((MediaQuery.of(context)
                                                    .platformBrightness ==
                                                Brightness.light)
                                            ? themeLight().colorScheme.secondary
                                            : themeDark().colorScheme.secondary)
                                        : null,
                                    labelStyle: (usedIndex == index &&
                                            !(prefs?.getBool(
                                                    "useDeviceTheme") ??
                                                false))
                                        ? TextStyle(
                                            color: (MediaQuery.of(context)
                                                        .platformBrightness ==
                                                    Brightness.light)
                                                ? themeLight()
                                                    .colorScheme
                                                    .secondary
                                                : themeDark()
                                                    .colorScheme
                                                    .secondary)
                                        : null,
                                    selectedColor: (prefs
                                                ?.getBool("useDeviceTheme") ??
                                            false)
                                        ? null
                                        : (MediaQuery.of(context)
                                                    .platformBrightness ==
                                                Brightness.light)
                                            ? themeLight().colorScheme.primary
                                            : themeDark().colorScheme.primary,
                                    onSelected: (bool selected) {
                                      selectionHaptic();
                                      if (addIndex == index) {
                                        usedIndex = oldIndex;
                                        Navigator.of(context).pop();
                                        addModel(context, setState);
                                      }
                                      if (!chatAllowed && model != null) {
                                        return;
                                      }
                                      setLocalState(() {
                                        usedIndex = selected ? index : -1;
                                      });
                                    },
                                  );
                                },
                              ).toList(),
                            )))
                  ])));
  });

  if (desktopLayoutNotRequired(context)) {
    showDialog(
        context: context,
        builder: (context) {
          return Transform.translate(
            offset: desktopLayoutRequired(context)
                ? const Offset(289, 0)
                : const Offset(0, 0),
            child: Dialog(
                surfaceTintColor:
                    (Theme.of(context).brightness == Brightness.dark)
                        ? Colors.grey[800]
                        : null,
                alignment: desktopLayoutRequired(context)
                    ? Alignment.topLeft
                    : Alignment.topCenter,
                child: content),
          );
        });
  } else {
    showModalBottomSheet(
        context: context,
        builder: (context) => SafeArea(top: false, child: content));
  }
}

void addModel(BuildContext context, Function setState) async {
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
    modelProvider = providerOllama;
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
  modelProvider = chat.provider ?? providerOllama;
  setState(() {});
  refreshThinkingSupport(setState);
}

/// Asks Ollama whether the selected model can think, so the composer shows
/// the thinking toggle even before the model list was ever opened.
void refreshThinkingSupport(Function setState) async {
  final name = model;
  if (name == null || modelProvider != providerOllama || host == null) return;
  try {
    final details = await ollamaClient
        .showModelInfo(request: llama.ModelInfoRequest(model: name))
        .timeout(Duration(
            seconds: (10.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
    final supported =
        (details.capabilities ?? []).contains(llama.Capability.thinking);
    if (supported == modelCanThink(name, providerOllama)) return;
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

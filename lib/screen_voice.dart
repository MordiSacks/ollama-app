import 'dart:io';

import 'package:flutter/material.dart';

import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:datetime_loop/datetime_loop.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'main.dart';
import 'worker/sender.dart';
import 'worker/llm.dart';
import 'worker/haptic.dart';
import 'worker/setter.dart';
import 'worker/speech.dart';
import 'worker/read_aloud.dart';
import 'worker/theme.dart';
import 'settings/voice.dart';

class ScreenVoice extends StatefulWidget {
  const ScreenVoice({super.key});

  @override
  State<ScreenVoice> createState() => _ScreenVoiceState();
}

class _ScreenVoiceState extends State<ScreenVoice> {
  Iterable<String> languageOptionIds = [];
  Iterable<String> languageOptions = [];

  bool speaking = false;
  bool aiThinking = false;

  bool sttDone = true;
  String text = "";
  String aiText = "";

  bool intendedStop = false;

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.toString()),
        showCloseIcon: true,
        duration: const Duration(seconds: 8)));
  }

  /// Listens with a speech server. Returns false if processing should stop.
  Future<bool> _listenRemote(SpeechServer server) async {
    setState(() {
      speaking = true;
      sttDone = false;
      text = "";
    });

    String? path;
    try {
      path = await recordUtterance(keepGoing: () => speaking && mounted);
    } catch (e) {
      speaking = false;
      if (mounted) setState(() {});
      _showError(e);
      return false;
    }
    if (!speaking) {
      if (!intendedStop) {
        // closed or cancelled
        if (path != null) File(path).delete().ignore();
        return false;
      }
      intendedStop = false;
      speaking = true;
    }
    if (path == null) {
      speaking = false;
      if (mounted) setState(() {});
      return false;
    }

    if (mounted) setState(() => text = "…");
    try {
      text = await transcribe(server, path);
    } catch (e) {
      text = "";
      speaking = false;
      if (mounted) setState(() {});
      _showError(e);
      return false;
    } finally {
      File(path).delete().ignore();
    }
    sttDone = true;
    if (!mounted) return false;
    setState(() {});
    return true;
  }

  /// Listens with the device's recognizer. Returns false if processing
  /// should stop.
  Future<bool> _listenDevice() async {
    setState(() {
      speaking = true;
      sttDone = false;
    });
    var textOldOld = text;
    var textOld = "";
    text = "";

    speech.listen(
        localeId: (prefs!.getString("voiceLanguage") ?? "en-US"),
        listenOptions:
            stt.SpeechListenOptions(listenMode: stt.ListenMode.dictation),
        onResult: (result) {
          lightHaptic();
          if (!speaking) return;
          setState(() {
            sttDone = result.finalResult;
            text = result.recognizedWords;
          });
        },
        pauseFor: const Duration(seconds: 3));

    DateTime start = DateTime.now();
    bool timeout = false;
    await Future.doWhile(() =>
        Future.delayed(const Duration(milliseconds: 1)).then((_) {
          if (textOld != text) {
            start = DateTime.now();
          }
          timeout =
              (DateTime.now().difference(start) >= const Duration(seconds: 3));
          textOld = text;
          return !sttDone && speaking && !timeout;
        }));
    if (!sttDone || timeout) {
      sttDone = true;
      speech.stop();
      if (timeout) {
        text = textOldOld;
        try {
          setState(() {});
        } catch (_) {}
      }
      if (!intendedStop) {
        speaking = false;
        try {
          setState(() {});
        } catch (_) {}
        return false;
      } else {
        intendedStop = false;
        try {
          setState(() {});
        } catch (_) {}
      }
    }
    return true;
  }

  void process() async {
    final server = sttServer;
    if (!await (server != null ? _listenRemote(server) : _listenDevice())) {
      return;
    }

    if (text.isEmpty) {
      setState(() {
        speaking = false;
      });
      return;
    }

    aiText = "";
    heavyHaptic();

    aiThinking = true;
    try {
      // speech servers (Whisper) already punctuate
      if (server == null && (prefs!.getBool("aiPunctuation") ?? true)) {
        final generated = await chatComplete(model: model!, messages: [
          LlmMessage("user",
              "Add punctuation and syntax to the following sentence. You must not change order of words or a word in itself! You must not add any word or phrase or remove one! Do not change between formal and personal form, keep the original one! Reply with the sentence only.\n\n$text")
        ]).timeout(Duration(
            seconds: (30.0 * (prefs!.getDouble("timeoutMultiplier") ?? 1.0))
                .round()));
        setState(() {
          if (generated.trim().isNotEmpty) text = generated.trim();
        });
      }
    } catch (_) {}

    // ignore: use_build_context_synchronously
    send(text, context, setState, onStream: (currentText, done) async {
      setState(() {
        aiText = currentText;
        lightHaptic();
        updateScrollState();
      });
      if (done) {
        aiThinking = false;
        heavyHaptic();

        if (currentText.isEmpty) {
          text = "";
          speaking = false;
          try {
            setState(() {});
          } catch (_) {}
          return;
        }

        bool finished = false;
        try {
          finished = await speakText(aiText,
              language: (prefs!.getString("voiceLanguage") ?? "en_US")
                  .replaceAll("_", "-"),
              rate: 0.6);
        } catch (e) {
          _showError(e);
        }
        speaking = false;
        try {
          setState(() {});
        } catch (_) {}
        // listen for the next question unless reading was stopped
        if (finished && mounted) process();
      }
    },
        addToSystem: (prefs!.getBool("voiceLimitLanguage") ?? true)
            ? "You must write in the following language: ${prefs!.getString("voiceLanguage") ?? "en_US"}!"
            : null);
  }

  final ScrollController scrollController = ScrollController();
  bool atScrollEnd = false;

  void updateScrollState() {
    setState(() {
      atScrollEnd = scrollController.position.extentAfter < 8.0;
    });
  }

  @override
  void initState() {
    super.initState();

    scrollController.addListener(() {
      updateScrollState();
    });

    void load() async {
      var tmp = await speech.locales();
      languageOptionIds = tmp.map((e) => e.localeId);
      languageOptions = tmp.map((e) => e.name);
      setState(() {});
    }

    load();

    void loadProcess() async {
      await Future.delayed(const Duration(milliseconds: 500));
      process();
    }

    loadProcess();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
        data: themeDark(),
        child: PopScope(
            canPop: !aiThinking,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) return;
              speaking = false;
              stopReadAloud();
              if (chatUuid != null) {
                loadChat(chatUuid!, setGlobalState!);
              }
              settingsOpen = false;
              logoVisible = true;
            },
            child: Scaffold(
                appBar: AppBar(
                    scrolledUnderElevation: 0.0,
                    leading: IconButton(
                        enableFeedback: false,
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.grey)),
                    title: Row(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Expanded(
                            child: Text(
                                (model ??
                                        AppLocalizations.of(context)!
                                            .noSelectedModel)
                                    .split(":")[0],
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.fade,
                                style: const TextStyle(
                                    fontFamily: "monospace", fontSize: 16))),
                      ],
                    ),
                    actions: [
                      IconButton(
                          enableFeedback: false,
                          onPressed: () {
                            speaking = false;
                            settingsOpen = false;
                            logoVisible = true;
                            Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                    builder: (context) =>
                                        const ScreenSettingsVoice()));
                          },
                          icon: const Icon(
                            Icons.settings_rounded,
                            color: Colors.grey,
                          ))
                    ]),
                body: SafeArea(
                  child: Column(mainAxisSize: MainAxisSize.max, children: [
                    Expanded(
                      child: Column(mainAxisSize: MainAxisSize.max, children: [
                        Expanded(
                            child: Padding(
                          padding: const EdgeInsets.only(left: 16, right: 16),
                          child: Center(
                              child: Text(text,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.fade,
                                  style: const TextStyle(
                                      color: Colors.grey,
                                      fontFamily: "monospace"))),
                        ))
                      ]),
                    ),
                    Expanded(
                        child: Center(
                            child: DateTimeLoopBuilder(
                                timeUnit: TimeUnit.seconds,
                                builder: (context, dateTime, child) {
                                  return SizedBox(
                                    height: 96,
                                    width: 96,
                                    child: AnimatedScale(
                                        scale: speaking
                                            ? aiThinking
                                                ? (dateTime.second).isEven
                                                    ? 2.4
                                                    : 2
                                                : 2
                                            : dateTime.second
                                                    .toString()
                                                    .endsWith("1")
                                                ? 1.6
                                                : 1.4,
                                        duration: aiThinking
                                            ? const Duration(seconds: 1)
                                            : const Duration(milliseconds: 200),
                                        curve: Curves.easeInOut,
                                        child: InkWell(
                                            borderRadius:
                                                BorderRadius.circular(48),
                                            onTap: () {
                                              if (speaking && !aiThinking) {
                                                // while listening: done
                                                // talking; while reading:
                                                // stop reading
                                                if (!sttDone) {
                                                  intendedStop = true;
                                                }
                                                speaking = false;
                                                stopReadAloud();
                                                return;
                                              }
                                              process();
                                            },
                                            child: CircleAvatar(
                                                backgroundColor: themeDark()
                                                    .colorScheme
                                                    .primary
                                                    .withAlpha(
                                                        !speaking ? 200 : 255),
                                                child: AnimatedSwitcher(
                                                    duration: const Duration(
                                                        milliseconds: 200),
                                                    child: speaking
                                                        ? aiThinking
                                                            ? Icon(Icons.auto_awesome_rounded,
                                                                color: themeDark()
                                                                    .colorScheme
                                                                    .secondary,
                                                                key: const ValueKey(
                                                                    "aiThinking"))
                                                            : sttDone
                                                                ? Icon(Icons.volume_up_rounded,
                                                                    color: themeDark()
                                                                        .colorScheme
                                                                        .secondary,
                                                                    key: const ValueKey(
                                                                        "tts"))
                                                                : Icon(Icons.mic_rounded,
                                                                    color: themeDark()
                                                                        .colorScheme
                                                                        .secondary,
                                                                    key: const ValueKey("stt"))
                                                        : null)))),
                                  );
                                }))),
                    Expanded(
                      child: Column(mainAxisSize: MainAxisSize.max, children: [
                        Expanded(
                            child: Stack(
                          children: [
                            ShaderMask(
                                shaderCallback: (Rect bounds) {
                                  return LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: const [
                                      Colors.transparent,
                                      Colors.black
                                    ],
                                    stops: [0.0, atScrollEnd ? 0.0 : 0.1],
                                  ).createShader(bounds);
                                },
                                blendMode: BlendMode.dstIn,
                                child: SingleChildScrollView(
                                    controller: scrollController,
                                    child: Padding(
                                        padding: const EdgeInsets.only(
                                            left: 16, right: 16),
                                        child: Center(
                                            child: Text(aiText,
                                                textAlign: TextAlign.center,
                                                overflow: TextOverflow.fade,
                                                style: const TextStyle(
                                                    fontFamily:
                                                        "monospace")))))),
                            if (!atScrollEnd)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: IconButton(
                                    icon: const Icon(
                                        Icons.arrow_downward_rounded,
                                        color: Colors.grey),
                                    onPressed: () {
                                      scrollController.animateTo(
                                          scrollController
                                              .position.maxScrollExtent,
                                          duration:
                                              const Duration(milliseconds: 500),
                                          curve: Curves.easeInOut);
                                    }),
                              )
                          ],
                        ))
                      ]),
                    )
                  ]),
                ))));
  }
}

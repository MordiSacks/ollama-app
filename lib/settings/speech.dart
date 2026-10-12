import 'dart:io';

import 'package:flutter/material.dart';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';

import '../main.dart';
import '../screen_settings.dart';
import '../worker/haptic.dart';
import '../worker/speech.dart';

/// Chooses the engine for speech recognition and text-to-speech (device or
/// one of the configured speech servers) and manages the servers.
class ScreenSettingsSpeech extends StatefulWidget {
  const ScreenSettingsSpeech({super.key});

  @override
  State<ScreenSettingsSpeech> createState() => _ScreenSettingsSpeechState();
}

class _ScreenSettingsSpeechState extends State<ScreenSettingsSpeech> {
  List<SpeechServer> servers = loadSpeechServers();

  String _engine(String key) {
    final id = prefs?.getString(key) ?? speechEngineDevice;
    return servers.any((s) => s.id == id) ? id : speechEngineDevice;
  }

  Future<void> _edit([SpeechServer? server]) async {
    selectionHaptic();
    final result = await Navigator.of(context).push<SpeechServer>(
        MaterialPageRoute(
            builder: (context) => ScreenSpeechServer(server: server)));
    if (result == null) return;
    final index = servers.indexWhere((s) => s.id == result.id);
    if (index >= 0) {
      servers[index] = result;
    } else {
      servers.add(result);
    }
    saveSpeechServers(servers);
    setState(() {});
  }

  void _delete(SpeechServer server) {
    selectionHaptic();
    servers.removeWhere((s) => s.id == server.id);
    saveSpeechServers(servers);
    for (final key in ["sttEngine", "ttsEngine"]) {
      if (prefs?.getString(key) == server.id) {
        prefs?.setString(key, speechEngineDevice);
      }
    }
    setState(() {});
  }

  Widget _engineChoice(String key, String deviceDescription) {
    final l10n = AppLocalizations.of(context)!;
    final selected = _engine(key);
    Widget option(String id, String label, String? subtitle) {
      return RadioListTile<String>(
          value: id,
          groupValue: selected,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: subtitle == null
              ? null
              : Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: "monospace")),
          onChanged: (value) {
            selectionHaptic();
            prefs?.setString(key, value ?? speechEngineDevice);
            setState(() {});
          });
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      option(speechEngineDevice, l10n.speechEngineDevice, deviceDescription),
      for (final server in servers)
        option(server.id, server.displayName, server.url),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return WindowBorder(
      color: Theme.of(context).colorScheme.surface,
      child: Scaffold(
          appBar: AppBar(title: Text(l10n.settingsTitleSpeech)),
          body: SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 16),
                child: ListView(children: [
                  title(l10n.speechSectionStt),
                  _engineChoice(
                      "sttEngine", l10n.speechEngineDeviceSttDescription),
                  title(l10n.speechSectionTts),
                  _engineChoice(
                      "ttsEngine", l10n.speechEngineDeviceTtsDescription),
                  title(l10n.speechSectionServers),
                  for (final server in servers)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.dns_rounded),
                        title: Text(server.displayName),
                        subtitle: Text(server.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: "monospace")),
                        onTap: () => _edit(server),
                        trailing: IconButton(
                            tooltip: l10n.speechServerDelete,
                            onPressed: () => _delete(server),
                            icon: const Icon(Icons.delete_rounded))),
                  const SizedBox(height: 8),
                  SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                          onPressed: () => _edit(),
                          icon: const Icon(Icons.add_rounded),
                          label: Text(l10n.speechServerAdd))),
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 16),
                    child: Text(l10n.speechServersDescription,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withAlpha(160))),
                  ),
                ])),
          )),
    );
  }
}

/// Edits one speech server; pops with the saved server.
class ScreenSpeechServer extends StatefulWidget {
  final SpeechServer? server;
  const ScreenSpeechServer({super.key, this.server});

  @override
  State<ScreenSpeechServer> createState() => _ScreenSpeechServerState();
}

class _ScreenSpeechServerState extends State<ScreenSpeechServer> {
  late final SpeechServer original = widget.server ?? SpeechServer();
  late final name = TextEditingController(text: original.name);
  late final url = TextEditingController(text: original.url);
  late final apiKey = TextEditingController(text: original.apiKey);
  late final sttModel = TextEditingController(text: original.sttModel);
  late final sttLanguage = TextEditingController(text: original.sttLanguage);
  late final ttsModel = TextEditingController(text: original.ttsModel);
  late final ttsVoice = TextEditingController(text: original.ttsVoice);
  late String ttsFormat = speechAudioFormats.contains(original.ttsFormat)
      ? original.ttsFormat
      : "mp3";

  String? urlError;
  bool testingTts = false;
  bool testingStt = false;
  bool listeningStt = false;

  @override
  void dispose() {
    for (final c in [
      name,
      url,
      apiKey,
      sttModel,
      sttLanguage,
      ttsModel,
      ttsVoice
    ]) {
      c.dispose();
    }
    listeningStt = false;
    stopPlayback();
    super.dispose();
  }

  SpeechServer? _current() {
    final uri = Uri.tryParse(url.text.trim());
    if (uri == null || !uri.isAbsolute || !uri.scheme.startsWith("http")) {
      setState(() =>
          urlError = AppLocalizations.of(context)!.settingsHostInvalid("url"));
      return null;
    }
    setState(() => urlError = null);
    return SpeechServer(
        id: original.id,
        name: name.text.trim(),
        url: url.text.trim(),
        apiKey: apiKey.text.trim(),
        sttModel: sttModel.text.trim(),
        sttLanguage: sttLanguage.text.trim(),
        ttsModel: ttsModel.text.trim(),
        ttsVoice: ttsVoice.text.trim(),
        ttsFormat: ttsFormat);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        showCloseIcon: true,
        duration: const Duration(seconds: 8)));
  }

  Future<void> _testTts() async {
    selectionHaptic();
    final server = _current();
    if (server == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => testingTts = true);
    try {
      final audio = await synthesize(server, l10n.speechServerTestSample);
      if (mounted) await playAudio(audio, server.ttsFormat);
    } catch (e) {
      _snack(e.toString());
    }
    if (mounted) setState(() => testingTts = false);
  }

  Future<void> _testStt() async {
    selectionHaptic();
    if (listeningStt) {
      // tapping again ends the recording early
      setState(() => listeningStt = false);
      return;
    }
    final server = _current();
    if (server == null) return;
    final l10n = AppLocalizations.of(context)!;
    if (!await recordingPermission()) {
      _snack(l10n.dictationPermissionDenied);
      return;
    }
    setState(() {
      testingStt = true;
      listeningStt = true;
    });
    try {
      final path = await recordUtterance(
          keepGoing: () => listeningStt && mounted,
          maxLength: const Duration(seconds: 30));
      if (mounted) setState(() => listeningStt = false);
      if (path == null) {
        _snack(l10n.speechServerTestNothing);
      } else {
        try {
          final text = await transcribe(server, path);
          _snack(text.isEmpty
              ? l10n.speechServerTestNothing
              : l10n.speechServerTestHeard(text));
        } finally {
          File(path).delete().ignore();
        }
      }
    } catch (e) {
      _snack(e.toString());
    }
    if (mounted) {
      setState(() {
        testingStt = false;
        listeningStt = false;
      });
    }
  }

  Widget _field(TextEditingController controller, String label,
      {String? hint,
      String? helper,
      String? error,
      bool obscure = false,
      TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: keyboard,
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              helperText: helper,
              helperMaxLines: 3,
              errorText: error,
              border: const OutlineInputBorder())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return WindowBorder(
      color: Theme.of(context).colorScheme.surface,
      child: Scaffold(
          appBar: AppBar(
              title: Text(widget.server == null
                  ? l10n.speechServerNew
                  : l10n.speechServerEdit),
              actions: [
                IconButton(
                    tooltip: l10n.tooltipSave,
                    onPressed: () {
                      selectionHaptic();
                      final server = _current();
                      if (server == null) return;
                      Navigator.of(context).pop(server);
                    },
                    icon: const Icon(Icons.save_rounded))
              ]),
          body: SafeArea(
            top: false,
            child: ListView(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
                children: [
                  _field(name, l10n.speechServerName, hint: "Speaches"),
                  _field(url, l10n.speechServerUrl,
                      hint: "http://192.168.1.10:8000/v1",
                      helper: l10n.speechServerUrlDescription,
                      error: urlError,
                      keyboard: TextInputType.url),
                  _field(apiKey, l10n.speechServerKey,
                      hint: "sk-...", obscure: true),
                  title(l10n.speechSectionStt),
                  _field(sttModel, l10n.speechServerSttModel,
                      hint: "Systran/faster-whisper-large-v3"),
                  _field(sttLanguage, l10n.speechServerSttLanguage,
                      hint: "he",
                      helper: l10n.speechServerSttLanguageDescription),
                  SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                          onPressed: (testingStt && !listeningStt) || testingTts
                              ? null
                              : _testStt,
                          icon: testingStt && !listeningStt
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : Icon(listeningStt
                                  ? Icons.stop_rounded
                                  : Icons.mic_rounded),
                          label: Text(listeningStt
                              ? l10n.speechServerTestListening
                              : l10n.speechServerTestStt))),
                  title(l10n.speechSectionTts),
                  _field(ttsModel, l10n.speechServerTtsModel,
                      hint: "speaches-ai/Kokoro-82M-v1.0-ONNX"),
                  _field(ttsVoice, l10n.speechServerTtsVoice, hint: "af_heart"),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownButtonFormField<String>(
                        value: ttsFormat,
                        decoration: InputDecoration(
                            labelText: l10n.speechServerTtsFormat,
                            border: const OutlineInputBorder()),
                        items: speechAudioFormats
                            .map((f) =>
                                DropdownMenuItem(value: f, child: Text(f)))
                            .toList(),
                        onChanged: (value) {
                          selectionHaptic();
                          setState(() => ttsFormat = value ?? "mp3");
                        }),
                  ),
                  SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                          onPressed: testingTts || testingStt ? null : _testTts,
                          icon: testingTts
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.volume_up_rounded),
                          label: Text(l10n.speechServerTestTts))),
                  const SizedBox(height: 24),
                ]),
          )),
    );
  }
}

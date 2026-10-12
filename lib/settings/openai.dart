import 'package:flutter/material.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';

import '../main.dart';
import '../worker/haptic.dart';
import '../worker/llm.dart';
import '../worker/setter.dart';

/// Settings field for an optional OpenAI-compatible server (vLLM, LM Studio,
/// llama.cpp server, API proxies). Its models show up in the model picker
/// next to the Ollama models.
class OpenAiEndpointField extends StatefulWidget {
  const OpenAiEndpointField({super.key});

  @override
  State<OpenAiEndpointField> createState() => _OpenAiEndpointFieldState();
}

class _OpenAiEndpointFieldState extends State<OpenAiEndpointField> {
  final controller =
      TextEditingController(text: prefs?.getString("openaiHost") ?? "");
  bool loading = false;
  String? error;
  int? modelCount;

  @override
  void initState() {
    super.initState();
    if (controller.text.trim().isNotEmpty) check(save: false);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> check({bool save = true}) async {
    final value = controller.text.trim();
    if (value.isEmpty) {
      prefs?.remove("openaiHost");
      setState(() {
        error = null;
        modelCount = null;
      });
      return;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isAbsolute) {
      setState(() {
        error = AppLocalizations.of(context)!.settingsHostInvalid("url");
        modelCount = null;
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final models =
          await listOpenAiModels(baseUrl: normalizeOpenAiBaseUrl(value));
      if (save) prefs?.setString("openaiHost", value);
      if (!mounted) return;
      setState(() {
        loading = false;
        modelCount = models.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        modelCount = null;
        error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final green =
        Colors.green.harmonizeWith(Theme.of(context).colorScheme.primary);
    return TextField(
        controller: controller,
        keyboardType: TextInputType.url,
        autocorrect: false,
        onSubmitted: (_) {
          selectionHaptic();
          check();
        },
        decoration: InputDecoration(
            labelText: l10n.settingsOpenAiHost,
            hintText: "http://192.168.1.10:8000/v1",
            border: const OutlineInputBorder(),
            prefixIcon: IconButton(
                enableFeedback: false,
                tooltip: l10n.settingsOpenAiKeyTitle,
                onPressed: () async {
                  selectionHaptic();
                  final key = await prompt(context,
                      title: l10n.settingsOpenAiKeyTitle,
                      description: l10n.settingsOpenAiKeyDescription,
                      value: prefs?.getString("openaiKey") ?? "",
                      placeholder: "sk-...",
                      autocorrect: false,
                      enableSuggestions: false);
                  prefs?.setString("openaiKey", key.trim());
                  check(save: false);
                },
                icon: const Icon(Icons.key_rounded)),
            suffixIcon: loading
                ? Transform.scale(
                    scale: 0.5, child: const CircularProgressIndicator())
                : IconButton(
                    enableFeedback: false,
                    tooltip: l10n.tooltipSave,
                    onPressed: () {
                      selectionHaptic();
                      check();
                    },
                    icon: const Icon(Icons.save_rounded)),
            errorText: error,
            errorMaxLines: 3,
            helperMaxLines: 2,
            helperText: modelCount != null
                ? l10n.settingsOpenAiConnected(modelCount.toString())
                : l10n.settingsOpenAiHostDescription,
            helperStyle: modelCount != null
                ? TextStyle(color: green, fontFamily: "monospace")
                : null));
  }
}

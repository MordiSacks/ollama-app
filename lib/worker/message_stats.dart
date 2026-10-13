// Statistics of an answer: model, tokens, speed and timings.
//
// send() stores them in the message metadata under "usage". Token counts
// and server timings come from the server (Ollama always reports them,
// OpenAI-compatible servers when they support stream_options.include_usage);
// time to first token and total time are measured by the app. Without
// server timings the speed is estimated from the app's own clock, which
// includes network time.

import 'package:flutter/material.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'llm.dart';

Map<String, dynamic>? messageUsage(types.Message message) {
  final usage = message.metadata?["usage"];
  return usage is Map ? Map<String, dynamic>.from(usage) : null;
}

int? _int(Map usage, String key) {
  final value = usage[key];
  return value is num ? value.toInt() : int.tryParse(value?.toString() ?? "");
}

String _duration(int ms) => ms < 1000
    ? "$ms ms"
    : "${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)} s";

String _rate(double perSecond) =>
    "${perSecond.toStringAsFixed(perSecond < 10 ? 2 : 1)} tok/s";

/// Output speed in tokens per second and whether the server measured it.
({double perSecond, bool measured})? usageSpeed(Map usage) {
  final tokens = _int(usage, "tokens");
  if (tokens == null || tokens <= 0) return null;
  final genMs = _int(usage, "genMs");
  if (genMs != null && genMs > 0) {
    return (perSecond: tokens * 1000 / genMs, measured: true);
  }
  final total = _int(usage, "totalMs");
  final first = _int(usage, "firstTokenMs");
  if (total == null || first == null || total - first <= 0) return null;
  return (perSecond: tokens * 1000 / (total - first), measured: false);
}

void showMessageStats(BuildContext context, types.Message message) {
  final usage = messageUsage(message);
  if (usage == null) return;
  final l10n = AppLocalizations.of(context)!;

  final tokens = _int(usage, "tokens");
  final reasoning = _int(usage, "reasoningTokens");
  final promptTokens = _int(usage, "promptTokens");
  final cached = _int(usage, "cachedTokens");
  final promptMs = _int(usage, "promptMs");
  final speed = usageSpeed(usage);
  final provider = usage["provider"]?.toString();
  final doneReason = usage["doneReason"]?.toString();

  final rows = <(String, String)>[
    if (usage["model"] != null)
      (
        l10n.statsModel,
        provider == providerOpenAi
            ? "${usage["model"]} (OpenAI)"
            : usage["model"].toString()
      ),
    if (speed != null)
      (
        l10n.statsSpeed,
        "${speed.measured ? "" : "~"}${_rate(speed.perSecond)}"
      ),
    if (tokens != null)
      (
        l10n.statsOutputTokens,
        reasoning != null
            ? "$tokens (${l10n.statsReasoningTokens(reasoning)})"
            : "$tokens"
      ),
    if (promptTokens != null)
      (
        l10n.statsPromptTokens,
        cached != null
            ? "$promptTokens (${l10n.statsCachedTokens(cached)})"
            : "$promptTokens"
      ),
    if (promptTokens != null && promptMs != null && promptMs > 0)
      (l10n.statsPromptSpeed, _rate(promptTokens * 1000 / promptMs)),
    if (_int(usage, "firstTokenMs") != null)
      (l10n.statsFirstToken, _duration(_int(usage, "firstTokenMs")!)),
    if (_int(usage, "genMs") != null)
      (l10n.statsGenerationTime, _duration(_int(usage, "genMs")!)),
    if ((_int(usage, "loadMs") ?? 0) >= 100)
      (l10n.statsLoadTime, _duration(_int(usage, "loadMs")!)),
    if (_int(usage, "totalMs") != null)
      (l10n.statsTotalTime, _duration(_int(usage, "totalMs")!)),
  ];

  final notes = <String>[
    if (usage["stopped"] == true)
      l10n.statsStopped
    else if (doneReason == "length")
      l10n.statsTruncated,
    if (speed != null && !speed.measured) l10n.statsEstimated,
    if (tokens == null) l10n.statsNoTokens,
  ];

  showModalBottomSheet(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurface.withAlpha(160);
        return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.statsTitle, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    for (final (label, value) in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  child: Text(label,
                                      style: TextStyle(color: muted))),
                              const SizedBox(width: 16),
                              Flexible(
                                  child: Text(value,
                                      textAlign: TextAlign.end,
                                      style: const TextStyle(
                                          fontFamily: "monospace"))),
                            ]),
                      ),
                    for (final note in notes)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(note,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: muted))),
                  ]),
            ));
      });
}

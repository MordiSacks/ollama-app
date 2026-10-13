// Reasoning ("thinking") of models like DeepSeek-R1, Qwen3 or gpt-oss.
//
// Servers deliver it either in a separate field (Ollama's "thinking",
// OpenAI-style "reasoning_content") or inline in the answer wrapped in
// <think>...</think>. Both end up in the message metadata and are shown as a
// collapsible block above the answer; it is never sent back to the model.

import 'package:flutter/material.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'haptic.dart';

final RegExp _openTag = RegExp(r"<(think|thinking)>", caseSensitive: false);

/// Splits inline reasoning off [text]. Handles a reasoning block that is
/// still open (streaming) and a lone closing tag (some servers drop the
/// opening one because it was part of the prompt template).
({String thinking, String answer}) splitThinking(String text) {
  final trimmed = text.trimLeft();
  final open = _openTag.matchAsPrefix(trimmed);
  if (open != null) {
    final closeTag = "</${open.group(1)!.toLowerCase()}>";
    final close = trimmed.toLowerCase().indexOf(closeTag, open.end);
    if (close == -1) {
      return (thinking: trimmed.substring(open.end).trim(), answer: "");
    }
    return (
      thinking: trimmed.substring(open.end, close).trim(),
      answer: trimmed.substring(close + closeTag.length).trimLeft()
    );
  }
  final lone = text.toLowerCase().indexOf("</think>");
  if (lone != -1 && !text.substring(0, lone).contains("<")) {
    return (
      thinking: text.substring(0, lone).trim(),
      answer: text.substring(lone + "</think>".length).trimLeft()
    );
  }
  return (thinking: "", answer: text);
}

String messageThinking(types.Message message) =>
    message.metadata?["thinking"]?.toString() ?? "";

int? messageThinkingMs(types.Message message) {
  final value = message.metadata?["thinkingMs"];
  return value is int ? value : int.tryParse(value?.toString() ?? "");
}

Map<String, dynamic>? thinkingMetadata(String thinking, int? thinkingMs) {
  if (thinking.trim().isEmpty) return null;
  return {"thinking": thinking, if (thinkingMs != null) "thinkingMs": thinkingMs};
}

/// Ids of messages whose reasoning is currently expanded.
final Set<String> _expanded = {};

class ThinkingBlock extends StatefulWidget {
  final String messageId;
  final String thinking;
  final int? thinkingMs;
  final bool active; // still reasoning

  const ThinkingBlock(
      {super.key,
      required this.messageId,
      required this.thinking,
      required this.thinkingMs,
      required this.active});

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurface.withAlpha(150);
    final expanded = _expanded.contains(widget.messageId);

    String label;
    if (widget.active) {
      label = l10n.thinkingActive;
    } else if (widget.thinkingMs != null) {
      final seconds = (widget.thinkingMs! / 1000).round();
      label = seconds < 1
          ? l10n.thinkingDoneBrief
          : l10n.thinkingDoneSeconds(seconds);
    } else {
      label = l10n.thinkingDone;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              selectionHaptic();
              setState(() {
                if (!_expanded.remove(widget.messageId)) {
                  _expanded.add(widget.messageId);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                widget.active
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: muted))
                    : Icon(Icons.psychology_alt_rounded,
                        size: 16, color: muted),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        color: muted,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: muted),
              ]),
            ),
          ),
          if (expanded)
            Container(
              margin: const EdgeInsets.only(top: 4, left: 6),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                  border: Border(
                      left: BorderSide(
                          color: colors.onSurface.withAlpha(50), width: 2))),
              child: MarkdownBody(
                  data: widget.thinking,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                          p: TextStyle(
                              color: muted, fontSize: 14, height: 1.4),
                          listBullet: TextStyle(color: muted, fontSize: 14))),
            ),
        ],
      ),
    );
  }
}

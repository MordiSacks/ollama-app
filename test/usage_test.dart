import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/worker/llm.dart';
import 'package:ollama_app/worker/message_stats.dart';

void main() {
  test("reads Ollama's final chunk", () {
    final usage = ollamaUsage(jsonDecode(
        '{"done":true,"done_reason":"stop","total_duration":4053463204,'
        '"load_duration":3973605278,"prompt_eval_count":15,'
        '"prompt_eval_cached_count":0,"prompt_eval_duration":60667000,'
        '"eval_count":4,"eval_duration":18036000}'))!;
    expect(usage, {
      "promptTokens": 15,
      "tokens": 4,
      "promptMs": 61,
      "genMs": 18,
      "loadMs": 3974,
      "serverMs": 4053,
      "doneReason": "stop"
    });
    expect(usageSpeed(usage)!.measured, isTrue);
    expect(usageSpeed(usage)!.perSecond, closeTo(222.2, 0.1));
  });

  test("reads OpenAI usage with llama.cpp timings", () {
    final usage = openAiUsage(jsonDecode(
        '{"choices":[],"usage":{"prompt_tokens":15,'
        '"prompt_tokens_details":{"cached_tokens":10},"completion_tokens":6,'
        '"total_tokens":21},"timings":{"prompt_n":15,"prompt_ms":10,'
        '"predicted_n":6,"predicted_ms":20}}'))!;
    expect(usage, {
      "promptTokens": 15,
      "cachedTokens": 10,
      "tokens": 6,
      "promptMs": 10,
      "genMs": 20
    });
  });

  test("plain OpenAI usage falls back to the app's clock", () {
    final usage = {
      ...openAiUsage(jsonDecode('{"usage":{"prompt_tokens":20,'
          '"completion_tokens":100,"completion_tokens_details":'
          '{"reasoning_tokens":40}}}'))!,
      "firstTokenMs": 500,
      "totalMs": 2500
    };
    expect(usage["reasoningTokens"], 40);
    final speed = usageSpeed(usage)!;
    expect(speed.measured, isFalse);
    expect(speed.perSecond, 50);
  });

  test("chunks without usage report nothing", () {
    expect(openAiUsage({"choices": []}), isNull);
    expect(ollamaUsage({"done": true}), isNull);
  });
}

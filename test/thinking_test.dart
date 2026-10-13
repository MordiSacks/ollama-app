import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/worker/thinking.dart';

void main() {
  test("plain answer is untouched", () {
    final r = splitThinking("Hello <b>there</b>");
    expect(r.thinking, "");
    expect(r.answer, "Hello <b>there</b>");
  });

  test("closed think block", () {
    final r = splitThinking("<think>\nLet me see.\n</think>\n\nThe answer.");
    expect(r.thinking, "Let me see.");
    expect(r.answer, "The answer.");
  });

  test("open think block while streaming", () {
    final r = splitThinking("  <think>Still going");
    expect(r.thinking, "Still going");
    expect(r.answer, "");
  });

  test("<thinking> variant and case", () {
    final r = splitThinking("<Thinking>hmm</THINKING>ok");
    expect(r.thinking, "hmm");
    expect(r.answer, "ok");
  });

  test("lone closing tag", () {
    final r = splitThinking("reasoning here</think>\n\nanswer");
    expect(r.thinking, "reasoning here");
    expect(r.answer, "answer");
  });

  test("think tag mentioned mid-answer is left alone", () {
    const text = "Use <code>x</code> then </think> appears";
    final r = splitThinking(text);
    expect(r.thinking, "");
    expect(r.answer, text);
  });
}

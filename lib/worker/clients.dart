import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;

import 'servers.dart';

class OllamaHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (_, __, ___) => true;
  }
}

final httpClient = http.Client();

/// Client for the native API of the Ollama [server].
llama.OllamaClient ollamaClientFor(LlmServer server) => llama.OllamaClient(
    headers: server.authHeaders,
    baseUrl: "${server.baseUrl}/api",
    client: httpClient);

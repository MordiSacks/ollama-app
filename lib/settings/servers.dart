import 'package:flutter/material.dart';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:ollama_app/l10n/gen/app_localizations.dart';

import '../main.dart';
import '../screen_settings.dart';
import '../worker/haptic.dart';
import '../worker/llm.dart';
import '../worker/servers.dart';

class _Status {
  bool loading = true;
  int? models;
  String? error;
}

/// The configured LLM servers with their connection state, shown at the top
/// of the settings. Tapping one edits it; the button below adds one.
class ServerList extends StatefulWidget {
  const ServerList({super.key});

  @override
  State<ServerList> createState() => _ServerListState();
}

class _ServerListState extends State<ServerList> {
  List<LlmServer> servers = List.of(llmServers);
  final Map<String, _Status> status = {};

  @override
  void initState() {
    super.initState();
    for (final server in servers) {
      _check(server);
    }
  }

  Future<void> _check(LlmServer server) async {
    final state = status[server.id] = _Status();
    if (mounted) setState(() {});
    try {
      state.models = await checkServer(server);
    } catch (e) {
      state.error = e.toString();
    }
    state.loading = false;
    if (mounted) setState(() {});
  }

  Future<void> _edit([LlmServer? server]) async {
    selectionHaptic();
    final result = await Navigator.of(context).push<_EditResult>(
        MaterialPageRoute(builder: (context) => ScreenLlmServer(server: server)));
    if (result == null) return;
    if (result.deleted) {
      servers.removeWhere((s) => s.id == result.server.id);
      status.remove(result.server.id);
    } else {
      final index = servers.indexWhere((s) => s.id == result.server.id);
      if (index >= 0) {
        servers[index] = result.server;
      } else {
        servers.add(result.server);
      }
      _check(result.server);
    }
    saveLlmServers(servers);
    setState(() {});
    setGlobalState?.call(() {});
  }

  Widget _statusLine(LlmServer server) {
    final l10n = AppLocalizations.of(context)!;
    final state = status[server.id];
    final theme = Theme.of(context);
    if (state == null || state.loading) {
      return Text(l10n.settingsHostChecking,
          style: const TextStyle(color: Colors.grey, fontFamily: "monospace"));
    }
    if (state.error != null) {
      return Text(state.error!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.colorScheme.error));
    }
    return Text(l10n.settingsOpenAiConnected(state.models.toString()),
        style: TextStyle(
            color: Colors.green.harmonizeWith(theme.colorScheme.primary),
            fontFamily: "monospace"));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title(l10n.settingsServers, top: 0, bottom: 8),
          for (final server in servers)
            Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                shape: RoundedRectangleBorder(
                    side: BorderSide(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                    onTap: useHost ? null : () => _edit(server),
                    leading: Icon(server.isOllama
                        ? Icons.memory_rounded
                        : Icons.dns_rounded),
                    title: Row(children: [
                      Flexible(
                          child: Text(server.displayName,
                              overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Text(
                          server.isOllama
                              ? l10n.serverTypeOllama
                              : l10n.serverTypeOpenAiShort,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withAlpha(140))),
                    ]),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(server.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontFamily: "monospace")),
                          _statusLine(server),
                        ]),
                    trailing: IconButton(
                        tooltip: l10n.serverRecheck,
                        onPressed: (status[server.id]?.loading ?? false)
                            ? null
                            : () {
                                selectionHaptic();
                                _check(server);
                              },
                        icon: const Icon(Icons.refresh_rounded)))),
          if (servers.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
              child: Text(l10n.settingsServersEmpty,
                  style: TextStyle(
                      color: theme.colorScheme.onSurface.withAlpha(160))),
            ),
          if (!useHost)
            OutlinedButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_rounded),
                label: Text(l10n.serverAdd)),
        ]);
  }
}

class _EditResult {
  final LlmServer server;
  final bool deleted;
  const _EditResult(this.server, {this.deleted = false});
}

class _HeaderRow {
  final TextEditingController name;
  final TextEditingController value;
  _HeaderRow(String name, String value)
      : name = TextEditingController(text: name),
        value = TextEditingController(text: value);
  void dispose() {
    name.dispose();
    value.dispose();
  }
}

/// Adds or edits one LLM server.
class ScreenLlmServer extends StatefulWidget {
  final LlmServer? server;
  const ScreenLlmServer({super.key, this.server});

  @override
  State<ScreenLlmServer> createState() => _ScreenLlmServerState();
}

class _ScreenLlmServerState extends State<ScreenLlmServer> {
  late final LlmServer original = widget.server ?? LlmServer();
  late final name = TextEditingController(text: original.name);
  late final url = TextEditingController(text: original.url);
  late final apiKey = TextEditingController(text: original.apiKey);
  late String type = original.type;
  late final List<_HeaderRow> headers = original.headers.entries
      .map((e) => _HeaderRow(e.key, e.value))
      .toList();
  final List<_HeaderRow> removedHeaders = [];

  String? urlError;
  bool testing = false;
  String? testResult;
  bool testFailed = false;

  @override
  void dispose() {
    for (final c in [name, url, apiKey]) {
      c.dispose();
    }
    for (final row in [...headers, ...removedHeaders]) {
      row.dispose();
    }
    super.dispose();
  }

  LlmServer? _current() {
    final l10n = AppLocalizations.of(context)!;
    final uri = Uri.tryParse(url.text.trim());
    if (uri == null || !uri.isAbsolute || !uri.scheme.startsWith("http")) {
      setState(() => urlError = l10n.settingsHostInvalid("url"));
      return null;
    }
    setState(() => urlError = null);
    return LlmServer(
        id: original.id,
        name: name.text.trim(),
        type: type,
        url: url.text.trim(),
        apiKey: apiKey.text.trim(),
        headers: {
          for (final row in headers)
            if (row.name.text.trim().isNotEmpty)
              row.name.text.trim(): row.value.text.trim()
        });
  }

  Future<void> _test() async {
    selectionHaptic();
    final server = _current();
    if (server == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      testing = true;
      testResult = null;
    });
    try {
      final count = await checkServer(server);
      testFailed = false;
      testResult = l10n.settingsOpenAiConnected("$count");
    } catch (e) {
      testFailed = true;
      testResult = e is LlmException ? e.message : e.toString();
    }
    if (mounted) setState(() => testing = false);
  }

  Future<void> _delete() async {
    selectionHaptic();
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(l10n.serverDeleteTitle(original.displayName)),
                content: Text(l10n.serverDeleteDescription),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(l10n.deleteDialogCancel)),
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(l10n.deleteDialogDelete)),
                ]));
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(_EditResult(original, deleted: true));
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
    final theme = Theme.of(context);
    final ollama = type == serverTypeOllama;
    return WindowBorder(
      color: theme.colorScheme.surface,
      child: Scaffold(
          appBar: AppBar(
              title: Text(
                  widget.server == null ? l10n.serverNew : l10n.serverEdit),
              actions: [
                if (widget.server != null)
                  IconButton(
                      tooltip: l10n.serverDelete,
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_rounded)),
                IconButton(
                    tooltip: l10n.tooltipSave,
                    onPressed: () {
                      selectionHaptic();
                      final server = _current();
                      if (server == null) return;
                      Navigator.of(context).pop(_EditResult(server));
                    },
                    icon: const Icon(Icons.save_rounded))
              ]),
          body: SafeArea(
            top: false,
            child: ListView(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
                children: [
                  _field(name, l10n.serverName,
                      hint: ollama ? "Home PC" : "vLLM rig",
                      helper: l10n.serverNameDescription),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: SegmentedButton<String>(
                        segments: [
                          ButtonSegment(
                              value: serverTypeOllama,
                              icon: const Icon(Icons.memory_rounded),
                              label: Text(l10n.serverTypeOllama)),
                          ButtonSegment(
                              value: serverTypeOpenAi,
                              icon: const Icon(Icons.dns_rounded),
                              label: Text(l10n.serverTypeOpenAi)),
                        ],
                        selected: {type},
                        onSelectionChanged: (value) {
                          selectionHaptic();
                          setState(() {
                            type = value.first;
                            testResult = null;
                          });
                        }),
                  ),
                  _field(url, l10n.serverUrl,
                      hint: ollama
                          ? "http://localhost:11434"
                          : "http://192.168.1.10:8000/v1",
                      helper: ollama ? null : l10n.settingsOpenAiHostDescription,
                      error: urlError,
                      keyboard: TextInputType.url),
                  _field(apiKey, l10n.settingsOpenAiKeyTitle,
                      hint: "sk-...",
                      helper: l10n.serverKeyDescription,
                      obscure: true),
                  title(l10n.serverHeaders, top: 4, bottom: 8),
                  for (final row in headers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Expanded(
                            flex: 2,
                            child: TextField(
                                controller: row.name,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: InputDecoration(
                                    labelText: l10n.serverHeaderName,
                                    hintText: "X-Api-Key",
                                    isDense: true,
                                    border: const OutlineInputBorder()))),
                        const SizedBox(width: 8),
                        Expanded(
                            flex: 3,
                            child: TextField(
                                controller: row.value,
                                autocorrect: false,
                                enableSuggestions: false,
                                decoration: InputDecoration(
                                    labelText: l10n.serverHeaderValue,
                                    isDense: true,
                                    border: const OutlineInputBorder()))),
                        IconButton(
                            tooltip: l10n.serverHeaderRemove,
                            onPressed: () {
                              selectionHaptic();
                              setState(() {
                                headers.remove(row);
                                removedHeaders.add(row);
                              });
                            },
                            icon: const Icon(Icons.remove_circle_outline)),
                      ]),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        onPressed: () {
                          selectionHaptic();
                          setState(() => headers.add(_HeaderRow("", "")));
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: Text(l10n.serverHeaderAdd)),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                          onPressed: testing ? null : _test,
                          icon: testing
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.wifi_tethering_rounded),
                          label: Text(l10n.serverTest))),
                  if (testResult != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(testResult!,
                          style: TextStyle(
                              fontFamily: "monospace",
                              color: testFailed
                                  ? theme.colorScheme.error
                                  : Colors.green
                                      .harmonizeWith(theme.colorScheme.primary))),
                    ),
                  const SizedBox(height: 24),
                ]),
          )),
    );
  }
}

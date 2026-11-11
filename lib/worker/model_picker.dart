// Model picker: the models of all configured servers in one searchable list,
// grouped by server, with a filter per server.

import 'package:flutter/material.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import '../main.dart';
import 'desktop.dart';
import 'haptic.dart';
import 'llm.dart';
import 'servers.dart';

class _ServerResult {
  final LlmServer server;
  List<ServerModel> models = [];
  String? error;
  bool loading = true;
  _ServerResult(this.server);
}

/// Shows the picker. [onSelected] gets the chosen model; [onPull] is called
/// with an Ollama server to download a new model onto.
void showModelPicker(BuildContext context,
    {required void Function(ServerModel model) onSelected,
    required void Function(LlmServer server) onPull,
    void Function()? onClosed}) {
  final picker = ModelPicker(onSelected: onSelected, onPull: onPull);
  final Future<void> closed;
  if (desktopLayoutNotRequired(context)) {
    closed = showDialog(
        context: context,
        builder: (context) => Transform.translate(
              offset: desktopLayoutRequired(context)
                  ? const Offset(289, 0)
                  : const Offset(0, 0),
              child: Dialog(
                  alignment: desktopLayoutRequired(context)
                      ? Alignment.topLeft
                      : Alignment.topCenter,
                  child: SizedBox(width: 440, height: 560, child: picker)),
            ));
  } else {
    closed = showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => SizedBox(
            height: MediaQuery.of(context).size.height * 0.8,
            child: SafeArea(top: false, child: picker)));
  }
  closed.then((_) => onClosed?.call());
}

class ModelPicker extends StatefulWidget {
  final void Function(ServerModel model) onSelected;
  final void Function(LlmServer server) onPull;

  const ModelPicker(
      {super.key, required this.onSelected, required this.onPull});

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  final search = TextEditingController();
  late final List<_ServerResult> results =
      llmServers.map(_ServerResult.new).toList();

  /// Id of the server the list is limited to; null shows all.
  String? filter;

  @override
  void initState() {
    super.initState();
    for (final result in results) {
      _load(result);
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _load(_ServerResult result) async {
    try {
      final models = await listServerModels(result.server);
      models.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      result.models = models;
      result.error = null;
    } catch (e) {
      result.models = [];
      result.error = e.toString();
    }
    result.loading = false;
    if (mounted) setState(() {});
  }

  bool get _multipleServers => results.length > 1;

  /// Whether the tag is needed to tell [m] apart, or the user wants tags.
  bool _showTag(ServerModel m) {
    if (m.tag.isEmpty) return false;
    if (prefs?.getBool("modelTags") ?? false) return true;
    return m.server.isOllama &&
        results
                .firstWhere((r) => r.server.id == m.server.id)
                .models
                .where((other) => other.baseName == m.baseName)
                .length >
            1;
  }

  bool _isSelected(ServerModel m) =>
      m.name == model && m.server.id == modelServer?.id;

  void _pull() {
    selectionHaptic();
    final ollama = results.map((r) => r.server).where((s) => s.isOllama);
    LlmServer? target = filter == null ? null : serverById(filter);
    if (target == null || !target.isOllama) {
      target = ollama.length == 1 ? ollama.first : null;
    }
    if (target != null) {
      Navigator.of(context).pop();
      widget.onPull(target);
      return;
    }
    showDialog(
        context: context,
        builder: (dialogContext) => SimpleDialog(
                title: Text(
                    AppLocalizations.of(context)!.modelPickerPullTarget),
                children: [
                  for (final server in ollama)
                    SimpleDialogOption(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          Navigator.of(context).pop();
                          widget.onPull(server);
                        },
                        child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(server.displayName),
                            subtitle: Text(server.url,
                                style:
                                    const TextStyle(fontFamily: "monospace"))))
                ]));
  }

  Widget _filterChips() {
    final l10n = AppLocalizations.of(context)!;
    Widget chip(String? id, String label, {int? count, bool error = false}) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
            label: Text(count == null ? label : "$label · $count"),
            avatar: error
                ? Icon(Icons.error_outline_rounded,
                    color: Theme.of(context).colorScheme.error)
                : null,
            showCheckmark: false,
            selected: filter == id,
            onSelected: (_) {
              selectionHaptic();
              setState(() => filter = id);
            }),
      );
    }

    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        chip(null, l10n.modelPickerAllServers),
        for (final result in results)
          chip(result.server.id, result.server.displayName,
              count: result.loading || result.error != null
                  ? null
                  : result.models.length,
              error: result.error != null),
      ]),
    );
  }

  Widget _serverHeader(_ServerResult result) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 16, bottom: 4),
      child: Row(children: [
        Icon(result.server.isOllama ? Icons.memory_rounded : Icons.dns_rounded,
            size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
            child: Text(result.server.displayName,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.primary))),
        if (result.loading)
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
    );
  }

  Widget _modelTile(ServerModel m) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final selected = _isSelected(m);
    final muted = theme.colorScheme.onSurface.withAlpha(140);
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.primary.withAlpha(30),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.only(left: 12, right: 8),
      leading: Icon(selected
          ? Icons.check_circle_rounded
          : recommendedModels.contains(m.baseName)
              ? Icons.star_rounded
              : Icons.smart_toy_outlined),
      title: Text.rich(TextSpan(children: [
        TextSpan(text: m.server.isOllama ? m.baseName : m.name),
        if (m.server.isOllama && _showTag(m))
          TextSpan(text: ":${m.tag}", style: TextStyle(color: muted)),
      ])),
      subtitle: _multipleServers && filter == null && search.text.isNotEmpty
          ? Text(m.server.displayName, style: TextStyle(color: muted))
          : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (m.server.isOllama && m.vision)
          Tooltip(
              message: l10n.modelPickerVision,
              child: Icon(Icons.image_outlined, size: 18, color: muted)),
        if (m.thinking)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Tooltip(
                message: l10n.modelPickerThinking,
                child: Icon(Icons.psychology_outlined, size: 18, color: muted)),
          ),
      ]),
      onTap: (!chatAllowed && model != null)
          ? null
          : () {
              selectionHaptic();
              Navigator.of(context).pop();
              widget.onSelected(m);
            },
    );
  }

  Widget _message(String text, {bool error = false, VoidCallback? retry}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(
            child: Text(text,
                style: TextStyle(
                    color: error
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurface.withAlpha(140)))),
        if (retry != null)
          IconButton(
              tooltip: AppLocalizations.of(context)!.modelPickerRetry,
              onPressed: retry,
              icon: const Icon(Icons.refresh_rounded)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = search.text.trim();
    final shown = results.where((r) => filter == null || r.server.id == filter);
    final grouped = _multipleServers && filter == null && query.isEmpty;

    final children = <Widget>[];
    if (grouped) {
      for (final result in shown) {
        children.add(_serverHeader(result));
        if (result.error != null) {
          children.add(_message(result.error!, error: true, retry: () {
            setState(() => result.loading = true);
            _load(result);
          }));
        } else if (!result.loading && result.models.isEmpty) {
          children.add(_message(l10n.modelPickerNoModels));
        }
        children.addAll(result.models.map(_modelTile));
      }
    } else {
      for (final result in shown) {
        if (result.error != null && query.isEmpty) {
          children.add(_message(result.error!, error: true, retry: () {
            setState(() => result.loading = true);
            _load(result);
          }));
        }
      }
      final models = shown
          .expand((r) => r.models)
          .where((m) => query.isEmpty || m.matches(query))
          .toList();
      children.addAll(models.map(_modelTile));
      final loading = shown.any((r) => r.loading);
      if (loading) {
        children.add(const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator())));
      } else if (models.isEmpty) {
        children.add(_message(query.isEmpty
            ? l10n.modelPickerNoModels
            : l10n.modelPickerNoMatch(query)));
      }
    }

    final canPull = results.any((r) => r.server.isOllama) &&
        (filter == null || (serverById(filter)?.isOllama ?? false));

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 8),
      child: Column(children: [
        TextField(
            controller: search,
            autofocus: desktopFeature(),
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              // Enter picks the only match
              final matches = results
                  .where((r) => filter == null || r.server.id == filter)
                  .expand((r) => r.models)
                  .where((m) => m.matches(search.text.trim()))
                  .toList();
              if (matches.length == 1 && (chatAllowed || model == null)) {
                Navigator.of(context).pop();
                widget.onSelected(matches.first);
              }
            },
            decoration: InputDecoration(
                hintText: l10n.modelPickerSearch,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.modelPickerClearSearch,
                        onPressed: () {
                          search.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded)),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(28)),
                isDense: true)),
        if (_multipleServers)
          Padding(
              padding: const EdgeInsets.only(top: 8), child: _filterChips()),
        const SizedBox(height: 4),
        Expanded(
            child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: children)),
        if (canPull)
          Padding(
            padding: const EdgeInsets.only(bottom: 12, top: 4),
            child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                    onPressed: _pull,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(l10n.modelPickerPull))),
          ),
      ]),
    );
  }
}

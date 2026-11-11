import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'main.dart';
import 'worker/haptic.dart';
import 'worker/update.dart';
import 'worker/desktop.dart';
import 'worker/setter.dart';

import 'package:ollama_app/l10n/gen/app_localizations.dart';

import 'settings/behavior.dart';
import 'settings/servers.dart';
import 'settings/speech.dart';
import 'settings/interface.dart';
import 'settings/voice.dart';
import 'settings/export.dart';
import 'settings/about.dart';

import 'package:dartx/dartx.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:version/version.dart';

Widget toggle(BuildContext context, String text, bool value,
    Function(bool value) onChanged,
    {bool disabled = false,
    void Function()? onDisabledTap,
    void Function()? onLongTap,
    void Function()? onDoubleTap,
    Widget? icon,
    bool? iconAfterwards}) {
  return InkWell(
    enableFeedback: false,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    onTap: () {
      if (disabled) {
        selectionHaptic();
        if (onDisabledTap != null) {
          onDisabledTap();
        }
      } else {
        onChanged(!value);
      }
    },
    onLongPress: onLongTap,
    onDoubleTap: onDoubleTap,
    child: Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(children: [
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            return Row(mainAxisSize: MainAxisSize.max, children: [
              (icon != null && !(iconAfterwards ?? false))
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: icon,
                    )
                  : const SizedBox.shrink(),
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth - (icon != null ? 32 : 0)),
                child: Text(text,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(color: disabled ? Colors.grey : null)),
              ),
              (icon != null && (iconAfterwards ?? false))
                  ? Transform.translate(
                      offset: const Offset(0, 1),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: icon,
                      ))
                  : const SizedBox.shrink(),
              Expanded(
                child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Divider(color: Theme.of(context).dividerColor)),
              ),
            ]);
          }),
        ),
        Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Switch(
                value: value,
                onChanged: disabled
                    ? (onDisabledTap != null)
                        ? (p0) {
                            selectionHaptic();
                            onDisabledTap();
                          }
                        : null
                    : onChanged,
                activeTrackColor: disabled
                    ? Theme.of(context).colorScheme.primary.withAlpha(50)
                    : null,
                trackOutlineColor: disabled
                    ? WidgetStatePropertyAll(
                        Theme.of(context).colorScheme.primary.withAlpha(150))
                    : null,
                thumbColor: disabled
                    ? WidgetStatePropertyAll(
                        Theme.of(context).colorScheme.primary.withAlpha(150))
                    : !(prefs?.getBool("useDeviceTheme") ?? false) && value
                        ? WidgetStatePropertyAll(
                            Theme.of(context).colorScheme.secondary)
                        : null))
      ]),
    ),
  );
}

Widget title(String text, {double top = 16, double bottom = 16}) {
  return Padding(
      padding: EdgeInsets.only(left: 8, right: 8, top: top, bottom: bottom),
      child: Row(children: [
        const Expanded(child: Divider()),
        Padding(
            padding: const EdgeInsets.only(left: 24, right: 24),
            child: Text(text)),
        const Expanded(child: Divider())
      ]));
}

Widget titleDivider({double? top, double? bottom, BuildContext? context}) {
  top ??= (context != null && desktopLayoutNotRequired(context)) ? 32 : 16;
  bottom ??= (context != null && desktopLayoutNotRequired(context)) ? 32 : 16;
  return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(left: 8, right: 8, top: top, bottom: bottom),
      child: const Row(
          mainAxisSize: MainAxisSize.max,
          children: [Expanded(child: Divider())]));
}

Widget verticalTitleDivider(
    {double? left, double? right, BuildContext? context}) {
  left ??= (context != null && desktopLayoutNotRequired(context)) ? 32 : 16;
  right ??= (context != null && desktopLayoutNotRequired(context)) ? 32 : 16;
  return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: EdgeInsets.only(left: left, right: right, top: 8, bottom: 8),
      child: const Row(
          mainAxisSize: MainAxisSize.max,
          children: [VerticalDivider(width: 1)]));
}

Widget button(String text, IconData? icon, void Function()? onPressed,
    {BuildContext? context,
    Color? color,
    bool disabled = false,
    bool replaceIconIfNull = false,
    String? description,
    bool onlyDesktopDescription = true,
    bool alwaysMobileDescription = false,
    String? badge,
    String? iconBadge,
    bool? iconAfterwards,
    void Function()? onDisabledTap,
    void Function()? onLongTap,
    void Function()? onDoubleTap}) {
  if (description != null &&
      ((context != null && desktopLayoutNotRequired(context)) ||
          !onlyDesktopDescription) &&
      !alwaysMobileDescription &&
      !description.startsWith("\n")) {
    description = " • $description";
  }
  return AnimatedContainer(
    duration: const Duration(milliseconds: 200),
    padding: (context != null && desktopLayoutNotRequired(context))
        ? const EdgeInsets.only(top: 8, bottom: 8)
        : EdgeInsets.zero,
    child: InkWell(
        enableFeedback: false,
        // disable hint that clickable, other tap functions still functional
        splashFactory: (onPressed == null) ? NoSplash.splashFactory : null,
        highlightColor: (onPressed == null) ? Colors.transparent : null,
        hoverColor: (onPressed == null) ? Colors.transparent : null,
        onTap: disabled
            ? () {
                selectionHaptic();
                if (onDisabledTap != null) {
                  onDisabledTap();
                }
              }
            : (onPressed == null && (onLongTap != null || onDoubleTap != null))
                ? () {
                    selectionHaptic();
                  }
                : onPressed,
        onLongPress: (description != null && context != null)
            ? (desktopLayoutNotRequired(context) && !alwaysMobileDescription) ||
                    !onlyDesktopDescription
                ? null
                : () {
                    selectionHaptic();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(description!.trim()),
                        showCloseIcon: true));
                  }
            : onLongTap,
        onDoubleTap: onDoubleTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Builder(builder: (context) {
            var iconContent = (icon != null || replaceIconIfNull)
                ? replaceIconIfNull
                    ? ImageIcon(MemoryImage(kTransparentImage))
                    : Icon(icon,
                        color: disabled || (iconAfterwards ?? false)
                            ? Colors.grey
                            : color)
                : const SizedBox.shrink();
            return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  !(iconAfterwards ?? false)
                      ? (iconBadge == null)
                          ? iconContent
                          : Badge(
                              label: (iconBadge != "") ? Text(iconBadge) : null,
                              child: iconContent)
                      : const SizedBox.shrink(),
                  (icon != null || replaceIconIfNull)
                      ? SizedBox(
                          width: !(iconAfterwards ?? false) ? 16 : null,
                          height: 42)
                      : const SizedBox.shrink(),
                  Expanded(child: Builder(builder: (context) {
                    Widget textWidget = Text(text,
                        style:
                            TextStyle(color: disabled ? Colors.grey : color));
                    if (badge != null) {
                      textWidget = Badge(
                          label: Text(badge),
                          offset: const Offset(20, -4),
                          backgroundColor:
                              Theme.of(context).colorScheme.primary,
                          textColor: Theme.of(context).colorScheme.onPrimary,
                          child: textWidget);
                    }
                    if (iconAfterwards ?? false) {
                      return Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            textWidget,
                            // same info distance as [toggle]
                            const SizedBox(width: 8),
                            Transform.translate(
                                offset: const Offset(0, 1),
                                child: (iconBadge == null)
                                    ? iconContent
                                    : Badge(
                                        label: (iconBadge != "")
                                            ? Text(iconBadge)
                                            : null,
                                        child: iconContent)),
                          ]);
                    } else {
                      if (description == null ||
                          description!.startsWith("\n")) {
                        description = description?.removePrefix("\n");
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              textWidget,
                              (description != null &&
                                      !alwaysMobileDescription &&
                                      (desktopLayoutNotRequired(context) ||
                                          !onlyDesktopDescription))
                                  ? Text(description!,
                                      style: const TextStyle(
                                          color: Colors.grey,
                                          overflow: TextOverflow.ellipsis))
                                  : const SizedBox.shrink()
                            ]);
                      } else {
                        return Row(
                            mainAxisAlignment: MainAxisAlignment.start,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              textWidget,
                              (description != null &&
                                      !alwaysMobileDescription &&
                                      (desktopLayoutNotRequired(context) ||
                                          !onlyDesktopDescription))
                                  ? Expanded(
                                      child: Text(description!,
                                          style: const TextStyle(
                                              color: Colors.grey,
                                              overflow: TextOverflow.ellipsis)),
                                    )
                                  : const SizedBox.shrink()
                            ]);
                      }
                    }
                  }))
                ]);
          }),
        )),
  );
}

class ScreenSettings extends StatefulWidget {
  const ScreenSettings({super.key});

  @override
  State<ScreenSettings> createState() => _ScreenSettingsState();
}

class _ScreenSettingsState extends State<ScreenSettings> {
  double iconSize = 1;
  bool animatedInitialized = false;
  bool animatedDesktop = false;

  @override
  void initState() {
    super.initState();
    WidgetsFlutterBinding.ensureInitialized();
  }

  @override
  Widget build(BuildContext context) {
    if (!animatedInitialized) {
      animatedInitialized = true;
      animatedDesktop = desktopLayoutNotRequired(context);
    }
    return PopScope(
        onPopInvokedWithResult: (didPop, result) {
          settingsOpen = false;
          FocusManager.instance.primaryFocus?.unfocus();
        },
        child: WindowBorder(
            color: Theme.of(context).colorScheme.surface,
            child: Scaffold(
                appBar: AppBar(
                    title: Row(children: [
                      Text(AppLocalizations.of(context)!.optionSettings),
                      Expanded(
                          child: SizedBox(height: 200, child: MoveWindow()))
                    ]),
                    actions: desktopControlsActions(context)),
                body: SafeArea(
              top: false,
              child: Center(
                  child: Container(
                      constraints: const BoxConstraints(maxWidth: 1200),
                      padding: const EdgeInsets.only(left: 16, right: 16),
                      child: LayoutBuilder(builder: (context, constraints) {
                        var column1 =
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: animatedDesktop ? 8 : 0,
                              child: const SizedBox.shrink()),
                          const SizedBox(height: 8),
                          const ServerList()
                        ]);
                        var column2 =
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          button(
                              AppLocalizations.of(context)!
                                  .settingsTitleBehavior,
                              Icons.psychology_rounded, () {
                            selectionHaptic();
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        const ScreenSettingsBehavior()));
                          },
                              context: context,
                              description:
                                  "\n${AppLocalizations.of(context)!.settingsDescriptionBehavior}"),
                          button(
                              AppLocalizations.of(context)!
                                  .settingsTitleInterface,
                              Icons.web_asset_rounded, () {
                            selectionHaptic();
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        const ScreenSettingsInterface()));
                          },
                              context: context,
                              description:
                                  "\n${AppLocalizations.of(context)!.settingsDescriptionInterface}"),
                          (!desktopFeature(web: true))
                              ? button(
                                  AppLocalizations.of(context)!
                                      .settingsTitleVoice,
                                  Icons.headphones_rounded, () {
                                  selectionHaptic();
                                  Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (context) =>
                                              const ScreenSettingsVoice()));
                                },
                                  context: context,
                                  description:
                                      "\n${AppLocalizations.of(context)!.settingsDescriptionVoice}",
                                  badge: AppLocalizations.of(context)!
                                      .settingsExperimentalBeta)
                              : const SizedBox.shrink(),
                          (!kIsWeb)
                              ? button(
                                  AppLocalizations.of(context)!
                                      .settingsTitleSpeech,
                                  Icons.record_voice_over_rounded, () {
                                  selectionHaptic();
                                  Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (context) =>
                                              const ScreenSettingsSpeech()));
                                },
                                  context: context,
                                  description:
                                      "\n${AppLocalizations.of(context)!.settingsDescriptionSpeech}")
                              : const SizedBox.shrink(),
                          button(
                              AppLocalizations.of(context)!.settingsTitleExport,
                              Icons.share_rounded, () {
                            selectionHaptic();
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        const ScreenSettingsExport()));
                          },
                              context: context,
                              description:
                                  "\n${AppLocalizations.of(context)!.settingsDescriptionExport}"),
                          Builder(builder: (context) {
                            return button(
                                AppLocalizations.of(context)!
                                    .settingsTitleAbout,
                                Icons.help_rounded, () {
                              selectionHaptic();
                              Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (context) =>
                                          const ScreenSettingsAbout()));
                            },
                                context: context,
                                description:
                                    "\n${AppLocalizations.of(context)!.settingsDescriptionAbout}",
                                iconBadge: (updateStatus == "ok" &&
                                        updateDetectedOnStart &&
                                        (Version.parse(
                                                latestVersion ?? "1.0.0") >
                                            Version.parse(
                                                currentVersion ?? "2.0.0")))
                                    ? ""
                                    : null);
                          })
                        ]);
                        animatedDesktop = desktopLayoutNotRequired(context);
                        return Column(children: [
                          Expanded(
                              child: desktopLayoutNotRequired(context)
                                  ? Row(
                                      mainAxisSize: MainAxisSize.max,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                          Expanded(
                                              child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.max,
                                                  children: [
                                                column1,
                                                Expanded(
                                                    child: Center(
                                                        child: InkWell(
                                                  splashFactory:
                                                      NoSplash.splashFactory,
                                                  highlightColor:
                                                      Colors.transparent,
                                                  enableFeedback: false,
                                                  hoverColor:
                                                      Colors.transparent,
                                                  onTap: () async {
                                                    if (iconSize != 1) return;
                                                    heavyHaptic();
                                                    setState(() {
                                                      iconSize = 0.8;
                                                    });
                                                    await Future.delayed(
                                                        const Duration(
                                                            milliseconds: 200));
                                                    setState(() {
                                                      iconSize = 1.2;
                                                    });
                                                    await Future.delayed(
                                                        const Duration(
                                                            milliseconds: 200));
                                                    setState(() {
                                                      iconSize = 1;
                                                    });
                                                  },
                                                  child: AnimatedScale(
                                                    scale: iconSize,
                                                    duration: const Duration(
                                                        milliseconds: 400),
                                                    child: const ImageIcon(
                                                        AssetImage(
                                                            "assets/logo512.png"),
                                                        size: 44),
                                                  ),
                                                ))),
                                                Transform.translate(
                                                  offset: const Offset(0, 8),
                                                  child: button(
                                                      AppLocalizations.of(
                                                              context)!
                                                          .settingsSavedAutomatically,
                                                      Icons.info_rounded,
                                                      null,
                                                      color: Colors.grey
                                                          .harmonizeWith(
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .primary)),
                                                )
                                              ])),
                                          verticalTitleDivider(
                                              context: context),
                                          Expanded(child: column2)
                                        ])
                                  : ListView(children: [
                                      column1,
                                      AnimatedOpacity(
                                          opacity: animatedDesktop ? 0 : 1,
                                          duration:
                                              const Duration(milliseconds: 200),
                                          child: titleDivider(bottom: 4)),
                                      AnimatedOpacity(
                                          opacity: animatedDesktop ? 0 : 1,
                                          duration:
                                              const Duration(milliseconds: 200),
                                          child: column2)
                                    ])),
                          const SizedBox(height: 8),
                          desktopLayoutNotRequired(context)
                              ? const SizedBox.shrink()
                              : button(
                                  AppLocalizations.of(context)!
                                      .settingsSavedAutomatically,
                                  Icons.info_rounded,
                                  null,
                                  color: Colors.grey.harmonizeWith(
                                      Theme.of(context).colorScheme.primary))
                        ]);
                      })),
                )))));
  }
}

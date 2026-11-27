import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

Future<void> showUpdatePrompt(
  BuildContext context,
  VersionInfo info, {
  bool automatic = false,
}) async {
  final firstPrompt = context.read<UpdateCubit>().markPromptShown(info);
  if (automatic && !firstPrompt) return;
  final open = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      final theme = Theme.of(dialog);
      final colors = theme.colorScheme;
      final apple = usesAppleGlass;
      final buttonStyle =
          apple
              ? FilledButton.styleFrom(
                foregroundColor: colors.onSurface,
                backgroundColor: colors.onSurface.withValues(alpha: .12),
                shape: const StadiumBorder(),
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
              )
              : null;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        backgroundColor: apple ? Colors.transparent : null,
        elevation: apple ? 0 : null,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: AppleGlassSurface(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('检测到新版本', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '要更新吗？',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          style: buttonStyle,
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('暂不', textAlign: TextAlign.center),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonal(
                          style: buttonStyle,
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text(
                            '打开 GitHub',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  if (open != true || !context.mounted) return;
  try {
    if (await launchUrl(
      Uri.parse(info.url),
      mode: LaunchMode.externalApplication,
    )) {
      return;
    }
  } catch (_) {
    // Report link failures in the same page that opened the prompt.
  }
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('无法打开 GitHub 发布页')));
  }
}

class UpdateChecker extends StatefulWidget {
  final Widget child;
  final bool forceCheck;

  const UpdateChecker({
    super.key,
    required this.child,
    this.forceCheck = false,
  });

  @override
  State<UpdateChecker> createState() => _UpdateCheckerState();
}

class _UpdateCheckerState extends State<UpdateChecker> {
  VersionInfo? _availableUpdate;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context);
    if (current != false && _availableUpdate != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showIfCurrent());
    }
  }

  void _showIfCurrent() {
    final info = _availableUpdate;
    if (!mounted || info == null || ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    _availableUpdate = null;
    unawaited(showUpdatePrompt(context, info, automatic: true));
  }

  Future<void> _checkUpdate() async {
    if (!mounted) return;
    final settings = settingsPreferencesOf(context, listen: false);
    if (!settings.autoUpdate && !widget.forceCheck) return;
    final updateInfo = await context.read<UpdateCubit>().checkUpdate(
      force: widget.forceCheck,
      channel: settings.updateChannel,
    );
    if (!mounted) return;
    _availableUpdate = updateInfo;
    _showIfCurrent();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkUpdate());
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

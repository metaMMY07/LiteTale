import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/settings/settings_preferences.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/utils/app_info.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_solid_surface.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/update_checker.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      throw Exception('Could not launch $url');
    }
    await launchUrl(uri);
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final channel = settingsPreferencesOf(context, listen: false).updateChannel;
    final info = await context.read<UpdateCubit>().checkUpdate(
      force: true,
      channel: channel,
    );
    if (info != null &&
        context.mounted &&
        ModalRoute.isCurrentOf(context) != false) {
      await showUpdatePrompt(context, info);
    }
  }

  Widget _iosCheckUpdateButton(
    BuildContext context, {
    required bool checking,
  }) => IosAccentGlassCapsuleButton(
    glassKey: const ValueKey('about-check-update-glass'),
    buttonKey: const ValueKey('about-check-update-button'),
    label: checking ? '正在检查更新…' : '检查更新',
    icon: CupertinoIcons.refresh,
    busy: checking,
    fullWidth: true,
    minHeight: 50,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
    onPressed: checking ? null : () => _checkUpdate(context),
  );

  Widget _iosAboutSections(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final headingStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: colors.onSurface,
    );
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: colors.onSurface.withValues(alpha: 0.88),
    );
    final externalTrailing = Icon(
      CupertinoIcons.arrow_up_right,
      size: 16,
      color: colors.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosGroupedCardSurface(
          key: const ValueKey('about-project-card'),
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text('关于 LiteTale', style: headingStyle),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'LiteTale 是一个使用 Flutter 开发的轻小说文库客户端，提供流畅的阅读体验和丰富的功能。',
                      style: bodyStyle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '本版本基于开源项目 Wild 开发，感谢原作者和所有贡献者。',
                      style: bodyStyle,
                    ),
                  ],
                ),
              ),
              iosGroupedDivider(
                context,
                indent: const EdgeInsetsDirectional.only(start: 18),
              ),
              IosSettingsRow(
                icon: CupertinoIcons.chevron_left_slash_chevron_right,
                title: '查看 LiteTale 源代码',
                trailing: externalTrailing,
                onTap: () => _launchUrl('https://github.com/metaMMY07/LiteTale'),
              ),
              iosGroupedDivider(
                context,
                indent: const EdgeInsetsDirectional.only(
                  start: IosSettingsSection.titleStartIndent,
                ),
              ),
              IosSettingsRow(
                icon: CupertinoIcons.arrow_branch,
                title: '查看上游 Wild 项目',
                trailing: externalTrailing,
                onTap: () => _launchUrl('https://github.com/niuhuan/wild'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        IosGroupedCardSurface(
          key: const ValueKey('about-license-card'),
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text('开源协议', style: headingStyle),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Wild 衍生代码采用 GNU GPL v3；应用图标来自 Novella，并按 GNU AGPL v3 许可使用。',
                      style: bodyStyle,
                    ),
                  ],
                ),
              ),
              iosGroupedDivider(
                context,
                indent: const EdgeInsetsDirectional.only(start: 18),
              ),
              IosSettingsRow(
                icon: CupertinoIcons.doc_text,
                title: '查看开源许可',
                onTap: () => showLicensePage(context: context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UpdateCubit, UpdateState>(
      builder: (context, state) {
        final checking = state.phase == UpdatePhase.checking;
        final apple = usesAppleGlass;
        return Scaffold(
          appBar: settingsAppBar(context, '关于'),
          body: LeftAlignedScrollView(
            topInset: 16,
            bottomInset: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: apple ? 12 : 24),
                Center(
                  child: Icon(
                    apple ? CupertinoIcons.book_fill : Icons.book,
                    size: apple ? 72 : 80,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    AppInfo.appName,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    '版本 ${AppInfo.version}',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w400,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(height: apple ? 24 : 32),
                if (state.updateInfo case final info?) ...[
                  if (apple)
                    IosSolidPillButton(
                      minHeight: 50,
                      onPressed: () => showUpdatePrompt(context, info),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(CupertinoIcons.arrow_down_circle, size: 19),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '发现新版本 ${info.version}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: AppButton.filledIcon(
                        onPressed: () => showUpdatePrompt(context, info),
                        icon: const Icon(Icons.system_update),
                        label: Text('发现新版本 ${info.version}'),
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
                if (apple)
                  _iosCheckUpdateButton(context, checking: checking)
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AppButton.outlinedIcon(
                      onPressed: checking ? null : () => _checkUpdate(context),
                      icon:
                          checking
                              ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                              : const Icon(Icons.refresh),
                      label: Text(checking ? '正在检查更新…' : '检查更新'),
                    ),
                  ),
                if (!checking &&
                    state.updateInfo == null &&
                    state.message.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      state.message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w400,
                        color:
                            apple
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : null,
                      ),
                    ),
                  ),
                ],
                SizedBox(height: apple ? 24 : 32),
                if (apple)
                  _iosAboutSections(context)
                else
                  SettingsCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '关于 LiteTale',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'LiteTale 是一个使用 Flutter 开发的轻小说文库客户端，提供流畅的阅读体验和丰富的功能。',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '本版本基于开源项目 Wild 开发，感谢原作者和所有贡献者。',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          AppButton.textIcon(
                            onPressed:
                                () => _launchUrl(
                                  'https://github.com/metaMMY07/LiteTale',
                                ),
                            icon: const Icon(Icons.code),
                            label: const Text('查看 LiteTale 源代码'),
                          ),
                          AppButton.textIcon(
                            onPressed:
                                () =>
                                    _launchUrl('https://github.com/niuhuan/wild'),
                            icon: const Icon(Icons.account_tree_outlined),
                            label: const Text('查看上游 Wild 项目'),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '开源协议',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Wild 衍生代码采用 GNU GPL v3；应用图标来自 Novella，并按 GNU AGPL v3 许可使用。',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          AppButton.textIcon(
                            onPressed: () => showLicensePage(context: context),
                            icon: const Icon(Icons.description_outlined),
                            label: const Text('查看开源许可'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

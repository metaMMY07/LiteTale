import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/login_page.dart';
import 'package:wild/pages/shelf_login_page.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/shelf_session.dart';
import 'package:wild/sources/source_api.dart' as api;
import 'package:wild/sources/source_website.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_solid_surface.dart';
import 'package:wild/widgets/material_source_picker.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/source_website.dart';

enum _SiteAction { website, signIn, signOut }

class SourceSettings extends StatelessWidget {
  const SourceSettings({super.key});

  Future<void> _selectSource(BuildContext context, SourceId value) async {
    if (value == activeSource.value) return;
    try {
      await api.selectSource(value);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('书源选择未能保存，请重试')));
      }
    }
  }

  Future<void> _openAccount(
    BuildContext context,
    SourceId source,
    Uri website,
  ) async {
    final wenku8 = source == SourceId.wenku8;
    final signedIn =
        wenku8
            ? context.read<AuthCubit>().state.status == AuthStatus.authenticated
            : ShelfSession.instance.signedIn.value;
    final action = await showAdaptiveDialog<_SiteAction>(
      context: context,
      useRootNavigator: false,
      builder:
          (dialogContext) => AlertDialog.adaptive(
            title: Text('${source.label}账号'),
            actions: [
              AppButton.text(
                onPressed:
                    () => Navigator.pop(dialogContext, _SiteAction.website),
                child: const Text('打开原网站'),
              ),
              AppButton.text(
                onPressed:
                    () => Navigator.pop(dialogContext, _SiteAction.signIn),
                child: Text(signedIn ? '重新登录' : '登录'),
              ),
              if (signedIn)
                AppButton.text(
                  onPressed:
                      () => Navigator.pop(dialogContext, _SiteAction.signOut),
                  child: const Text('退出登录'),
                ),
              AppButton.text(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
            ],
          ),
    );
    if (!context.mounted || activeSource.value != source) return;
    switch (action) {
      case _SiteAction.website:
        await openSourceWebsite(context, website);
      case _SiteAction.signIn:
        await Navigator.of(context).push(
          HorizontalCoverPageRoute(
            builder: (_) => wenku8 ? const LoginPage() : const ShelfLoginPage(),
          ),
        );
        if (activeSource.value == source) sourceRevision.value++;
      case _SiteAction.signOut:
        try {
          if (wenku8) {
            await api.logout();
            if (context.mounted) context.read<AuthCubit>().logout();
          } else {
            await ShelfSession.instance.logout();
            api.clearShelfSessionCache();
          }
          if (activeSource.value == source) sourceRevision.value++;
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('退出失败，请重试')));
          }
        }
      case null:
        break;
    }
  }

  Widget _picker(BuildContext context, SourceId source) {
    final sources = api.availableSources;
    if (!usesAppleGlass) {
      return MaterialSourcePicker(
        value: source,
        sources: sources,
        onChanged: (value) => _selectSource(context, value),
      );
    }
    return IosGroupedCardSurface(
      key: const ValueKey('source-card-current'),
      color: Theme.of(context).colorScheme.surface,
      // The trailing UIKit view stays inside the row padding. Only the route
      // clips it during navigation, so the grouped card can draw continuously.
      clipBehavior: Clip.none,
      child: LayoutBuilder(
        builder:
            (context, constraints) => IosSettingsRow(
              icon: CupertinoIcons.book,
              title: '当前书源',
              trailing: AppleGlassMenu(
                key: const ValueKey('source-picker-button'),
                label: source.label,
                selected: source.name,
                width: math.min(200, constraints.maxWidth * .47),
                textOnly: true,
                items: [
                  for (final item in sources)
                    {
                      'label': item.isRule ? '${item.label}（导入）' : item.label,
                      'value': item.name,
                    },
                ],
                onSelect: (name) {
                  for (final item in sources) {
                    if (item.name == name) {
                      _selectSource(context, item);
                      return;
                    }
                  }
                },
              ),
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = context.select((ApiHostCubit? cubit) => cubit?.state);
    return ListenableBuilder(
      listenable: Listenable.merge([activeSource, sourceRevision]),
      builder: (context, _) {
        final source = activeSource.value;
        final website = sourceWebsite(source, wenku8Host: host);
        final hasAccount =
            source == SourceId.wenku8 || source == SourceId.lightNovelShelf;
        final title = hasAccount ? '原站登录' : '打开原网站';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _picker(context, source),
            if (website != null) ...[
              const SizedBox(height: 12),
              SettingsCard(
                key: const ValueKey('source-card-website'),
                margin: EdgeInsets.zero,
                filled: true,
                child: _siteRow(context, source, website, hasAccount, title),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _siteRow(
    BuildContext context,
    SourceId source,
    Uri website,
    bool hasAccount,
    String title,
  ) {
    void open() {
      if (hasAccount) {
        _openAccount(context, source, website);
      } else {
        openSourceWebsite(context, website);
      }
    }

    if (usesAppleGlass) {
      return IosSettingsRow(
        icon: CupertinoIcons.arrow_up_right_square,
        title: title,
        trailing: null,
        onTap: open,
      );
    }
    return ListTile(
      leading: const Icon(Icons.open_in_new_rounded),
      title: Text(title),
      onTap: open,
    );
  }
}

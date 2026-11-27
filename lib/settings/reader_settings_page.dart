import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/ios_top_bar_backdrop.dart';
import 'package:wild/widgets/left_aligned_scrollable.dart';
import 'package:wild/widgets/reader_settings_binding.dart';
import 'package:wild/widgets/reader_settings_panel.dart';

class ReaderSettingsPage extends StatelessWidget {
  const ReaderSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (!usesAppleGlass) {
      return Scaffold(
        appBar: settingsAppBar(context, '阅读显示'),
        body: const ReaderSettingsPanel(),
      );
    }
    return IosTopBarScaffold(
      appBar: settingsAppBar(context, '阅读显示'),
      body: LeftAlignedScrollView(
        topInset: 12,
        bottomInset: 28,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            _IosReaderCategoryCard(
              cardKey: ValueKey('reader-settings-card-typography'),
              icon: CupertinoIcons.textformat_size,
              section: ReaderSettingsSection.typography,
            ),
            SizedBox(height: 12),
            _IosReaderCategoryCard(
              cardKey: ValueKey('reader-settings-card-mode'),
              icon: CupertinoIcons.book,
              section: ReaderSettingsSection.readingMode,
            ),
            SizedBox(height: 12),
            _IosReaderCategoryCard(
              cardKey: ValueKey('reader-settings-card-appearance'),
              icon: CupertinoIcons.paintbrush,
              section: ReaderSettingsSection.appearance,
            ),
          ],
        ),
      ),
    );
  }
}

class _IosReaderCategoryCard extends StatelessWidget {
  const _IosReaderCategoryCard({
    required this.cardKey,
    required this.icon,
    required this.section,
  });

  final Key cardKey;
  final IconData icon;
  final ReaderSettingsSection section;

  @override
  Widget build(BuildContext context) => SettingsCard(
    key: cardKey,
    margin: EdgeInsets.zero,
    filled: true,
    child: IosSettingsRow(
      icon: icon,
      title: section.title,
      onTap:
          () => openSettingsPage(
            context,
            ReaderSettingsSectionPage(section: section),
          ),
    ),
  );
}

class ReaderSettingsSectionPage extends StatelessWidget {
  const ReaderSettingsSectionPage({super.key, required this.section});

  final ReaderSettingsSection section;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsAppBar(context, section.title),
    body: ReaderSettingsPanel(section: section),
  );
}

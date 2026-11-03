import 'package:flutter/material.dart';
import 'package:wild/widgets/reader_settings_panel.dart';

class ReaderSettingsPage extends StatelessWidget {
  const ReaderSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('阅读显示')),
    body: const ReaderSettingsPanel(),
  );
}

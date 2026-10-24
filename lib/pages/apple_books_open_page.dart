import 'package:wild/widgets/platform_controls.dart';
import 'package:flutter/material.dart';
import 'package:wild/services/epub/apple_books_opener.dart';
import 'package:wild/services/epub/local_epub_library.dart';

/// Covers reader links from history/details as well as the local-library entry.
class AppleBooksOpenPage extends StatefulWidget {
  const AppleBooksOpenPage({super.key, required this.bookId});
  final String bookId;

  @override
  State<AppleBooksOpenPage> createState() => _AppleBooksOpenPageState();
}

class _AppleBooksOpenPageState extends State<AppleBooksOpenPage> {
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (!mounted || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await AppleBooksOpener.instance.open(
        LocalEpubLibrary.instance,
        widget.bookId,
        isActive: () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
      );
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        await Navigator.maybePop(context);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '未能打开 EPUB，请重新导入原文件后重试。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('在图书中阅读')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_rounded, size: 56),
            const SizedBox(height: 20),
            Text(
              _error ?? '在系统菜单中选择“图书”，使用原书排版阅读。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            AppButton.filled(
              onPressed: _opening ? null : _open,
              child: Text(_opening ? '正在打开系统菜单…' : '添加到图书'),
            ),
          ],
        ),
      ),
    ),
  );
}

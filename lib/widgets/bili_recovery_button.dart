import 'package:flutter/material.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'bili_verification_page.dart';

/// Offers a same-site verification flow for the exact Bili request that failed.
/// A stale verification must never replay a different book or source request.
class BiliRecoveryButton extends StatefulWidget {
  const BiliRecoveryButton({
    super.key,
    required this.error,
    required this.source,
    required this.onRecovered,
    this.verify,
  });

  final Object? error;
  final SourceId source;
  final Future<void> Function() onRecovered;
  final Future<bool> Function(BuildContext)? verify;

  @override
  State<BiliRecoveryButton> createState() => _BiliRecoveryButtonState();
}

class _BiliRecoveryButtonState extends State<BiliRecoveryButton> {
  bool _opening = false;

  Future<bool> _verify(
    BuildContext context,
    BiliSiteVerificationRequired request,
  ) async {
    if (!context.mounted) return false;
    final result = await Navigator.of(context).push<bool>(
      HorizontalCoverPageRoute<bool>(
        builder: (_) => BiliVerificationPage(request: request),
      ),
    );
    return result == true;
  }

  Future<void> _recover() async {
    if (_opening || widget.source != SourceId.bili) return;
    final error = widget.error;
    if (error is! BiliSiteVerificationRequired) return;
    final source = activeSource.value;
    final revision = sourceRevision.value;
    if (source != SourceId.bili || error.revision != revision) return;

    setState(() => _opening = true);
    try {
      final verified = await (widget.verify ??
          (context) => _verify(context, error))(context);
      if (!mounted ||
          verified != true ||
          source != SourceId.bili ||
          activeSource.value != source ||
          sourceRevision.value != revision ||
          widget.source != source ||
          !identical(widget.error, error)) {
        return;
      }
      await widget.onRecovered();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能完成哔哩原站验证，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.error;
    if (widget.source != SourceId.bili ||
        request is! BiliSiteVerificationRequired) {
      return const SizedBox.shrink();
    }
    return OutlinedButton.icon(
      onPressed: _opening ? null : _recover,
      icon: const Icon(Icons.open_in_browser_rounded),
      label: Text(request.contentRequired ? '打开原站加载完整正文' : '打开哔哩原站验证'),
    );
  }
}

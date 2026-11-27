import 'package:wild/widgets/platform_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/utils/wenku8_network_error.dart';
import 'wenku8_verification_page.dart';

/// Explicit, visible verification. Returning from a verified guest page also
/// allows a retry; cancelling or switching source never replays an old read.
class Wenku8RecoveryButton extends StatefulWidget {
  const Wenku8RecoveryButton({
    super.key,
    required this.error,
    required this.source,
    required this.onRecovered,
    this.verify,
    this.siteVerificationOnly = false,
  });
  final Object? error;
  final SourceId source;
  final Future<void> Function() onRecovered;
  final Future<bool> Function(BuildContext)? verify;
  final bool siteVerificationOnly;

  @override
  State<Wenku8RecoveryButton> createState() => _Wenku8RecoveryButtonState();
}

class _Wenku8RecoveryButtonState extends State<Wenku8RecoveryButton> {
  bool _opening = false;
  bool get _canRecover =>
      widget.source == SourceId.wenku8 &&
      (widget.siteVerificationOnly
          ? widget.error is Wenku8SiteVerificationRequired ||
              widget.error is Wenku8SiteLoginRequired
          : shouldOfferWenku8SiteVerification(widget.error));

  Future<bool> _verify(BuildContext context, Object? error) async {
    final revision = sourceRevision.value;
    final host = await Wenku8BrowserSession.instance.apiHost();
    if (!context.mounted ||
        sourceRevision.value != revision ||
        activeSource.value != SourceId.wenku8 ||
        !identical(widget.error, error)) {
      return false;
    }
    final target = switch (error) {
      Wenku8SiteVerificationRequired(:final target) => target,
      Wenku8SiteLoginRequired(:final target) => target,
      _ => null,
    };
    final page = HorizontalCoverPageRoute<bool>(
      fullscreenDialog: true,
      builder:
          (_) => Wenku8VerificationPage(
            apiHost: host,
            sessionOnly: true,
            target: target,
          ),
    );
    final result = await Navigator.of(context).push(page);
    await page.completed;
    if (result == true &&
        context.mounted &&
        activeSource.value == SourceId.wenku8 &&
        sourceRevision.value == revision) {
      await context.read<AuthCubit?>()?.init();
    }
    return result != null;
  }

  Future<void> _recover() async {
    if (_opening || !_canRecover) return;
    final source = activeSource.value, revision = sourceRevision.value;
    final error = widget.error;
    setState(() => _opening = true);
    try {
      final verified =
          await (widget.verify?.call(context) ?? _verify(context, error));
      if (!mounted ||
          !verified ||
          activeSource.value != source ||
          sourceRevision.value != revision ||
          !identical(widget.error, error)) {
        return;
      }
      await widget.onRecovered();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能完成站点验证，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRecover) {
      return const SizedBox.shrink();
    }
    return AppButton.outlinedIcon(
      onPressed: _opening ? null : _recover,
      icon: const Icon(Icons.open_in_browser_rounded),
      label: const Text('打开文库8验证 / 登录'),
    );
  }
}

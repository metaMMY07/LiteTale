import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wild/cubits/api_host_cubit.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_website.dart';
import 'app_loading_indicator.dart';
import 'platform_controls.dart';

Future<void> openSourceWebsite(BuildContext context, Uri uri) async {
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // Launch failures do not change the pending read, source or login state.
  }
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('无法打开浏览器，可复制网址后手动访问')));
  }
}

class SourceWebsiteLink extends StatelessWidget {
  const SourceWebsiteLink({
    super.key,
    required this.source,
    this.showAddress = true,
    this.textAlign = TextAlign.center,
  });
  final SourceId source;
  final bool showAddress;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    if (source == SourceId.localEpub) return const SizedBox.shrink();
    final host = context.select((ApiHostCubit? cubit) => cubit?.state);
    final uri = sourceWebsite(source, wenku8Host: host);
    if (uri == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          textAlign == TextAlign.center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
      children: [
        if (showAddress)
          SelectableText(
            '$uri',
            textAlign: textAlign,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        AppButton.outlinedIcon(
          onPressed: () => openSourceWebsite(context, uri),
          icon: const Icon(Icons.open_in_browser_rounded),
          label: const Text('打开原网站'),
        ),
      ],
    );
  }
}

/// An inline hint, not another request/timeout or an automatically opened page.
/// The deadline is tied to a single load, unaffected by ordinary rebuilds.
class SourceLoadingIndicator extends StatefulWidget {
  const SourceLoadingIndicator({
    super.key,
    required this.source,
    this.requestKey,
    this.message,
    this.delay = const Duration(seconds: 8),
    this.size,
    this.centered = true,
  });
  final SourceId source;
  final Object? requestKey;
  final String? message;
  final Duration delay;
  final double? size;
  final bool centered;

  @override
  State<SourceLoadingIndicator> createState() => _SourceLoadingIndicatorState();
}

class _SourceLoadingIndicatorState extends State<SourceLoadingIndicator> {
  Timer? _timer;
  bool _slow = false;
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _slow = false;
    if (widget.source == SourceId.localEpub) return;
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void didUpdateWidget(covariant SourceLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.requestKey != widget.requestKey ||
        oldWidget.delay != widget.delay) {
      _start();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppLoadingIndicator(size: widget.size),
          if (widget.message != null) ...[
            const SizedBox(height: 16),
            Text(widget.message!, textAlign: TextAlign.center),
          ],
          if (_slow) ...[
            const SizedBox(height: 16),
            const Text('加载较久，可打开原网站对照访问情况。', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            SourceWebsiteLink(source: widget.source),
          ],
        ],
      ),
    );
    return widget.centered
        ? Center(child: content)
        : ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .35,
          ),
          child: content,
        );
  }
}

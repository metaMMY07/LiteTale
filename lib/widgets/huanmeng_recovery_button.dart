import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wild/services/huanmeng_api_session.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/wenku_webview.dart';

class HuanmengRecoveryButton extends StatefulWidget {
  const HuanmengRecoveryButton({
    super.key,
    required this.request,
    required this.onRecovered,
  });
  final HuanmengVerificationRequired request;
  final Future<void> Function() onRecovered;
  @override
  State<HuanmengRecoveryButton> createState() => _HuanmengRecoveryButtonState();
}

class _HuanmengRecoveryButtonState extends State<HuanmengRecoveryButton> {
  bool opening = false;
  Future<void> _open() async {
    final revision = sourceRevision.value,
        source = activeSource.value,
        request = widget.request;
    if (opening || request.revision != revision) return;
    setState(() => opening = true);
    try {
      final result = await Navigator.of(context).push<bool>(
        HorizontalCoverPageRoute(
          builder: (_) => HuanmengVerificationPage(request: request),
        ),
      );
      if (mounted &&
          result == true &&
          identical(request, widget.request) &&
          revision == sourceRevision.value &&
          source == activeSource.value) {
        await widget.onRecovered();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('原站暂时无法打开，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppButton.outlinedIcon(
    onPressed: opening ? null : _open,
    icon: const Icon(Icons.open_in_browser),
    label: const Text('打开幻梦原站验证'),
  );
}

class HuanmengVerificationPage extends StatefulWidget {
  const HuanmengVerificationPage({super.key, required this.request});
  final HuanmengVerificationRequired request;
  @override
  State<HuanmengVerificationPage> createState() =>
      _HuanmengVerificationPageState();
}

class _HuanmengVerificationPageState extends State<HuanmengVerificationPage> {
  final web = WenkuWebView();
  bool initialized = false, ready = false, confirming = false;
  String? error;
  Timer? timer;
  bool probing = false;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (!HuanmengApiSession.isApiTarget(widget.request.target)) {
      setState(() => error = '验证地址无效');
      return;
    }
    try {
      await web
          .initialize(
            onLoaded: () => unawaited(_probe()),
            onError: (message) {
              if (mounted) setState(() => error = message);
            },
            allowMainFrameNavigation: HuanmengApiSession.allowsNavigation,
            normalBrowserUserAgent: true,
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() => initialized = true);
      await web
          .loadUrl(widget.request.target.toString())
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      timer = Timer.periodic(
        const Duration(milliseconds: 800),
        (_) => unawaited(_probe()),
      );
    } catch (_) {
      if (mounted) setState(() => error = '原站页面暂时无法打开，请稍后重试。');
    }
  }

  Future<void> _probe() async {
    if (!mounted || !initialized || probing || confirming) return;
    probing = true;
    try {
      final probe = HuanmengApiSession.decodeProbe(
        await web
            .executeScript(HuanmengApiSession.documentProbe)
            .timeout(const Duration(seconds: 4)),
      );
      final valid = _validProbe(probe);
      if (mounted) setState(() => ready = valid);
    } catch (_) {
      if (mounted) setState(() => ready = false);
    } finally {
      probing = false;
    }
  }

  bool _validProbe(Map<String, dynamic> probe) {
    try {
      return HuanmengApiSession.verifiedEnvelope(widget.request, probe) != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _confirm() async {
    if (!ready || confirming) return;
    setState(() => confirming = true);
    try {
      final probe = await web
          .executeScript(HuanmengApiSession.documentProbe)
          .timeout(const Duration(seconds: 4));
      if (!mounted) return;
      if (HuanmengApiSession.instance.acceptVerification(
        widget.request,
        probe,
      )) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          ready = false;
          error = '原站尚未返回有效书籍数据，请完成验证后重试。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          ready = false;
          error = '验证未完成，请稍后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('幻梦原站验证')),
    body: Column(
      children: [
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        Expanded(
          child:
              initialized ? web.build() : const Center(child: Text('正在打开原站…')),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                const Text('请完成原站要求。返回有效书籍数据后即可继续。'),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: AppButton.filled(
                    onPressed: ready && !confirming ? _confirm : null,
                    child: const Text('验证完成并继续'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    timer?.cancel();
    unawaited(web.dispose());
    super.dispose();
  }
}

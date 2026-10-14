import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/widgets/wenku_webview.dart';

class BiliBrowserHost extends StatefulWidget {
  const BiliBrowserHost({super.key, required this.child});
  final Widget child;
  @override
  State<BiliBrowserHost> createState() => _BiliBrowserHostState();
}

class _BiliBrowserHostState extends State<BiliBrowserHost> {
  final session = BiliBrowserSession.instance;
  @override
  void initState() {
    super.initState();
    session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (session.requested)
        Offstage(
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: SizedBox(
                width: 1024,
                height: 768,
                child: _Renderer(key: ValueKey(session.rendererGeneration)),
              ),
            ),
          ),
        ),
    ],
  );
}

class _Renderer extends StatefulWidget {
  const _Renderer({super.key});
  @override
  State<_Renderer> createState() => _RendererState();
}

class _RendererState extends State<_Renderer> implements BiliBrowserPort {
  final web = WenkuWebView();
  final session = BiliBrowserSession.instance;
  bool initialized = false;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final generation = session.rendererGeneration;
    try {
      await web.initialize(
        onLoaded: () {},
        onError: (_) {},
        allowMainFrameNavigation: BiliBrowserSession.allowsNavigation,
        normalBrowserUserAgent: true,
        enableVerificationCookies: true,
      );
      if (!mounted || generation != session.rendererGeneration) return;
      setState(() => initialized = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && generation == session.rendererGeneration) {
        session.attach(this, generation);
      }
    } catch (_) {
      if (mounted && generation == session.rendererGeneration) {
        session.attachmentFailed();
      }
    }
  }

  @override
  Future<void> loadUrl(String url) => web.loadUrl(url);
  @override
  Future<void> setDesktopSite(bool enabled) => web.setDesktopSite(enabled);
  @override
  Future<dynamic> executeScript(String script) => web.executeScript(script);
  @override
  void dispose() {
    session.detach(this);
    unawaited(web.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      initialized ? web.build() : const SizedBox.shrink();
}

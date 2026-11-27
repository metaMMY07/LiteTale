import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wild/services/huanmeng_api_session.dart';
import 'package:wild/widgets/wenku_webview.dart';

class HuanmengBrowserHost extends StatefulWidget {
  const HuanmengBrowserHost({super.key, required this.child});
  final Widget child;
  @override
  State<HuanmengBrowserHost> createState() => _HuanmengBrowserHostState();
}

class _HuanmengBrowserHostState extends State<HuanmengBrowserHost> {
  final session = HuanmengApiSession.instance;
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

class _RendererState extends State<_Renderer> implements HuanmengBrowserPort {
  final web = WenkuWebView();
  final session = HuanmengApiSession.instance;
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
        allowMainFrameNavigation: HuanmengApiSession.allowsNavigation,
        normalBrowserUserAgent: true,
      );
      if (!mounted || generation != session.rendererGeneration) return;
      setState(() => initialized = true);
      session.attach(this, generation);
    } catch (_) {
      /* The pending request has a bounded attachment deadline. */
    }
  }

  @override
  Future<void> loadUrl(String url) => web.loadUrl(url);
  @override
  Future<dynamic> executeScript(String script) => web.executeScript(script);
  @override
  Widget build(BuildContext context) =>
      initialized ? web.build() : const SizedBox.shrink();
  @override
  void dispose() {
    session.detach(this);
    unawaited(web.dispose());
    super.dispose();
  }
}

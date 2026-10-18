import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wild/services/wenku8_browser.dart';
import 'package:wild/widgets/wenku_webview.dart';

/// A lazy renderer using the platform's ordinary persistent website session.
/// It is created only when the Wenku8 native transport needs a fallback.
class Wenku8BrowserHost extends StatefulWidget {
  const Wenku8BrowserHost({super.key, required this.child});
  final Widget child;
  @override
  State<Wenku8BrowserHost> createState() => _Wenku8BrowserHostState();
}

class _Wenku8BrowserHostState extends State<Wenku8BrowserHost> {
  final session = Wenku8BrowserSession.instance;
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
                width: 720,
                height: 1024,
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

class _RendererState extends State<_Renderer>
    implements Wenku8BrowserPort, Wenku8DocumentContextPort {
  final web = WenkuWebView();
  final session = Wenku8BrowserSession.instance;
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
        onLoaded: () {
          if (mounted && generation == session.rendererGeneration) {
            session.pageFinished();
          }
        },
        onError: (_) {
          if (mounted && generation == session.rendererGeneration) {
            session.pageError();
          }
        },
        allowMainFrameNavigation: session.allowsNavigation,
      );
      if (!mounted || generation != session.rendererGeneration) return;
      setState(() => initialized = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && generation == session.rendererGeneration) {
        session.attach(this);
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
  Future<String> currentUrl() => web.currentUrl();
  @override
  Future<dynamic> executeScript(String script) => web.executeScript(script);
  @override
  Future<void> persistSession() => web.persistSession();
  @override
  Future<bool> prepareDocumentContext(String host, String html) =>
      web.prepareDocumentContext(host, html);

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

import 'package:wild/widgets/platform_controls.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wild/services/bili_browser.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/utils/bili_site_dom.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/wenku_webview.dart';

/// Ordinary, user-visible site verification. No cookie or challenge token is
/// read by Dart; only the requested public book page is adopted on confirmation.
class BiliVerificationPage extends StatefulWidget {
  const BiliVerificationPage({
    super.key,
    required this.request,
    this.searchView,
  });
  final BiliSiteVerificationRequired request;
  final WenkuWebView? searchView;

  @override
  State<BiliVerificationPage> createState() => _BiliVerificationPageState();
}

class _BiliVerificationPageState extends State<BiliVerificationPage> {
  late final _web = widget.searchView ?? WenkuWebView();
  bool _initialized = false, _checking = false, _closed = false;
  bool _blocked = false;
  int _navigation = 0, _inspection = 0;
  String? _error;

  bool get _current =>
      mounted &&
      !_closed &&
      activeSource.value == SourceId.bili &&
      sourceRevision.value == widget.request.revision;

  @override
  void initState() {
    super.initState();
    activeSource.addListener(_sourceChanged);
    sourceRevision.addListener(_sourceChanged);
    unawaited(_initialize());
  }

  void _sourceChanged() {
    if (!mounted || _closed || _current) return;
    _navigation++;
    setState(() {
      _blocked = true;
      _error = '书源已变化，请返回重新打开。';
    });
    scheduleMicrotask(() {
      if (mounted && !_closed && ModalRoute.isCurrentOf(context) == true) {
        Navigator.of(context).pop<bool>(false);
      }
    });
  }

  bool _allowPage(String url) =>
      url == 'about:blank' ||
      (_current &&
          BiliBrowserSession.allowsVerificationNavigation(url, widget.request));

  void _pageError(String _) {
    if (_current) {
      setState(() => _error = '原站网页未能打开，可点右上角重试。');
    }
  }

  Future<void> _initialize() async {
    try {
      if (!BiliBrowserSession.isVerificationTarget(widget.request)) {
        throw const BiliBrowserException('原站验证地址无效，请返回重新打开。');
      }
      if (widget.searchView != null) {
        _web.setPageHandlers(
          allowMainFrameNavigation: _allowPage,
          onLoaded: () => unawaited(_inspectAccess()),
          onError: _pageError,
          onNavigationBlocked: () => _pageError(''),
        );
        _initialized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_closed) unawaited(_inspectAccess());
        });
        return;
      }
      await _web
          .initialize(
            normalBrowserUserAgent: true,
            enableVerificationCookies: true,
            allowMainFrameNavigation: _allowPage,
            onLoaded: () => unawaited(_inspectAccess()),
            onError: _pageError,
            onNavigationBlocked: () => _pageError(''),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted || _closed) return;
      setState(() => _initialized = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _closed) return;
      await _web
          .setDesktopSite(widget.request.desktopSite)
          .timeout(const Duration(seconds: 5));
      if (!mounted || _closed) return;
      await _openTarget();
    } catch (_) {
      if (mounted && !_closed) {
        setState(() => _error = '原站网页组件未能启动，请返回后重试。');
      }
    }
  }

  Future<void> _openTarget() async {
    if (!_initialized || _checking || !_current) return;
    _navigation++;
    setState(() {
      _error = null;
      _blocked = false;
    });
    try {
      final entry = widget.request.searchEntry ?? widget.request.target;
      await _web.loadUrl('$entry').timeout(const Duration(seconds: 5));
    } catch (_) {
      if (mounted && !_closed) {
        setState(() => _error = '原站网页未能打开，请检查网络后重试。');
      }
    }
  }

  Future<void> _inspectAccess() async {
    if (!_initialized || !_current) return;
    final navigation = _navigation, inspection = ++_inspection;
    try {
      final raw = await _web
          .executeScript(biliAccessProbeScript)
          .timeout(const Duration(seconds: 5));
      if (!_current || navigation != _navigation || inspection != _inspection) {
        return;
      }
      final blocked = BiliBrowserSession.isAccessDeniedProbe(raw);
      final keyword = widget.request.searchKeyword;
      final entry = widget.request.searchEntry;
      if (!blocked &&
          (widget.searchView == null || navigation > 0) &&
          keyword != null &&
          entry != null &&
          await _web.currentUrl().timeout(const Duration(seconds: 5)) ==
              '$entry' &&
          _current &&
          navigation == _navigation &&
          inspection == _inspection) {
        await _web
            .executeScript(biliFillSearchFieldScript(keyword))
            .timeout(const Duration(seconds: 5));
      }
      if (!_current || navigation != _navigation || inspection != _inspection) {
        return;
      }
      setState(() {
        if (_blocked && !blocked) _error = null;
        _blocked = blocked;
        if (blocked) {
          _error = BiliSiteAccessDenied(widget.request.target).message;
        }
      });
      if (widget.request.searchChallenge && !blocked && !_checking) {
        final search = await _web
            .executeScript(
              BiliBrowserSession.verificationScript(widget.request),
            )
            .timeout(const Duration(seconds: 5));
        if (_current &&
            !_checking &&
            navigation == _navigation &&
            inspection == _inspection &&
            BiliBrowserSession.isReadySearchProbe(search)) {
          await _continue(result: search);
        }
      }
    } catch (_) {
      // Navigation can replace this document while the inspection is running.
    }
  }

  Future<void> _continue({Object? result}) async {
    if (!_initialized ||
        _checking ||
        !_current ||
        _blocked ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final navigation = _navigation, inspection = _inspection;
    bool current() =>
        _current &&
        _checking &&
        navigation == _navigation &&
        inspection == _inspection &&
        ModalRoute.of(context)?.isCurrent == true;
    try {
      final raw =
          result ??
          await _web
              .executeScript(
                BiliBrowserSession.verificationScript(widget.request),
              )
              .timeout(const Duration(seconds: 5));
      if (!current()) return;
      final adopted = await BiliBrowserSession.instance.adoptVisiblePage(
        widget.request,
        raw,
        persistSession: _web.persistSession,
        isCurrent: current,
      );
      if (!mounted || !current()) return;
      if (!adopted) {
        setState(() => _error = '书源已变化，请返回重新打开。');
        return;
      }
      _closed = true;
      Navigator.of(context).pop<bool>(true);
    } catch (error) {
      if (current()) {
        setState(() {
          if (error is BiliSiteAccessDenied) _blocked = true;
          _error =
              error is BiliBrowserException
                  ? error.message
                  : '未能确认原站页面，请按网页提示完成后再试。';
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    _closed = true;
    activeSource.removeListener(_sourceChanged);
    sourceRevision.removeListener(_sourceChanged);
    if (widget.searchView == null) {
      unawaited(
        _web
            .dispose()
            .timeout(const Duration(seconds: 2))
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _closed = true;
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.request.contentRequired
              ? '哔哩原站阅读'
              : widget.request.searchChallenge
              ? '搜索验证'
              : '哔哩原站验证',
        ),
        actions: [
          AppIconButton(
            tooltip: '重新打开原站页面',
            onPressed:
                _initialized && !_checking && !_closed ? _openTarget : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error case final message?)
            if (usesAppleGlass)
              AppleGlassCard(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(message),
                ),
              )
            else
              MaterialBanner(
                content: Text(message),
                actions: [
                  AppButton.text(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('知道了'),
                  ),
                ],
              ),
          Expanded(
            child:
                _initialized
                    ? (widget.searchView == null
                        ? _web.build()
                        : _web.buildTransferable())
                    : _error == null
                    ? const CenteredLoadingIndicator()
                    : const SizedBox.shrink(),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _blocked
                        ? '原站拒绝访问，当前页面没有可完成的验证。请返回并稍后重试。'
                        : widget.request.contentRequired
                        ? '请按原站提示完成阅读要求，正文完整显示后再继续。'
                        : widget.searchView != null
                        ? '请在原站表单填写验证码，完成后继续搜索「${widget.request.searchKeyword}」。'
                        : widget.request.searchEntry != null
                        ? '请在原站搜索「${widget.request.searchKeyword}」，按网页提示填写验证码，结果显示后再返回。'
                        : '请在网页内完成原站验证，显示正常书目或正文后再继续。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: AppButton.filledIcon(
                      onPressed:
                          _initialized && !_checking && _current && !_blocked
                              ? _continue
                              : null,
                      icon: const Icon(Icons.check_rounded),
                      label: Text(
                        _blocked
                            ? '当前页面无法验证'
                            : _checking
                            ? '正在确认…'
                            : widget.request.contentRequired
                            ? '正文已完整，继续阅读'
                            : widget.request.kind == BiliProbeKind.chapter
                            ? '验证完成并继续阅读'
                            : '验证完成并返回',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

/// Floating reader chrome; neither toolbar changes the laid-out paper size.
class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({
    super.key,
    required this.title,
    required this.onBack,
    required this.onCatalog,
    required this.onSettings,
    this.onAutoScroll,
  });
  final String title;
  final VoidCallback onBack, onCatalog, onSettings;
  final VoidCallback? onAutoScroll;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          ReaderControlSurface(
            child: AppIconButton(
              tooltip: '返回',
              onPressed: onBack,
              icon: Icon(
                usesAppleGlass ? CupertinoIcons.chevron_back : Icons.arrow_back,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ReaderControlSurface(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ReaderControlSurface(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconButton(
                  tooltip: '目录',
                  onPressed: onCatalog,
                  icon: Icon(
                    usesAppleGlass
                        ? CupertinoIcons.list_bullet
                        : Icons.format_list_bulleted,
                  ),
                ),
                if (onAutoScroll != null)
                  AppIconButton(
                    tooltip: '自动滚动',
                    onPressed: onAutoScroll,
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                AppIconButton(
                  tooltip: '阅读设置',
                  onPressed: onSettings,
                  icon: Icon(
                    usesAppleGlass
                        ? CupertinoIcons.gear
                        : Icons.settings_outlined,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class ReaderControlSurface extends StatelessWidget {
  const ReaderControlSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? AppleGlassSurface(capsule: true, child: child)
          : Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            elevation: 2,
            shadowColor: Colors.black26,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: child,
          );
}

/// Preview while dragging; only the final release seeks the reader.
/// A chapter/session change invalidates an in-flight scrub.
class ReaderPageScrubber extends StatefulWidget {
  const ReaderPageScrubber({
    super.key,
    required this.index,
    required this.count,
    required this.revision,
    required this.onSeek,
    this.label = '本章',
  });
  final int index, count;
  final Object revision;
  final ValueChanged<int> onSeek;
  final String label;
  @override
  State<ReaderPageScrubber> createState() => _ReaderPageScrubberState();
}

class _ReaderPageScrubberState extends State<ReaderPageScrubber> {
  double? _draft;
  Object? _scrubRevision;
  @override
  void didUpdateWidget(ReaderPageScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision ||
        widget.count != oldWidget.count) {
      _draft = null;
      _scrubRevision = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = (widget.count - 1).clamp(0, 1 << 30);
    final value = (_draft ?? widget.index.toDouble()).clamp(
      0.0,
      last.toDouble(),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        child: ReaderControlSurface(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: '${widget.label}跳转书页',
                  child: AppSlider(
                    key: const ValueKey('reader-page-scrubber'),
                    min: 0,
                    max: last > 0 ? last.toDouble() : 1,
                    interactionRevision: widget.revision,
                    value: value,
                    onChangeCancel:
                        () => setState(() {
                          _draft = null;
                          _scrubRevision = null;
                        }),
                    onChangeStart: (_) => _scrubRevision = widget.revision,
                    onChanged:
                        last > 0 ? (v) => setState(() => _draft = v) : null,
                    onChangeEnd: (v) {
                      final valid = _scrubRevision == widget.revision;
                      setState(() {
                        _draft = null;
                        _scrubRevision = null;
                      });
                      if (valid) widget.onSeek(v.round().clamp(0, last));
                    },
                  ),
                ),
                Text(
                  '${widget.label} ${value.round() + 1}/${widget.count.clamp(1, 1 << 30)}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

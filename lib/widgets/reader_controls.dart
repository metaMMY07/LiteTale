import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/material_control_motion.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_speech_scope.dart';

/// Moves the reader controls over the paper without resizing the viewport.
class ReaderMenuMotion extends StatefulWidget {
  const ReaderMenuMotion({
    super.key,
    required this.visible,
    required this.child,
    this.fromBottom = false,
  });

  final bool visible;
  final Widget child;
  final bool fromBottom;

  @override
  State<ReaderMenuMotion> createState() => _ReaderMenuMotionState();
}

class _ReaderMenuMotionState extends State<ReaderMenuMotion> {
  late bool _hasOpened = widget.visible;

  @override
  void didUpdateWidget(ReaderMenuMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hasOpened = _hasOpened || widget.visible;
  }

  @override
  Widget build(BuildContext context) {
    final exit = ReaderSpeechScope.exitOf(context);
    if (!usesAppleGlass && exit == null) {
      return widget.visible ? widget.child : const SizedBox.shrink();
    }
    final target = widget.visible ? 1.0 : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: target, end: target),
      duration:
          MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : readerMenuMotionDuration,
      curve: Curves.easeInOutCubic,
      child: _hasOpened ? widget.child : const SizedBox.shrink(),
      builder:
          (context, progress, child) => AnimatedBuilder(
            animation: exit ?? kAlwaysDismissedAnimation,
            child: child,
            builder: (context, child) {
              final departing = Curves.easeInOutCubic.transform(
                exit?.value ?? 0,
              );
              final inactive = !widget.visible || exit != null;
              return Offstage(
                offstage: (!widget.visible && progress == 0) || departing == 1,
                child: IgnorePointer(
                  ignoring: inactive,
                  child: ExcludeSemantics(
                    excluding: inactive,
                    child: ExcludeFocus(
                      excluding: inactive,
                      child: FractionalTranslation(
                        translation: Offset(
                          0,
                          widget.fromBottom
                              ? (1 - progress) * .55 + departing * 1.5
                              : -(1 - progress) - departing * 1.5,
                        ),
                        child:
                            widget.fromBottom
                                ? Opacity(
                                  opacity: progress * (1 - departing),
                                  child: child,
                                )
                                : child,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }
}

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
          ReaderRoundAction(
            key: const ValueKey('reader-catalog'),
            label: '目录',
            onPressed: onCatalog,
            motion: MaterialReaderMotion.catalog,
            icon:
                usesAppleGlass
                    ? CupertinoIcons.list_bullet
                    : Icons.format_list_bulleted,
          ),
          if (onAutoScroll != null) ...[
            const SizedBox(width: 8),
            ReaderRoundAction(
              label: '自动滚动',
              onPressed: onAutoScroll,
              icon:
                  usesAppleGlass
                      ? CupertinoIcons.play_fill
                      : Icons.play_arrow_rounded,
            ),
          ],
          const SizedBox(width: 8),
          ReaderRoundAction(
            key: const ValueKey('reader-settings'),
            label: '阅读设置',
            onPressed: onSettings,
            motion: MaterialReaderMotion.settings,
            icon:
                usesAppleGlass ? CupertinoIcons.gear : Icons.settings_outlined,
          ),
          if (ReaderSpeechScope.actionOf(context) case (
            visible: true,
            :final open,
          )) ...[
            const SizedBox(width: 8),
            ReaderRoundAction(
              key: const ValueKey('reader-speech'),
              label: '听书',
              onPressed: open,
              icon:
                  usesAppleGlass
                      ? CupertinoIcons.headphones
                      : Icons.headphones_outlined,
            ),
          ],
        ],
      ),
    ),
  );
}

/// Square constraints make the native glass capsule a true circle.
class ReaderRoundAction extends StatelessWidget {
  const ReaderRoundAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.size = 48,
    this.selected = false,
    this.motion,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool selected;
  final MaterialReaderMotion? motion;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child:
        usesAppleGlass
            ? AppleGlassSurface(
              capsule: true,
              child: Semantics(
                selected: selected,
                child: SizedBox.expand(
                  child: AppIconButton(
                    tooltip: label,
                    padding: EdgeInsets.zero,
                    onPressed: onPressed,
                    icon: Icon(icon),
                  ),
                ),
              ),
            )
            : motion != null &&
                Theme.of(context).platform == TargetPlatform.android
            ? MaterialReaderMotionButton(
              motion: motion!,
              label: label,
              onPressed: onPressed,
            )
            : IconButton.filledTonal(
              tooltip: label,
              style: IconButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
              ),
              isSelected: selected,
              icon: Icon(icon),
              onPressed: onPressed,
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
    this.active = true,
    this.embedded = false,
    this.unit = '',
  });
  final int index, count;
  final Object revision;
  final ValueChanged<int> onSeek;
  final String label;
  final bool active;
  final bool embedded;
  final String unit;
  @override
  State<ReaderPageScrubber> createState() => _ReaderPageScrubberState();
}

class _ReaderPageScrubberState extends State<ReaderPageScrubber> {
  double? _draft;
  int _interactionRevision = 0;
  bool _dragging = false;

  void _resetDrag() {
    _draft = null;
    _dragging = false;
  }

  @override
  void didUpdateWidget(ReaderPageScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision ||
        widget.count != oldWidget.count ||
        widget.active != oldWidget.active) {
      _interactionRevision++;
      _resetDrag();
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = (widget.count - 1).clamp(0, 1 << 30);
    final canScrub = widget.active && last > 0;
    final value = (_draft ?? widget.index.toDouble()).clamp(
      0.0,
      last.toDouble(),
    );
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: widget.unit == '段' ? '跳转段落' : '${widget.label}跳转书页',
            child: AppSlider(
              key: const ValueKey('reader-page-scrubber'),
              min: 0,
              max: last > 0 ? last.toDouble() : 1,
              interactionRevision: _interactionRevision,
              value: value,
              onChangeCancel: () => setState(_resetDrag),
              onChangeStart: (_) => _dragging = canScrub,
              onChanged: canScrub ? (v) => setState(() => _draft = v) : null,
              onChangeEnd: (v) {
                final valid = widget.active && _dragging;
                setState(_resetDrag);
                if (valid) widget.onSeek(v.round().clamp(0, last));
              },
            ),
          ),
          Text(
            '${widget.label} ${value.round() + 1}/${widget.count.clamp(1, 1 << 30)}${widget.unit}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
    if (widget.embedded) return content;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        child: ReaderControlSurface(child: content),
      ),
    );
  }
}

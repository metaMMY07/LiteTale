import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/material_control_motion.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_speech_scope.dart';
import 'package:wild/widgets/wavy_slider_track_shape.dart';

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
    if (!usesAppleGlass &&
        Theme.of(context).platform != TargetPlatform.android &&
        exit == null) {
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
                        child: child,
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
  Widget build(BuildContext context) {
    final apple = usesAppleGlass;
    final trailingIconColor =
        apple ? Theme.of(context).colorScheme.onSurface : null;
    final trailingActions = <Widget>[
      ReaderRoundAction(
        key: const ValueKey('reader-catalog'),
        label: '目录',
        size: apple ? 44 : 48,
        grouped: apple,
        color: trailingIconColor,
        onPressed: onCatalog,
        motion: MaterialReaderMotion.catalog,
        icon:
            apple ? CupertinoIcons.list_bullet : Icons.format_list_bulleted,
      ),
      if (onAutoScroll != null) ...[
        if (!apple) const SizedBox(width: 8),
        ReaderRoundAction(
          label: '自动滚动',
          size: apple ? 44 : 48,
          grouped: apple,
          color: trailingIconColor,
          onPressed: onAutoScroll,
          icon: apple ? CupertinoIcons.play_fill : Icons.play_arrow_rounded,
        ),
      ],
      if (!apple) const SizedBox(width: 8),
      ReaderRoundAction(
        key: const ValueKey('reader-settings'),
        label: '阅读设置',
        size: apple ? 44 : 48,
        grouped: apple,
        color: trailingIconColor,
        onPressed: onSettings,
        motion: MaterialReaderMotion.settings,
        icon: apple ? CupertinoIcons.gear : Icons.settings_outlined,
      ),
      if (ReaderSpeechScope.actionOf(context) case (
        visible: true,
        :final open,
      )) ...[
        if (!apple) const SizedBox(width: 8),
        ReaderRoundAction(
          key: const ValueKey('reader-speech'),
          label: '听书',
          size: apple ? 44 : 48,
          grouped: apple,
          color: trailingIconColor,
          onPressed: open,
          icon: apple ? CupertinoIcons.headphones : Icons.headphones_outlined,
        ),
      ],
    ];
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            if (apple)
              IosReaderBackButton(onPressed: onBack)
            else
              ReaderControlSurface(
                child: AppIconButton(
                  tooltip: '返回',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: ReaderControlSurface(
                child: SizedBox(
                  height: apple ? 44 : null,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: apple ? 0 : 14,
                    ),
                    child: Align(
                      alignment: Alignment.center,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: apple ? 15 : 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (apple)
              AppleGlassSurface(
                capsule: true,
                interactive: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: trailingActions,
                  ),
                ),
              )
            else
              ...trailingActions,
          ],
        ),
      ),
    );
  }
}

class IosReaderBackButton extends StatelessWidget {
  const IosReaderBackButton({
    super.key,
    required this.onPressed,
    this.label = '返回',
  });

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) => ReaderRoundAction(
    label: label,
    icon: CupertinoIcons.chevron_back,
    size: 44,
    color: Theme.of(context).colorScheme.onSurface,
    onPressed: onPressed,
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
    this.grouped = false,
    this.motion,
    this.color,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool selected;
  final bool grouped;
  final MaterialReaderMotion? motion;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final appleButton = Semantics(
      selected: selected,
      child: SizedBox.expand(
        child: AppIconButton(
          tooltip: label,
          padding: EdgeInsets.zero,
          color: color,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child:
          usesAppleGlass
              ? grouped
                  ? appleButton
                  : AppleGlassSurface(
                    capsule: true,
                    interactive: onPressed != null,
                    child: appleButton,
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
                isSelected:
                    !selected &&
                            Theme.of(context).platform == TargetPlatform.android
                        ? null
                        : selected,
                icon: Icon(icon),
                onPressed: onPressed,
              ),
    );
  }
}

class ReaderControlSurface extends StatelessWidget {
  const ReaderControlSurface({
    super.key,
    required this.child,
    this.capsule = true,
    this.borderRadius = 24,
  });
  final Widget child;
  final bool capsule;
  final double borderRadius;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? AppleGlassSurface(
            capsule: capsule,
            borderRadius: borderRadius,
            child: child,
          )
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
    this.wavy = false,
    this.wavePlaying = false,
    this.activeColor,
  });
  final int index, count;
  final Object revision;
  final ValueChanged<int> onSeek;
  final String label;
  final bool active;
  final bool embedded;
  final String unit;
  final bool wavy;
  final bool wavePlaying;
  final Color? activeColor;
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
    Widget slider = AppSlider(
      key: const ValueKey('reader-page-scrubber'),
      min: 0,
      max: last > 0 ? last.toDouble() : 1,
      interactionRevision: _interactionRevision,
      value: value,
      activeColor: widget.activeColor,
      onChangeCancel: () => setState(_resetDrag),
      onChangeStart: (_) => _dragging = canScrub,
      onChanged: canScrub ? (v) => setState(() => _draft = v) : null,
      onChangeEnd: (v) {
        final valid = widget.active && _dragging;
        setState(_resetDrag);
        if (valid) widget.onSeek(v.round().clamp(0, last));
      },
    );
    if (widget.wavy) {
      slider = WavySlider(
        flowing: widget.wavePlaying && widget.active,
        child: slider,
      );
    }
    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        widget.embedded ? 12 : 14,
        widget.embedded ? 6 : 4,
        widget.embedded ? 12 : 14,
        widget.embedded ? 10 : 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: widget.unit == '段' ? '跳转段落' : '${widget.label}跳转书页',
            child: slider,
          ),
          Text(
            '${widget.label} ${value.round() + 1}/${widget.count.clamp(1, 1 << 30)}${widget.unit}',
            style:
                widget.embedded && usesAppleGlass
                    ? Theme.of(context).textTheme.labelLarge
                    : Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
    if (widget.embedded) return content;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: ReaderControlSurface(
          capsule: false,
          borderRadius: 24,
          child: content,
        ),
      ),
    );
  }
}

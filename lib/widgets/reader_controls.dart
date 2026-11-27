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

Brightness _readerBarBrightness(BuildContext context) {
  final paperBg = Scaffold.maybeOf(context)?.widget.backgroundColor;
  if (paperBg != null) return ThemeData.estimateBrightnessForColor(paperBg);
  return Theme.of(context).brightness;
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

  static const double iosBarHeight = 44;

  @override
  Widget build(BuildContext context) {
    final apple = usesAppleGlass;
    final barBrightness = _readerBarBrightness(context);
    final neutralColor =
        barBrightness == Brightness.dark ? Colors.white : Colors.black;
    final speech = ReaderSpeechScope.actionOf(context);
    final trailingActions = <Widget>[
      ReaderRoundAction(
        key: const ValueKey('reader-catalog'),
        label: '目录',
        size: apple ? iosBarHeight : 48,
        iconSize: apple ? AppleGlassActions.defaultIconSize : null,
        grouped: apple,
        color: apple ? neutralColor : null,
        onPressed: onCatalog,
        motion: MaterialReaderMotion.catalog,
        icon: apple ? CupertinoIcons.list_bullet : Icons.format_list_bulleted,
      ),
      if (onAutoScroll != null) ...[
        if (!apple) const SizedBox(width: 8),
        ReaderRoundAction(
          label: '自动滚动',
          size: apple ? iosBarHeight : 48,
          iconSize: apple ? AppleGlassActions.defaultIconSize : null,
          grouped: apple,
          color: apple ? neutralColor : null,
          onPressed: onAutoScroll,
          icon: apple ? CupertinoIcons.play_fill : Icons.play_arrow_rounded,
        ),
      ],
      if (!apple) const SizedBox(width: 8),
      ReaderRoundAction(
        key: const ValueKey('reader-settings'),
        label: '阅读设置',
        size: apple ? iosBarHeight : 48,
        iconSize: apple ? AppleGlassActions.defaultIconSize : null,
        grouped: apple,
        color: apple ? neutralColor : null,
        onPressed: onSettings,
        motion: MaterialReaderMotion.settings,
        icon: apple ? CupertinoIcons.gear : Icons.settings_outlined,
      ),
      if (speech case (visible: true, :final open)) ...[
        if (!apple) const SizedBox(width: 8),
        ReaderRoundAction(
          key: const ValueKey('reader-speech'),
          label: '听书',
          size: apple ? iosBarHeight : 48,
          iconSize: apple ? AppleGlassActions.defaultIconSize : null,
          grouped: apple,
          color:
              apple
                  ? (open == null
                      ? neutralColor.withValues(alpha: .35)
                      : neutralColor)
                  : null,
          onPressed: open,
          icon: apple ? CupertinoIcons.headphones : Icons.headphones_outlined,
        ),
      ],
    ];
    final titleChild =
        apple
            ? SizedBox(
              key: const ValueKey('reader-title-capsule'),
              height: iosBarHeight,
              child: ReaderControlSurface(
                brightness: barBrightness,
                keepGlassInSheets: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      textScaler: MediaQuery.textScalerOf(
                        context,
                      ).clamp(maxScaleFactor: 1.2),
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: neutralColor,
                      ),
                    ),
                  ),
                ),
              ),
            )
            : ReaderControlSurface(
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
            );
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (apple)
              IosReaderBackButton(
                onPressed: onBack,
                color: neutralColor,
                brightness: barBrightness,
                keepGlassInSheets: true,
              )
            else
              ReaderControlSurface(
                child: AppIconButton(
                  tooltip: '返回',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(child: titleChild),
            const SizedBox(width: 10),
            if (apple)
              AppleGlassActions(
                key: const ValueKey('reader-trailing-capsule'),
                brightness: barBrightness,
                keepGlassInSheets: true,
                actions: [
                  AppleGlassAction(
                    id: 'catalog',
                    label: '目录',
                    symbol: 'list.bullet',
                    fallbackIcon: CupertinoIcons.list_bullet,
                    onPressed: onCatalog,
                  ),
                  if (onAutoScroll != null)
                    AppleGlassAction(
                      id: 'auto-scroll',
                      label: '自动滚动',
                      symbol: 'play.fill',
                      fallbackIcon: CupertinoIcons.play_fill,
                      onPressed: onAutoScroll,
                    ),
                  AppleGlassAction(
                    id: 'settings',
                    label: '阅读设置',
                    symbol: 'gearshape',
                    fallbackIcon: CupertinoIcons.gear,
                    onPressed: onSettings,
                  ),
                  if (speech case (visible: true, :final open))
                    AppleGlassAction(
                      id: 'speech',
                      label: '听书',
                      symbol: 'headphones',
                      fallbackIcon: CupertinoIcons.headphones,
                      onPressed: open,
                    ),
                ],
                fallback: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: trailingActions,
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
    this.color,
    this.brightness,
    this.keepGlassInSheets = false,
  });

  static const double iosIconSize = 24;

  final VoidCallback onPressed;
  final String label;
  final Color? color;
  final Brightness? brightness;
  final bool keepGlassInSheets;

  @override
  Widget build(BuildContext context) => ReaderRoundAction(
    label: label,
    icon: CupertinoIcons.chevron_back,
    iconSize: iosIconSize,
    symbol: 'chevron.left',
    useIconGlyphInGlass: true,
    size: 44,
    color: color ?? Theme.of(context).colorScheme.onSurface,
    brightness: brightness,
    keepGlassInSheets: keepGlassInSheets,
    onPressed: onPressed,
  );
}

/// Square constraints make the native glass capsule a true circle.
class ReaderRoundAction extends StatelessWidget {
  const ReaderRoundAction({
    super.key,
    required this.label,
    required this.icon,
    this.iconSize,
    this.symbol,
    this.useIconGlyphInGlass = false,
    required this.onPressed,
    this.size = 48,
    this.selected = false,
    this.grouped = false,
    this.tint,
    this.preserveTint = false,
    this.brightness,
    this.motion,
    this.color,
    this.keepGlassInSheets = false,
  });
  final String label;
  final IconData icon;
  final double? iconSize;
  final String? symbol;
  final bool useIconGlyphInGlass;
  final VoidCallback? onPressed;
  final double size;
  final bool selected;
  final bool grouped;
  final Color? tint;
  final bool preserveTint;
  final Brightness? brightness;
  final MaterialReaderMotion? motion;
  final Color? color;
  final bool keepGlassInSheets;

  @override
  Widget build(BuildContext context) {
    final appleButton = Semantics(
      selected: selected,
      child: SizedBox.expand(
        child: AppIconButton(
          tooltip: label,
          padding: EdgeInsets.zero,
          color: color,
          iconSize: iconSize,
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
                  : symbol != null
                  ? AppleGlassButton(
                    label: label,
                    symbol: symbol,
                    glyph: useIconGlyphInGlass ? icon : null,
                    glyphSize: iconSize ?? 24,
                    onPressed: onPressed,
                    foreground: color,
                    brightness: brightness,
                    tint: preserveTint ? tint : null,
                    selected: selected,
                    keepGlassInSheets: keepGlassInSheets,
                    fallback: appleButton,
                  )
                  : AppleGlassSurface(
                    capsule: true,
                    tint: tint,
                    preserveTint: preserveTint,
                    brightness: brightness,
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
    this.brightness,
    this.keepGlassInSheets = false,
  });
  final Widget child;
  final Brightness? brightness;
  final bool keepGlassInSheets;
  @override
  Widget build(BuildContext context) =>
      usesAppleGlass
          ? AppleGlassSurface(
            capsule: true,
            brightness: brightness,
            keepGlassInSheets: keepGlassInSheets,
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
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
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
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        child: ReaderControlSurface(child: content),
      ),
    );
  }
}

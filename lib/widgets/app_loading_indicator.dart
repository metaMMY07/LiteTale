import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:wild/widgets/expressive_loading_indicator.dart';

/// A regular circular spinner using the surrounding surface's theme color.
class AppLoadingIndicator extends StatelessWidget {
  const AppLoadingIndicator({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return ExpressiveLoadingIndicator(size: size ?? 48, color: color);
    }
    final extent = size ?? 32;
    final theme = Theme.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      label: '正在加载',
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: extent,
            child: CircularProgressIndicator(
              color:
                  color ??
                  theme.progressIndicatorTheme.color ??
                  theme.colorScheme.primary,
              strokeWidth: extent <= 24 ? 2 : 2.5,
              // Keep the regular ring even if a parent opts into new shapes.
              // ignore: deprecated_member_use
              year2023: true,
              value: reduceMotion ? 0.75 : null,
            ),
          ),
        ),
      ),
    );
  }
}

class CenteredLoadingIndicator extends StatelessWidget {
  const CenteredLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: AppLoadingIndicator());
}

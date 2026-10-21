import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:wild/models/reader_page.dart';
import 'package:wild/services/reader_rich_typography.dart';

/// Paint the same measured paragraph used to cut rich pages, without relying
/// on a second HTML renderer with different font metrics or line wrapping.
class ReaderStyledParagraph extends LeafRenderObjectWidget {
  const ReaderStyledParagraph({
    super.key,
    required this.fragment,
    required this.style,
    required this.textScaler,
  });
  final ReaderFragment fragment;
  final TextStyle style;
  final TextScaler textScaler;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _StyledParagraphBox(fragment, style, textScaler);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderBox renderObject,
  ) =>
      (renderObject as _StyledParagraphBox).update(fragment, style, textScaler);
}

class _StyledParagraphBox extends RenderBox {
  _StyledParagraphBox(this._fragment, this._style, this._scaler);
  ReaderFragment _fragment;
  TextStyle _style;
  TextScaler _scaler;
  ReaderParagraphLayout? _layout;

  void update(ReaderFragment fragment, TextStyle style, TextScaler scaler) {
    if (fragment == _fragment && style == _style && scaler == _scaler) return;
    _fragment = fragment;
    _style = style;
    _scaler = scaler;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  void performLayout() {
    _layout?.dispose();
    _layout = ReaderParagraphLayout(
      fragment: _fragment,
      baseStyle: _style,
      width: constraints.maxWidth,
      textScaler: _scaler,
    );
    size = constraints.constrain(
      Size(
        constraints.maxWidth,
        _layout!.height + _fragment.gapBefore + _fragment.gapAfter,
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      _layout?.paint(context.canvas, offset + Offset(0, _fragment.gapBefore));

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isSemanticBoundary = true;
    config.label = _fragment.text;
    config.textDirection = TextDirection.ltr;
  }

  @override
  void dispose() {
    _layout?.dispose();
    super.dispose();
  }
}

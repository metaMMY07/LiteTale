import 'package:flutter/material.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/book_cover_image.dart';

typedef ShelfCover = ({String url, SourceId source});

class BookshelfTile extends StatelessWidget {
  const BookshelfTile({
    super.key,
    required this.title,
    required this.cover,
    this.folder = false,
    this.showSource = false,
    this.sourceLabel,
    this.unreadCount,
    this.selected = false,
    this.onTap,
  });

  final String title;
  final Widget cover;
  final bool folder, showSource, selected;
  final String? sourceLabel;
  final int? unreadCount;
  final VoidCallback? onTap;

  static double captionHeight(BuildContext context, bool showSource) {
    final scale = MediaQuery.textScalerOf(context);
    final title = (scale.scale(12) * 1.25).ceilToDouble() * 2;
    final source = (scale.scale(10) * 1.25).ceilToDouble();
    return 6 + title + (showSource ? 2 + source : 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = unreadCount ?? 0;
    final radius = BorderRadius.circular(10);
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: radius,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      cover,
                      PositionedDirectional(
                        bottom: 1,
                        end: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                          child: SizedBox.square(
                            dimension: 23,
                            child: ShelfIcon(
                              folder ? ShelfSymbol.folder : ShelfSymbol.book,
                              size: 15,
                              color: colors.onPrimary,
                            ),
                          ),
                        ),
                      ),
                      if (count > 0)
                        Positioned(
                          top: 0,
                          left: 0,
                          child: _UnreadCorner(count),
                        ),
                      if (selected)
                        ColoredBox(
                          color: colors.primary.withValues(alpha: .66),
                          child: ShelfIcon(
                            ShelfSymbol.check,
                            color: colors.onPrimary,
                            size: 34,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: captionHeight(context, showSource),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 12, height: 1.25),
                        ),
                      ),
                      if (showSource && sourceLabel != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          sourceLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.25,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BookshelfBookCover extends StatelessWidget {
  const BookshelfBookCover(this.image, {super.key});

  final ShelfCover image;

  @override
  Widget build(BuildContext context) => BookCoverImage(
    url: image.url,
    source: image.source,
    width: double.infinity,
    height: double.infinity,
    preferPaintedSize: true,
  );
}

class BookshelfFolderCover extends StatelessWidget {
  const BookshelfFolderCover(this.previews, {super.key});

  final List<ShelfCover> previews;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainer,
      child:
          previews.isEmpty
              ? ShelfIcon(
                ShelfSymbol.openFolder,
                size: 56,
                color: colors.primary,
              )
              : Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    for (var row = 0; row < 2; row++) ...[
                      if (row > 0) const SizedBox(height: 4),
                      Expanded(
                        child: Row(
                          children: [
                            for (var col = 0; col < 2; col++) ...[
                              if (col > 0) const SizedBox(width: 4),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(5),
                                  child:
                                      row * 2 + col < previews.length
                                          ? BookshelfBookCover(
                                            previews[row * 2 + col],
                                          )
                                          : ColoredBox(
                                            color: colors.surfaceContainerHigh,
                                          ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
    );
  }
}

class _UnreadCorner extends StatelessWidget {
  const _UnreadCorner(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '未读 $count 章',
      excludeSemantics: true,
      child: IgnorePointer(
        child: ClipPath(
          clipper: const _CornerTriangle(),
          child: ColoredBox(
            color: colors.primary,
            child: SizedBox.square(
              dimension: count > 99 ? 51 : 39,
              child: Padding(
                padding: const EdgeInsets.only(top: 7, left: 8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    count > 999 ? '999+' : '$count',
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CornerTriangle extends CustomClipper<Path> {
  const _CornerTriangle();

  @override
  Path getClip(Size size) =>
      Path()
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close();

  @override
  bool shouldReclip(_CornerTriangle oldClipper) => false;
}

enum ShelfSymbol { openFolder, folder, book, check, root }

class ShelfIcon extends StatelessWidget {
  const ShelfIcon(
    this.symbol, {
    super.key,
    required this.size,
    required this.color,
  });

  final ShelfSymbol symbol;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (usesAppleGlass) {
      return Center(
        widthFactor: 1,
        heightFactor: 1,
        child: CustomPaint(
          size: Size.square(size),
          painter: _ShelfSymbolPainter(symbol, color),
        ),
      );
    }
    return Icon(
      switch (symbol) {
        ShelfSymbol.openFolder => Icons.folder_open_rounded,
        ShelfSymbol.folder => Icons.folder_outlined,
        ShelfSymbol.book => Icons.menu_book_outlined,
        ShelfSymbol.check => Icons.check_rounded,
        ShelfSymbol.root => Icons.home_outlined,
      },
      size: size,
      color: color,
    );
  }
}

// Tabler Icons, copyright (c) 2020-2024 Paweł Kuna, MIT.
// The outline paths below use the original 24-point coordinate space.
class _ShelfSymbolPainter extends CustomPainter {
  const _ShelfSymbolPainter(this.symbol, this.color);

  final ShelfSymbol symbol;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const r1 = Radius.circular(1);
    const r2 = Radius.circular(2);
    final path = Path();
    switch (symbol) {
      case ShelfSymbol.openFolder:
        path
          ..moveTo(5, 19)
          ..relativeLineTo(2.757, -7.351)
          ..relativeArcToPoint(const Offset(.936, -.649), radius: r1)
          ..relativeLineTo(12.307, 0)
          ..relativeArcToPoint(const Offset(.986, 1.164), radius: r1)
          ..relativeLineTo(-.996, 5.211)
          ..relativeArcToPoint(const Offset(-1.964, 1.625), radius: r2)
          ..relativeLineTo(-14.026, 0)
          ..relativeArcToPoint(const Offset(-2, -2), radius: r2)
          ..relativeLineTo(0, -11)
          ..relativeArcToPoint(const Offset(2, -2), radius: r2)
          ..relativeLineTo(4, 0)
          ..relativeLineTo(3, 3)
          ..relativeLineTo(7, 0)
          ..relativeArcToPoint(const Offset(2, 2), radius: r2)
          ..relativeLineTo(0, 2);
      case ShelfSymbol.folder:
        path
          ..moveTo(5, 4)
          ..lineTo(9, 4)
          ..lineTo(12, 7)
          ..lineTo(19, 7)
          ..arcToPoint(const Offset(21, 9), radius: r2)
          ..lineTo(21, 17)
          ..arcToPoint(const Offset(19, 19), radius: r2)
          ..lineTo(5, 19)
          ..arcToPoint(const Offset(3, 17), radius: r2)
          ..lineTo(3, 6)
          ..arcToPoint(const Offset(5, 4), radius: r2)
          ..close();
      case ShelfSymbol.book:
        path
          ..moveTo(19, 4)
          ..lineTo(19, 20)
          ..lineTo(7, 20)
          ..arcToPoint(const Offset(5, 18), radius: r2)
          ..lineTo(5, 6)
          ..arcToPoint(const Offset(7, 4), radius: r2)
          ..close()
          ..moveTo(19, 16)
          ..lineTo(7, 16)
          ..arcToPoint(const Offset(5, 18), radius: r2, clockwise: false)
          ..moveTo(9, 8)
          ..lineTo(15, 8);
      case ShelfSymbol.check:
        path
          ..moveTo(5, 12)
          ..lineTo(10, 17)
          ..lineTo(20, 7);
      case ShelfSymbol.root:
        path
          ..moveTo(5, 12)
          ..lineTo(3, 12)
          ..lineTo(12, 3)
          ..lineTo(21, 12)
          ..lineTo(19, 12)
          ..moveTo(5, 12)
          ..lineTo(5, 19)
          ..arcToPoint(const Offset(7, 21), radius: r2, clockwise: false)
          ..lineTo(17, 21)
          ..arcToPoint(const Offset(19, 19), radius: r2, clockwise: false)
          ..lineTo(19, 12)
          ..moveTo(9, 21)
          ..lineTo(9, 15)
          ..arcToPoint(const Offset(11, 13), radius: r2)
          ..lineTo(13, 13)
          ..arcToPoint(const Offset(15, 15), radius: r2)
          ..lineTo(15, 21);
    }
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = switch (symbol) {
          ShelfSymbol.openFolder => 1.7,
          ShelfSymbol.check => 2.5,
          _ => 2,
        }
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShelfSymbolPainter oldDelegate) =>
      symbol != oldDelegate.symbol || color != oldDelegate.color;
}

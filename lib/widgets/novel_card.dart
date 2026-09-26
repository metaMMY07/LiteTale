import 'package:flutter/material.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/widgets/cached_image.dart';
import 'package:wild/src/rust/wenku8/models.dart';

class NovelCard extends StatelessWidget {
  final String title;
  final String coverUrl;
  final String? author;
  final VoidCallback? onTap;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final double elevation;
  final EdgeInsetsGeometry? padding;
  final bool showAuthor;
  final SourceId source;

  const NovelCard({
    super.key,
    required this.title,
    required this.coverUrl,
    this.author,
    this.onTap,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.elevation = 0.5,
    this.padding,
    this.showAuthor = true,
    required this.source,
  });

  factory NovelCard.fromNovel({
    required Novel novel,
    VoidCallback? onTap,
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
    BorderRadius? borderRadius,
    double elevation = 0.5,
    EdgeInsetsGeometry? padding,
    bool showAuthor = true,
    required SourceId source,
  }) {
    return NovelCard(
      title: novel.title,
      coverUrl: novel.coverUrl,
      author: novel.author,
      onTap: onTap,
      width: width,
      height: height,
      fit: fit,
      borderRadius: borderRadius,
      elevation: usesMaterialYou ? 0 : elevation,
      padding: padding,
      showAuthor: showAuthor,
      source: source,
    );
  }

  factory NovelCard.fromNovelCover({
    required NovelCover novel,
    VoidCallback? onTap,
    double? width,
    double? height,
    BoxFit fit = BoxFit.cover,
    BorderRadius? borderRadius,
    double elevation = 0.5,
    EdgeInsetsGeometry? padding,
    bool showAuthor = false,
    required SourceId source,
  }) {
    return NovelCard(
      title: novel.title,
      coverUrl: novel.img,
      onTap: onTap,
      width: width,
      height: height,
      fit: fit,
      borderRadius: borderRadius,
      elevation: elevation,
      padding: padding,
      showAuthor: showAuthor,
      source: source,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardRadius =
        borderRadius ?? BorderRadius.circular(usesMaterialYou ? 16 : 4);
    final logicalCoverWidth =
        width != null && width!.isFinite && width! > 0 ? width! : 220.0;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: elevation,
      shape: RoundedRectangleBorder(borderRadius: cardRadius),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: CachedImage(
                url: coverUrl,
                source: source,
                fit: fit,
                width: width ?? double.infinity,
                height: height,
                cacheWidth:
                    (logicalCoverWidth * MediaQuery.devicePixelRatioOf(context))
                        .ceil(),
              ),
            ),
            Padding(
              padding: padding ?? EdgeInsets.all(usesMaterialYou ? 10 : 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: showAuthor ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: showAuthor ? null : 12,
                      fontWeight:
                          showAuthor ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                  if (showAuthor && author != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

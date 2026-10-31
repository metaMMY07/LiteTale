import 'package:flutter/material.dart';
import 'apple_book_cover.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/cached_image.dart';

class NovelCoverCard extends StatelessWidget {
  final NovelCover novel;

  const NovelCoverCard({super.key, required this.novel});

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return AppleBookCover(
        title: novel.title,
        url: novel.img,
        source: sourceOf(novel.aid),
        onTap:
            () => Navigator.pushNamed(
              context,
              '/novel/info',
              arguments: novel.aid,
            ),
      );
    }
    final cardRadius = BorderRadius.circular(usesMaterialYou ? 24 : 4);
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: usesMaterialYou ? 0 : .5,
      shape: RoundedRectangleBorder(borderRadius: cardRadius),
      child: InkWell(
        onTap:
            () => Navigator.pushNamed(
              context,
              '/novel/info',
              arguments: novel.aid,
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CachedImage(
                url: novel.img,
                source: sourceOf(novel.aid),
                width: double.infinity,
                fit: BoxFit.cover,
                cacheWidth:
                    (220 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(usesMaterialYou ? 10 : 4),
              child: SizedBox(
                height:
                    usesMaterialYou
                        ? MediaQuery.textScalerOf(context).scale(13) * 2.8
                        : null,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    novel.title,
                    maxLines: usesMaterialYou ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: usesMaterialYou ? 13 : 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/cached_image.dart';

class NovelCoverCard extends StatelessWidget {
  final NovelCover novel;

  const NovelCoverCard({super.key, required this.novel});

  @override
  Widget build(BuildContext context) {
    final cardRadius = BorderRadius.circular(usesMaterialYou ? 16 : 4);
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
          ],
        ),
      ),
    );
  }
}

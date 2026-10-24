import 'package:flutter/material.dart';
import '../sources/book_source.dart';
import 'cached_image.dart';

/// Every item reserves the same two title lines, even for a one-line title.
class AppleBookCover extends StatelessWidget {
  const AppleBookCover({
    super.key,
    required this.title,
    required this.url,
    required this.source,
    this.onTap,
    this.author,
    this.showAuthor = false,
  });
  final String title, url;
  final SourceId source;
  final VoidCallback? onTap;
  final String? author;
  final bool showAuthor;
  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final captionHeight =
        scaler.scale(14) * 1.3 * 2 +
        10 +
        (!showAuthor ? 0 : scaler.scale(12) * 1.3 + 4);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              key: const ValueKey('book-cover-frame'),
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder:
                    (context, box) => CachedImage(
                      url: url,
                      source: source,
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      cacheWidth:
                          (box.maxWidth *
                                  MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                    ),
              ),
            ),
          ),
          SizedBox(
            height: captionHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 7, 2, 3),
              child: Column(
                children: [
                  SizedBox(
                    height: scaler.scale(14) * 1.3 * 2,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  if (showAuthor) ...[
                    const SizedBox(height: 4),
                    Text(
                      author ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

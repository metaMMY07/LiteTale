import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/home/recommend_page.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/novel_cover_card.dart';

void main() {
  testWidgets('recommendations only build covers near the scroll viewport', (
    tester,
  ) async {
    final books = List.generate(
      100,
      (index) => NovelCover(
        title: 'Book $index',
        img: '',
        detailUrl: '',
        aid: '$index',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendationFeed(
            blocks: [HomeBlock(title: 'Books', list: books)],
          ),
        ),
      ),
    );

    expect(find.text('Books'), findsOneWidget);
    expect(find.byType(NovelCoverCard).evaluate().length, lessThan(25));
    expect(find.text('Book 99'), findsNothing);

    await tester.scrollUntilVisible(find.text('Book 30'), 600);
    expect(find.text('Book 30'), findsOneWidget);
    expect(find.text('Book 99'), findsNothing);
    expect(find.byType(NovelCoverCard).evaluate().length, lessThan(25));
  });
}

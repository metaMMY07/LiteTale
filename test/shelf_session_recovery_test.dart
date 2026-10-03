import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/pages/home/bookshelf_cubit.dart';
import 'package:wild/pages/novel/novel_info_cubit.dart';
import 'package:wild/pages/novel/novel_info_page.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/light_novel_shelf_source.dart';
import 'package:wild/sources/shelf_session.dart';
import 'package:wild/sources/source_api.dart' as api;

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _refreshKey = 'litetale.lns.refresh';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    ShelfSession.instance.signedIn.value = false;
  });

  test(
    'unreadable Android token is removed without touching other data',
    () async {
      final values = <String, String>{
        _refreshKey: 'encrypted-on-another-device',
        'unrelated.secret': 'keep',
      };
      final deleted = <String>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        final key = (call.arguments as Map)['key'] as String;
        if (call.method == 'read') {
          if (key == _refreshKey && values.containsKey(key)) {
            throw PlatformException(
              code: 'Exception encountered',
              message: 'read',
              details: 'javax.crypto.BadPaddingException: BAD_DECRYPT',
            );
          }
          return values[key];
        }
        if (call.method == 'delete') {
          deleted.add(key);
          values.remove(key);
          return null;
        }
        throw StateError('Unexpected secure storage call: ${call.method}');
      });

      await ShelfSession.instance.load();
      expect(ShelfSession.instance.signedIn.value, isFalse);
      expect(deleted, [_refreshKey]);
      expect(values['unrelated.secret'], 'keep');
      expect(await ShelfSession.instance.token(), isNull);
      await expectLater(
        LightNovelShelfSource().detail('lns:42'),
        throwsA(isA<ShelfSignInRequired>()),
      );
    },
  );

  test('other storage failures are not mistaken for a corrupt token', () async {
    var deleted = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'read') {
        throw PlatformException(
          code: 'Exception encountered',
          message: 'read',
          details: 'Storage is temporarily unavailable',
        );
      }
      if (call.method == 'delete') deleted = true;
      return null;
    });

    await expectLater(
      ShelfSession.instance.load(),
      throwsA(isA<PlatformException>()),
    );
    expect(deleted, isFalse);
  });

  test(
    'a failed token cleanup still asks for login without showing crypto details',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'read') {
          throw PlatformException(
            code: 'Exception encountered',
            message: 'read',
            details: 'javax.crypto.BadPaddingException: BAD_DECRYPT',
          );
        }
        if (call.method == 'delete') {
          throw PlatformException(
            code: 'Exception encountered',
            message: 'delete',
          );
        }
        return null;
      });

      await expectLater(
        ShelfSession.instance.load(),
        throwsA(isA<ShelfSignInRequired>()),
      );
      expect(ShelfSession.instance.signedIn.value, isFalse);
    },
  );

  test('detail errors identify a login action for the page', () async {
    final original = api.bookSources[SourceId.lightNovelShelf]!;
    api.bookSources[SourceId.lightNovelShelf] = LightNovelShelfSource(
      invoke: (_, __) async => throw const ShelfSignInRequired(),
    );
    addTearDown(() => api.bookSources[SourceId.lightNovelShelf] = original);

    final cubit = NovelInfoCubit('lns:42');
    addTearDown(cubit.close);
    await cubit.load();
    expect(cubit.state, isA<NovelInfoError>());
    expect((cubit.state as NovelInfoError).loginRequired, isTrue);
  });

  testWidgets(
    'unreadable shelf login shows a login action instead of a stack',
    (tester) async {
      final original = api.bookSources[SourceId.lightNovelShelf]!;
      api.bookSources[SourceId.lightNovelShelf] = LightNovelShelfSource(
        invoke: (_, __) async => throw const ShelfSignInRequired(),
      );
      addTearDown(() => api.bookSources[SourceId.lightNovelShelf] = original);

      await tester.pumpWidget(
        BlocProvider(
          create: (_) => BookshelfCubit(),
          child: const MaterialApp(home: NovelInfoPage(novelId: 'lns:42')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('登录轻书架'), findsOneWidget);
      expect(find.textContaining('BAD_DECRYPT'), findsNothing);
      await tester.tap(find.text('登录轻书架'));
      await tester.pumpAndSettle();
      expect(find.text('轻书架账号'), findsOneWidget);
    },
  );

  test('a readable saved token keeps the session signed in', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'read') return 'valid-refresh-token';
      throw StateError('Unexpected secure storage call: ${call.method}');
    });

    await ShelfSession.instance.load();
    expect(ShelfSession.instance.signedIn.value, isTrue);
  });
}

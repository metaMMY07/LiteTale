import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/home/index_page.dart';
import 'package:wild/src/rust/frb_generated.dart';
import 'package:wild/src/rust/wenku8/models.dart';

class _FakeAuthCubit extends AuthCubit {
  _FakeAuthCubit(AuthStatus initialStatus)
    : super(
        login:
            ({
              required username,
              required password,
              required checkcode,
            }) async {},
        preLoginState: () async => false,
        downloadCheckcode: () async => Uint8List(0),
      ) {
    emit(AuthState(status: initialStatus));
  }

  void setStatus(AuthStatus status) => emit(AuthState(status: status));
}

class _FakeRustApi implements RustLibApi {
  static const _feed = [HomeBlock(title: '安全夹具推荐', list: <NovelCover>[])];

  int indexCalls = 0;
  int databaseWrites = 0;

  @override
  Future<String> crateApiWenku8GetApiHost() async => 'https://www.wenku8.net';

  @override
  Future<String> crateApiDatabaseLoadProperty({required String key}) async =>
      '';

  @override
  Future<void> crateApiDatabaseSaveProperty({
    required String key,
    required String value,
  }) async {
    databaseWrites++;
    throw StateError('Database writes are disabled in this widget test.');
  }

  @override
  Future<List<HomeBlock>> crateApiWenku8Index() async {
    indexCalls++;
    return _feed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError(
      'Unconfigured Rust API ${invocation.memberName} is disabled in this widget test.',
    );
  }
}

class _BlockingHttpClient implements HttpClient {
  int blockedRequests = 0;

  @override
  set connectionTimeout(Duration? value) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    blockedRequests++;
    return Future.error(StateError('Network is blocked in this widget test.'));
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    blockedRequests++;
    return Future.error(StateError('Network is blocked in this widget test.'));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError(
      'HttpClient.${invocation.memberName} is disabled in this widget test.',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the mounted Wenku8 discovery page follows login and logout state',
    (tester) async {
      final auth = _FakeAuthCubit(AuthStatus.unauthenticated);
      final rustApi = _FakeRustApi();
      final httpClient = _BlockingHttpClient();
      final pageKey = GlobalKey();
      addTearDown(auth.close);
      RustLib.initMock(api: rustApi);

      await HttpOverrides.runZoned(() async {
        await tester.pumpWidget(
          BlocProvider<AuthCubit>.value(
            value: auth,
            child: MaterialApp(home: IndexPage(key: pageKey)),
          ),
        );
        await tester.pump();

        final mountedPage = tester.element(find.byKey(pageKey));
        expect(find.text('选择书源后即可开始；需要账号的书源可在同一页面登录。'), findsOneWidget);
        expect(find.byType(TabBarView), findsNothing);

        auth.setStatus(AuthStatus.authenticated);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          identical(tester.element(find.byKey(pageKey)), mountedPage),
          isTrue,
        );
        expect(find.byType(TabBarView), findsOneWidget);
        expect(find.text('安全夹具推荐'), findsOneWidget);
        expect(rustApi.indexCalls, 1);

        auth.setStatus(AuthStatus.unauthenticated);
        await tester.pump();

        expect(
          identical(tester.element(find.byKey(pageKey)), mountedPage),
          isTrue,
        );
        expect(find.text('选择书源后即可开始；需要账号的书源可在同一页面登录。'), findsOneWidget);
        expect(find.byType(TabBarView), findsNothing);
        expect(find.text('安全夹具推荐'), findsNothing);
        expect(rustApi.databaseWrites, 0);
        expect(tester.takeException(), isNull);
      }, createHttpClient: (_) => httpClient);
    },
  );
}

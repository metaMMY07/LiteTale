import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wild/sources/bili_api_source.dart';

const _liveEnabled = bool.fromEnvironment('BILI_API_ONLINE');

void main() {
  group('BiliApiSource', () {
    test(
      'requests real ranking pages and performs local title matching',
      () async {
        final requestedPages = <String>[];
        final client = MockClient((request) async {
          requestedPages.add(request.url.queryParameters['page'] ?? '');
          final page = int.parse(request.url.queryParameters['page']!);
          final records =
              page == 1
                  ? List.generate(
                    30,
                    (index) => _topItem(100 + index, 'Index $index'),
                  )
                  : [_topItem(777, 'Wanted Book')];
          return _jsonResponse(
            _envelope({
              'items': records,
              'pagination': {'current': page},
            }),
          );
        });
        final source = BiliApiSource(client: client);

        final first = await source.listPage(1);
        expect(first.records, hasLength(30));
        expect(first.maxPage, 2);
        expect(first.records.first.aid, 'bili:100');
        expect(first.records.first.detailUrl, 'bili:100');
        expect(first.records.first.img, 'https://img.example/cover.jpg');

        final found = await source.search('wanted', 'articlename', 2);
        expect(found.currentPage, 2);
        expect(found.records.map((book) => book.aid), ['bili:777']);
        expect(requestedPages, ['1', '2']);
        expect(
          () => source.search('Writer', 'author', 1),
          throwsA(isA<UnsupportedError>()),
        );
        expect(requestedPages, ['1', '2']);
      },
    );

    test(
      'expands volumes in original order with at most three requests',
      () async {
        final volumeOrder = [30, 10, 20, 40];
        var activeVolumeRequests = 0;
        var maxActiveVolumeRequests = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/api/bili/novel/42') {
            return _jsonResponse(
              _envelope({
                'nid': 42,
                'name': 'Ordered Novel',
                'authors': [
                  {'name': 'Writer', 'position': 'author'},
                ],
                'labels': ['連載'],
                'description': 'A description',
                'cover': 'https://img.example/book.jpg',
                'updatedAt': '2026-10-01T00:00:00.000Z',
                'volumes':
                    volumeOrder
                        .map(
                          (vid) => {
                            'nid': 42,
                            'vid': vid,
                            'title': 'Volume $vid',
                          },
                        )
                        .toList(),
              }),
            );
          }
          final vid = int.parse(request.url.path.split('/').last);
          activeVolumeRequests++;
          if (activeVolumeRequests > maxActiveVolumeRequests) {
            maxActiveVolumeRequests = activeVolumeRequests;
          }
          await Future<void>.delayed(const Duration(milliseconds: 15));
          activeVolumeRequests--;
          return _jsonResponse(
            _envelope({
              'nid': 42,
              'vid': vid,
              'name': 'API Volume $vid',
              'chapters': [
                {
                  'nid': 42,
                  'vid': vid,
                  'cid': vid + 1000,
                  'title': 'Chapter $vid',
                },
              ],
            }),
          );
        });
        final source = BiliApiSource(client: client);

        final detail = await source.detail('bili:42');

        expect(detail.info.title, 'Ordered Novel');
        expect(detail.info.author, 'Writer');
        expect(detail.volumes.map((volume) => volume.id), [
          'bili:42:vol:30',
          'bili:42:vol:10',
          'bili:42:vol:20',
          'bili:42:vol:40',
        ]);
        expect(detail.volumes.first.title, 'API Volume 30');
        expect(detail.volumes.first.chapters.single.aid, 'bili:42');
        expect(detail.volumes.first.chapters.single.cid, 'bili:42:1030');
        expect(maxActiveVolumeRequests, 3);
      },
    );

    test('chapter prose and illustrations become safe reader markers', () async {
      final requested = <String>[];
      final client = MockClient((request) async {
        requested.add(request.url.path);
        if (request.url.path.endsWith('/274118')) {
          return _jsonResponse(
            _envelope({
              'nid': 4649,
              'vid': 274116,
              'cid': 274118,
              'title': 'Text chapter',
              'content':
                  '<p>第一段 &amp; prose</p>'
                  '<script>forbidden()</script>'
                  '<img src="../images/embedded.jpg" onerror="bad()">'
                  '<img src="javascript:alert(1)">',
              'images': [
                {'src': 'https://cdn.example/extra.jpg', 'alt': 'extra'},
                {
                  'src': 'https://name:secret@evil.example/private.jpg',
                  'alt': null,
                },
              ],
            }),
          );
        }
        return _jsonResponse(
          _envelope({
            'nid': 4649,
            'vid': 274116,
            'cid': 274117,
            'title': 'Illustrations',
            'content': '<div>插图</div>',
            'images': [
              {'src': '//cdn.example/front.jpg', 'alt': 'front'},
              {'src': 'data:image/png;base64,invalid', 'alt': 'blocked'},
            ],
          }),
        );
      });
      final source = BiliApiSource(client: client);

      final prose = await source.chapter('bili:4649', 'bili:4649:274118');
      expect(prose.content, contains('第一段 & prose'));
      expect(
        prose.content,
        contains(
          '<!--image-->https://lnovel.animes.garden/images/embedded.jpg<!--image-->',
        ),
      );
      expect(
        prose.content,
        contains('<!--image-->https://cdn.example/extra.jpg<!--image-->'),
      );
      expect(prose.content, isNot(contains('forbidden')));
      expect(prose.content, isNot(contains('javascript:')));
      expect(prose.content, isNot(contains('name:secret')));
      expect(prose.content, isNot(contains('onerror')));

      final illustrations = await source.chapter(
        'bili:4649',
        'bili:4649:274117',
      );
      expect(illustrations.content, contains('插图'));
      expect(
        illustrations.content,
        contains('<!--image-->https://cdn.example/front.jpg<!--image-->'),
      );
      expect(illustrations.content, isNot(contains('data:image')));
      expect(requested, [
        '/api/bili/novel/4649/chapter/274118',
        '/api/bili/novel/4649/chapter/274117',
      ]);
    });

    test(
      'preserves repeated plain paragraphs in the API-provided order',
      () async {
        // The observed Re:Zero prologue response is a sequence of bare <p>
        // elements with no class/style/hidden markers, yet the API repeats some
        // complete paragraphs. Keep this small structural fixture as-is: there
        // is no safe signal for the adapter to deduplicate or reorder them.
        const apiHtml =
            '<p>第一段</p>'
            '<p>重复段落</p>'
            '<p>中间段落</p>'
            '<p>重复段落</p>'
            '<p>最后一段</p>';
        final source = BiliApiSource(
          client: MockClient(
            (_) async => _jsonResponse(
              _envelope({
                'nid': 2139,
                'vid': 76672,
                'cid': 76673,
                'title': '序章『开始的余温』',
                'content': apiHtml,
                'images': <Object?>[],
              }),
            ),
          ),
        );

        final chapter = await source.chapter('bili:2139', 'bili:2139:76673');

        expect(chapter.content, '第一段\n重复段落\n中间段落\n重复段落\n最后一段');
      },
    );

    test(
      'rejects chapter ids belonging to another book before networking',
      () async {
        var requestCount = 0;
        final source = BiliApiSource(
          client: MockClient((_) async {
            requestCount++;
            return _jsonResponse(_envelope({}));
          }),
        );
        await expectLater(
          source.chapter('bili:42', 'bili:43:100'),
          throwsA(isA<FormatException>()),
        );
        expect(requestCount, 0);
      },
    );

    test('does not expose error bodies and rejects bad JSON', () async {
      final unavailable = BiliApiSource(
        client: MockClient(
          (_) async => http.Response('private server detail', 503),
        ),
      );
      await expectLater(
        unavailable.listPage(1),
        throwsA(
          isA<BiliApiException>().having(
            (error) => error.message,
            'message',
            allOf(contains('503'), isNot(contains('private server detail'))),
          ),
        ),
      );

      final malformed = BiliApiSource(
        client: MockClient((_) async => http.Response('{broken', 200)),
      );
      await expectLater(malformed.listPage(1), throwsA(isA<FormatException>()));
    });

    test('enforces streamed response size and request timeout', () async {
      final oversized = BiliApiSource(
        budget: const BiliApiBudget(maxResponseBytes: 32),
        client: _StreamingClient((request) async {
          final bytes = utf8.encode('{"ok":true,"data":${'x' * 64}}');
          return http.StreamedResponse(
            Stream<List<int>>.value(bytes),
            200,
            contentLength: bytes.length,
            request: request,
          );
        }),
      );
      await expectLater(
        oversized.listPage(1),
        throwsA(
          isA<BiliApiException>().having(
            (e) => e.message,
            'message',
            contains('32'),
          ),
        ),
      );

      final slow = BiliApiSource(
        budget: const BiliApiBudget(requestTimeout: Duration(milliseconds: 20)),
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return _jsonResponse(
            _envelope({
              'items': [],
              'pagination': {'current': 1},
            }),
          );
        }),
      );
      await expectLater(
        slow.listPage(1),
        throwsA(
          isA<BiliApiException>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );

      final slowBody = BiliApiSource(
        budget: const BiliApiBudget(requestTimeout: Duration(milliseconds: 20)),
        client: _StreamingClient((request) async {
          final bytes = utf8.encode(
            jsonEncode(
              _envelope({
                'items': [],
                'pagination': {'current': 1},
              }),
            ),
          );
          return http.StreamedResponse(
            Stream<List<int>>.periodic(
              const Duration(milliseconds: 100),
              (_) => bytes,
            ).take(1),
            200,
            request: request,
          );
        }),
      );
      await expectLater(
        slowBody.listPage(1),
        throwsA(
          isA<BiliApiException>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );
    });

    test(
      'fails explicitly when volume or chapter limits are exceeded',
      () async {
        var volumeRequests = 0;
        final tooManyVolumes = BiliApiSource(
          client: MockClient((request) async {
            if (request.url.path == '/api/bili/novel/42') {
              return _jsonResponse(
                _envelope({
                  'nid': 42,
                  'name': 'Large',
                  'authors': [],
                  'labels': [],
                  'description': '',
                  'cover': null,
                  'updatedAt': null,
                  'volumes': List.generate(
                    81,
                    (index) => {
                      'nid': 42,
                      'vid': index + 1,
                      'title': 'V$index',
                    },
                  ),
                }),
              );
            }
            volumeRequests++;
            return _jsonResponse(_envelope({}));
          }),
        );
        await expectLater(
          tooManyVolumes.detail('bili:42'),
          throwsA(
            isA<BiliApiException>().having(
              (e) => e.message,
              'message',
              contains('80'),
            ),
          ),
        );
        expect(volumeRequests, 0);

        final tooManyChapters = BiliApiSource(
          client: MockClient((request) async {
            if (request.url.path == '/api/bili/novel/42') {
              return _jsonResponse(
                _envelope({
                  'nid': 42,
                  'name': 'Large',
                  'authors': [],
                  'labels': [],
                  'description': '',
                  'cover': null,
                  'updatedAt': null,
                  'volumes': [
                    {'nid': 42, 'vid': 1, 'title': 'V1'},
                  ],
                }),
              );
            }
            return _jsonResponse(
              _envelope({
                'nid': 42,
                'vid': 1,
                'name': 'V1',
                'chapters': List.generate(
                  10001,
                  (index) => {
                    'nid': 42,
                    'vid': 1,
                    'cid': index + 1,
                    'title': 'C$index',
                  },
                ),
              }),
            );
          }),
        );
        await expectLater(
          tooManyChapters.detail('bili:42'),
          throwsA(
            isA<BiliApiException>().having(
              (e) => e.message,
              'message',
              contains('10000'),
            ),
          ),
        );
      },
    );

    test(
      'maps only explicit status labels and rejects an empty directory',
      () async {
        Future<String> statusFor(List<String> labels) async {
          final client = MockClient((request) async {
            if (request.url.path == '/api/bili/novel/42') {
              return _jsonResponse(_envelope(_novelData(labels: labels)));
            }
            return _jsonResponse(
              _envelope({
                'nid': 42,
                'vid': 1,
                'name': 'Volume 1',
                'chapters': [
                  {'nid': 42, 'vid': 1, 'cid': 100, 'title': 'Chapter'},
                ],
              }),
            );
          });
          return (await BiliApiSource(
            client: client,
          ).detail('bili:42')).info.status;
        }

        expect(await statusFor(['奇幻']), '未知');
        expect(await statusFor(['連載中']), '连载中');
        expect(await statusFor(['已完結']), '已完结');

        final emptyDirectory = BiliApiSource(
          client: MockClient(
            (_) async => _jsonResponse(
              _envelope(_novelData(labels: ['奇幻'], volumes: [])),
            ),
          ),
        );
        await expectLater(
          emptyDirectory.detail('bili:42'),
          throwsA(
            isA<BiliApiException>().having(
              (error) => error.message,
              'message',
              contains('尚未就绪'),
            ),
          ),
        );
      },
    );

    test(
      'operation deadline includes a hanging response cancellation',
      () async {
        final client = _NeverCompletingCancelClient();
        final source = BiliApiSource(
          client: client,
          budget: const BiliApiBudget(
            requestTimeout: Duration(milliseconds: 60),
            maxRedirects: 0,
          ),
        );
        final clock = Stopwatch()..start();
        await expectLater(
          source.listPage(1),
          throwsA(
            isA<BiliApiException>().having(
              (error) => error.message,
              'message',
              contains('超时'),
            ),
          ),
        );
        clock.stop();
        expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)));

        // A timed-out operation must leave an injected client usable for a new
        // operation, even while its abandoned cancellation Future never ends.
        final next = await source.listPage(1);
        expect(next.currentPage, 1);
        expect(client.sendCount, 2);
      },
    );

    test(
      'blocks cross-origin redirects and accepts bounded same-origin redirects',
      () async {
        var outsideRequests = 0;
        final crossOrigin = BiliApiSource(
          client: MockClient((request) async {
            outsideRequests++;
            return http.Response(
              '',
              302,
              headers: {'location': 'https://attacker.example/data'},
            );
          }),
        );
        await expectLater(
          crossOrigin.listPage(1),
          throwsA(
            isA<BiliApiException>().having(
              (e) => e.message,
              'message',
              contains('不安全'),
            ),
          ),
        );
        expect(outsideRequests, 1);

        var hops = 0;
        final sameOrigin = BiliApiSource(
          client: MockClient((request) async {
            hops++;
            if (hops < 4) {
              return http.Response(
                '',
                302,
                headers: {'location': '/redirect-$hops'},
              );
            }
            return _jsonResponse(
              _envelope({
                'items': [],
                'pagination': {'current': 1},
              }),
            );
          }),
        );
        final page = await sameOrigin.listPage(1);
        expect(page.records, isEmpty);
        expect(hops, 4);
      },
    );

    test(
      'optional live sample covers ranking pages, all volumes, prose, and illustrations',
      () async {
        final source = BiliApiSource();
        final firstPage = await source.listPage(1);
        expect(firstPage.records, isNotEmpty);
        if (firstPage.maxPage > firstPage.currentPage) {
          final secondPage = await source.listPage(2);
          expect(secondPage.currentPage, 2);
          expect(secondPage.records, isNotEmpty);
        }

        final detail = await source.detail('bili:4649');
        expect(detail.volumes, hasLength(5));
        expect(detail.volumes.expand((volume) => volume.chapters), isNotEmpty);

        final prose = await source.chapter('bili:4649', 'bili:4649:274118');
        expect(prose.content.trim(), isNotEmpty);
        final proseText = prose.content.replaceAll(
          RegExp(r'<!--image-->.*?<!--image-->', dotAll: true),
          '',
        );
        expect(RegExp(r'[A-Za-z\u4e00-\u9fff]{4}').hasMatch(proseText), isTrue);

        final illustrations = await source.chapter(
          'bili:4649',
          'bili:4649:274117',
        );
        expect(illustrations.content, contains('<!--image-->'));
      },
      timeout: const Timeout(Duration(seconds: 120)),
      skip:
          _liveEnabled ? null : 'set --dart-define=BILI_API_ONLINE=true to run',
    );
  });
}

Map<String, Object?> _topItem(int nid, String title) => {
  'nid': nid,
  'title': title,
  'cover': 'https://img.example/cover.jpg',
  'author': 'Author',
  'description': 'Description',
  'updatedAt': '2026-10-01T00:00:00.000Z',
};

Map<String, Object?> _novelData({
  required List<String> labels,
  List<Map<String, Object?>>? volumes,
}) => {
  'nid': 42,
  'name': 'Test Novel',
  'authors': [
    {'name': 'Writer', 'position': 'author'},
  ],
  'labels': labels,
  'description': 'Description',
  'cover': null,
  'updatedAt': null,
  'volumes':
      volumes ??
      [
        {'nid': 42, 'vid': 1, 'title': 'Volume 1'},
      ],
};

Map<String, Object?> _envelope(Map<String, Object?> data) => {
  'ok': true,
  'provider': 'bilinovel',
  'data': data,
};

http.Response _jsonResponse(Map<String, Object?> json) => http.Response(
  jsonEncode(json),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

class _NeverCompletingCancelClient extends http.BaseClient {
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    if (sendCount == 1) {
      final neverCompletes = Completer<void>();
      final controller = StreamController<List<int>>(
        onCancel: () => neverCompletes.future,
      );
      return http.StreamedResponse(
        controller.stream,
        302,
        headers: {'location': '/after-redirect'},
        request: request,
      );
    }
    final bytes = utf8.encode(
      jsonEncode(
        _envelope({
          'items': [],
          'pagination': {'current': 1},
        }),
      ),
    );
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      contentLength: bytes.length,
      request: request,
    );
  }
}

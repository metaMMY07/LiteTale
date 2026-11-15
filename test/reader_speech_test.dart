import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_listening_page.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/services/reader_listening_chapter.dart';
import 'package:wild/services/reader_mark_text.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as sources;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/widgets/reader_speech_scope.dart';

void main() {
  test('spoken EPUB offsets map back to independently spaced DOM text', () {
    const text = '章节标题\n第一段文字。\n　第二段继续向前阅读，直到末尾。';
    const dom = '章节标题  第一段文字。第二段继续向前阅读，  直到末尾。';
    final raw = text.indexOf('向前');
    final css = dom.indexOf('向前');
    expect(matchEpubTextOffset(text, raw, dom), css);
    expect(matchEpubTextOffset(dom, css, text), raw);
  });

  test('segments preserve punctuation and skip illustrations', () {
    expect(
      ReaderSpeechPlan(
        '第一句。第二句。\n<!--image-->https://example.com/a.png<!--image-->',
        7,
      ).chunks.map((part) => part.text),
      ['第一句。', '第二句。'],
    );
    expect(ReaderSpeechPlan('甲🙂乙', 2).chunks.map((part) => part.text), [
      '甲',
      '🙂',
      '乙',
    ]);
  });

  test(
    'visible paragraphs retain source offsets through image removal and splitting',
    () {
      const text =
          '  第一。第二。<!--image-->https://example.com/a.png<!--image-->最后。\n下一段。';
      final plan = ReaderSpeechPlan(text, 5);
      expect(plan.paragraphs.map((part) => part.text), ['第一。第二。 最后。', '下一段。']);
      expect(plan.chunks.map((part) => part.paragraph), [0, 0, 0, 1]);
      for (final part in plan.chunks) {
        expect(
          text.substring(part.offset, part.offset + part.text.length),
          part.text,
        );
      }
    },
  );

  test(
    'pause resumes at the confirmed range and ignores older events',
    () async {
      final engine = _SpeechEngine();
      final speech = ReaderSpeechController(engine: engine);
      addTearDown(engine.close);
      addTearDown(speech.dispose);

      speech.loadPlan(ReaderSpeechPlan('甲乙丙丁\n戊己', 240), 0);
      await speech.play();
      final first = engine.calls.single.id;
      expect(ReaderSpeechController.isAnyPlaying, isTrue);
      engine.emit(first, 'range', start: 2);
      await speech.pause();
      expect(speech.paused, isTrue);
      expect(ReaderSpeechController.isAnyPlaying, isFalse);

      await speech.play();
      expect(engine.calls.last.text, '丙丁');
      final resumed = engine.calls.last.id;
      engine.emit(first, 'done');
      expect(engine.calls, hasLength(2));
      engine.emit(resumed, 'done');
      expect(engine.calls.last.text, '戊己');
      engine.emit(engine.calls.last.id, 'done');
      expect(speech.finished, isTrue);
      expect(ReaderSpeechController.isAnyPlaying, isFalse);
    },
  );

  test('outdated native resume cannot stop a newer resume', () async {
    final engine = _SpeechEngine()..nativePause = true;
    final speech = ReaderSpeechController(engine: engine);
    addTearDown(engine.close);
    addTearDown(speech.dispose);

    speech.loadPlan(ReaderSpeechPlan('测试章节', 240), 0);
    await speech.play();
    await speech.pause();
    final firstResume = Completer<bool>();
    engine.resumeResponse = firstResume.future;
    final pending = speech.play();
    await speech.pause();
    engine.resumeResponse = Future.value(true);
    await speech.play();
    firstResume.complete(false);
    await pending;

    expect(speech.playing, isTrue);
    expect(engine.calls, hasLength(1));
    expect(engine.stopped, isEmpty);
  });

  test('switching chapters discards pending engine initialization', () async {
    final first = Completer<ReaderSpeechInfo>();
    final engine = _SpeechEngine()..initialization = first.future;
    final speech = ReaderSpeechController(engine: engine);
    addTearDown(engine.close);
    addTearDown(speech.dispose);

    speech.loadPlan(ReaderSpeechPlan('旧章节', 240), 0);
    final pending = speech.play();
    engine.initialization = null;
    speech.loadPlan(ReaderSpeechPlan('新章节', 240), 0);
    first.complete(_SpeechEngine.info);
    await pending;
    await speech.play();
    expect(engine.calls.single.text, '新章节');
    speech.loadPlan(ReaderSpeechPlan('', 240), 0);
    expect(engine.stopped, [engine.calls.single.id]);
    engine.emit(engine.calls.single.id, 'done');
    expect(speech.ready, isFalse);
    expect(ReaderSpeechController.isAnyPlaying, isFalse);
  });

  testWidgets(
    'reader hands over listening only after its controls and route exit',
    (tester) async {
      ReaderListeningRequest? handedOff;
      final chapter = ValueNotifier(
        const ReaderListeningChapter(
          aid: '1',
          cid: '2',
          title: '插图',
          text: '<!--image-->https://example.com/a.png<!--image-->',
        ),
      );
      addTearDown(chapter.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      handedOff = await pushAndWaitForPageExit(
                        context,
                        HorizontalCoverPageRoute<ReaderListeningRequest>(
                          builder:
                              (_) => ValueListenableBuilder(
                                valueListenable: chapter,
                                builder:
                                    (_, content, __) => ReaderSpeechScope(
                                      chapter: content,
                                      request:
                                          (chapter) => ReaderListeningRequest(
                                            chapter: chapter,
                                            volumes: const [],
                                            info: _book,
                                            offset: 8,
                                          ),
                                      child: Scaffold(
                                        body: ReaderMenuMotion(
                                          visible: true,
                                          child: ReaderToolbar(
                                            title: '正文',
                                            onBack: () {},
                                            onCatalog: () {},
                                            onSettings: () {},
                                          ),
                                        ),
                                      ),
                                    ),
                              ),
                        ),
                      );
                    },
                    child: const Text('详情'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReaderRoundAction>(
              find.byKey(const ValueKey('reader-speech')),
            )
            .onPressed,
        isNull,
      );
      chapter.value = _chapter;
      await tester.pump();
      await tester.tap(find.byTooltip('听书'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(handedOff, isNull);
      await tester.pump(const Duration(milliseconds: 150));
      expect(handedOff, isNull);
      await tester.pumpAndSettle();
      expect(handedOff?.offset, 8);
      expect(handedOff?.chapter.cid, _chapter.cid);
    },
  );

  testWidgets(
    'listening waits for the cover, stops at chapter end and resumes reading after a manual chapter change',
    (tester) async {
      final source = _ListeningSource();
      final previous = sources.bookSources[SourceId.lnovel]!;
      sources.bookSources[SourceId.lnovel] = source;
      addTearDown(() => sources.bookSources[SourceId.lnovel] = previous);
      const commands = MethodChannel('litetale/reader_speech');
      const events = MethodChannel('litetale/reader_speech/events');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(commands, (call) async {
        calls.add(call);
        return call.method == 'voices' ? {'limit': 1000, 'voices': []} : null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      FlutterSecureStorage.setMockInitialValues({
        'litetale.listening.voice.v1': jsonEncode({
          'voice': ListeningVoice.system.toJson(),
        }),
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(commands, null);
        messenger.setMockMethodCallHandler(events, null);
        FlutterSecureStorage.setMockInitialValues({});
      });

      final writes = <ReadingProgress>[];
      final progress = ReadingProgressQueue(
        write: (position) async => writes.add(position),
      );
      ReadingProgress? detailPosition;
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => ThemeCubit()),
            BlocProvider(create: (_) => FontSettingsCubit()),
            BlocProvider(create: (_) => FontSizeCubit()),
            BlocProvider(create: (_) => LineHeightCubit()),
            BlocProvider(create: (_) => ParagraphSpacingCubit()),
          ],
          child: MaterialApp(
            home: Builder(
              builder:
                  (context) => Scaffold(
                    body: TextButton(
                      child: const Text('打开听书页'),
                      onPressed:
                          () => Navigator.of(context).push(
                            HorizontalCoverPageRoute<void>(
                              builder:
                                  (_) => ReaderListeningPage(
                                    progress: progress,
                                    onPosition:
                                        (progress) => detailPosition = progress,
                                    request: const ReaderListeningRequest(
                                      chapter: _chapter,
                                      volumes: [
                                        Volume(
                                          id: 'volume',
                                          title: '卷一',
                                          chapters: [
                                            Chapter(
                                              aid: _aid,
                                              cid: '2',
                                              title: '第一章',
                                              url: '',
                                            ),
                                            Chapter(
                                              aid: _aid,
                                              cid: '3',
                                              title: '第二章',
                                              url: '',
                                            ),
                                          ],
                                        ),
                                      ],
                                      info: _book,
                                      offset: 0,
                                    ),
                                  ),
                            ),
                          ),
                    ),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开听书页'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(find.text('第一个段落。'), findsOneWidget);
      expect(find.byTooltip('播放'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放'), findsOneWidget);
      await tester.tap(find.text('第二个段落。'));
      await tester.pumpAndSettle();
      final args =
          calls.singleWhere((call) => call.method == 'speak').arguments as Map;
      expect(args['text'], '第二个段落。');
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'id': args['id'],
          'type': 'started',
        }),
        (_) {},
      );
      await tester.pump();
      expect(find.text('第 2/2段'), findsOneWidget);
      await tester.tapAt(const Offset(748, 300));
      await tester.pump();
      expect(find.byTooltip('暂停'), findsOneWidget);
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'id': args['id'],
          'type': 'done',
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放'), findsOneWidget);
      expect(source.requests, isEmpty);
      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      expect(source.requests, ['3']);
      final speak =
          calls.where((call) => call.method == 'speak').last.arguments as Map;
      expect(speak['text'], _ListeningSource.second);
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope({
          'id': speak['id'],
          'type': 'range',
          'start': 3,
        }),
        (_) {},
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('打开听书页'), findsOneWidget);
      expect(writes.single.chapterId, '3');
      expect(writes.single.characters, 3);
      expect(writes.single.page, scrollReaderProgressPage);
      expect(detailPosition, same(writes.single));
      expect(
        calls.any(
          (call) => call.method == 'stop' && call.arguments == speak['id'],
        ),
        isTrue,
      );
    },
  );
}

const _aid = 'lnv:listening-test';
const _chapter = ReaderListeningChapter(
  aid: _aid,
  cid: '2',
  title: '第一章',
  text: '第一个段落。\n<!--image-->https://example.com/a.png<!--image-->\n第二个段落。',
);

class _ListeningSource implements BookSource {
  static const second = '继续播放第二章。';
  final requests = <String>[];

  @override
  SourceId get id => SourceId.lnovel;

  @override
  Future<SourceChapter> chapter(String bookId, String chapterId) async {
    requests.add(chapterId);
    return const SourceChapter(second);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _book = NovelInfo(
  title: '测试小说',
  author: '',
  status: '',
  imgUrl: '',
  introduce: '',
  finUpdate: '',
  isAnimated: false,
  tags: [],
  trending: '',
  heat: '',
);

class _SpeechEngine implements ReaderSpeechEngine {
  static const ReaderSpeechInfo info = (limit: 1000, voices: []);
  final _events = StreamController<ReaderSpeechEvent>.broadcast(sync: true);
  final calls = <({String id, String text})>[];
  final stopped = <String>[];
  bool nativePause = false;
  Future<bool>? resumeResponse;
  Future<ReaderSpeechInfo>? initialization;

  @override
  Stream<ReaderSpeechEvent> get events => _events.stream;

  @override
  Future<ReaderSpeechInfo> initialize() => initialization ?? Future.value(info);

  @override
  Future<void> speak(String id, String text, double rate, String? voice) async {
    calls.add((id: id, text: text));
  }

  @override
  Future<bool> pause(String id) async => nativePause;

  @override
  Future<bool> resume(String id) => resumeResponse ?? Future.value(false);

  @override
  Future<void> stop(String id) async => stopped.add(id);

  void emit(String id, String type, {int? start}) {
    _events.add((id: id, type: type, start: start, message: null));
  }

  Future<void> close() => _events.close();
}

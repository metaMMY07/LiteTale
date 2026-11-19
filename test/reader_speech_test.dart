import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_edge_tts/flutter_edge_tts.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:wild/cubits/font_settings_cubit.dart';
import 'package:wild/pages/novel/font_size_cubit.dart';
import 'package:wild/pages/novel/line_height_cubit.dart';
import 'package:wild/pages/novel/paragraph_spacing_cubit.dart';
import 'package:wild/pages/novel/reader_listening_page.dart';
import 'package:wild/pages/novel/theme_cubit.dart';
import 'package:wild/services/qwen_reader_tts.dart';
import 'package:wild/services/read_request.dart';
import 'package:wild/services/reader_listening_audio.dart';
import 'package:wild/services/reader_listening_chapter.dart';
import 'package:wild/services/reader_mark_text.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/services/reading_progress.dart';
import 'package:wild/settings/settings_widgets.dart';
import 'package:wild/sources/book_source.dart';
import 'package:wild/sources/source_api.dart' as sources;
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/theme/horizontal_page_transitions.dart';
import 'package:wild/theme/ios_glass_theme.dart';
import 'package:wild/theme/material_you.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';
import 'package:wild/widgets/reader_controls.dart';
import 'package:wild/widgets/reader_listening_voice_panel.dart';
import 'package:wild/widgets/reader_speech_scope.dart';
import 'package:wild/widgets/wavy_slider_track_shape.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'removed voice preferences resolve to the default online voice',
    () async {
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
      for (final source in ['custom', 'system']) {
        FlutterSecureStorage.setMockInitialValues({
          'litetale.listening.voice.v1': jsonEncode({
            'voice': {'source': source, 'id': 'old-voice', 'name': '旧音色'},
          }),
        });
        expect(await ListeningVoice.load(), same(ListeningVoice.xiaoxiao));
      }
      await ListeningVoice.xiaoyi.save();
      expect(await ListeningVoice.load(), same(ListeningVoice.xiaoyi));
    },
  );

  test(
    'the previous Yunxi selection stays available as an online voice',
    () async {
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
      FlutterSecureStorage.setMockInitialValues({
        'litetale.listening.voice.v1': jsonEncode({
          'voice': {
            'source': 'online',
            'id': 'zh-CN-YunxiNeural',
            'name': 'LiteTale 默认音色（男）',
            'language': 'zh-CN',
          },
        }),
      });
      final voice = await ListeningVoice.load();
      expect(voice.id, 'zh-CN-YunxiNeural');
      expect(voice.name, 'Yunxi · zh-CN · 男声');
      expect(ListeningVoice.defaults.map((voice) => voice.id), [
        'zh-CN-XiaoxiaoNeural',
        'zh-CN-XiaoyiNeural',
      ]);
    },
  );

  test('online playback advances through successive completed clips', () async {
    final directory = await Directory.systemTemp.createTemp(
      'litetale-tts-test-',
    );
    final player = _AudioPlayer();
    final engine = OnlineReaderSpeech(
      createPlayer: () => player,
      temporaryDirectory: () async => directory,
      synthesize:
          (_, text, __) async => EdgeTtsSynthesisResult(
            audioBytes: Uint8List.fromList(utf8.encode(text)),
            metadata: const [],
            requestId: 'test',
          ),
    );
    final speech = ReaderSpeechController(engine: engine);
    addTearDown(() async {
      speech.dispose();
      await engine.dispose();
      await directory.delete();
    });
    speech.loadPlan(ReaderSpeechPlan('第一段。\n第二段。', 240), 0);
    await speech.play();
    expect(player.playCount, 1);
    final second = player.plays.firstWhere((value) => value == 2);
    player.completeClip();
    await second.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(speech.playing, isTrue);
    expect(speech.paragraphIndex, 1);
    expect(player.playing, isTrue);
    final finished = engine.events.firstWhere((event) => event.type == 'done');
    player.completeClip();
    await finished;
    expect(speech.finished, isTrue);
    expect(speech.playing, isFalse);
    expect(player.playCount, 2);
  });

  test(
    'Qwen downloads WAV clips and reuses the next paragraph request',
    () async {
      final directory = await Directory.systemTemp.createTemp('litetale-qwen-');
      final requests = <http.Request>[];
      final player = _AudioPlayer();
      const audioHost = 'dashscope-result-sg.oss-ap-southeast-1.aliyuncs.com';
      const audioQuery = 'Signature=example%2Bsignature%3D';
      final wave =
          Uint8List(46)
            ..setRange(0, 4, 'RIFF'.codeUnits)
            ..setRange(8, 12, 'WAVE'.codeUnits);
      final engine = OnlineReaderSpeech(
        createPlayer: () => player,
        temporaryDirectory: () async => directory,
        synthesize: (_, __, ___) async => fail('Qwen voice reached Edge'),
        qwen: QwenReaderTts(
          loadSettings:
              () async => const QwenTtsSettings(
                region: QwenTtsRegion.singapore,
                apiKey: 'sk-test',
              ),
          createClient:
              () => MockClient((request) async {
                requests.add(request);
                if (request.method == 'POST') {
                  return http.Response(
                    jsonEncode({
                      'output': {
                        'audio': {
                          'url': 'http://$audioHost/clip.wav?$audioQuery',
                        },
                      },
                    }),
                    200,
                  );
                }
                return http.Response.bytes(wave, 200);
              }),
        ),
      );
      final speech = ReaderSpeechController(engine: engine);
      addTearDown(() async {
        speech.dispose();
        await engine.dispose();
        await directory.delete();
      });
      speech.selectVoice(ListeningVoice.qwenPresets.first.id);
      speech.loadPlan(ReaderSpeechPlan('晚上好。\nこんばんは。', 240), 0);
      await speech.play();
      expect(player.playCount, 1, reason: speech.message);
      final second = player.plays.firstWhere((value) => value == 2);
      player.completeClip();
      await second.timeout(const Duration(seconds: 2));
      expect(speech.paragraphIndex, 1);
      final finished = engine.events.firstWhere(
        (event) => event.type == 'done',
      );
      player.completeClip();
      await finished;
      expect(speech.finished, isTrue);
      expect(player.loadedPaths, hasLength(2));
      expect(player.loadedPaths, everyElement(endsWith('.wav')));
      expect(requests.map((request) => request.method), [
        'POST',
        'GET',
        'POST',
        'GET',
      ]);
      for (final request in requests.where(
        (request) => request.method == 'GET',
      )) {
        expect(
          request.url.toString(),
          'https://$audioHost/clip.wav?$audioQuery',
        );
        expect(request.headers['authorization'], isNull);
      }
      final posts = requests.where((request) => request.method == 'POST');
      for (final request in posts) {
        expect(
          request.url.toString(),
          'https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation',
        );
        expect(request.headers['authorization'], 'Bearer sk-test');
      }
      expect(posts.map((request) => jsonDecode(request.body)), [
        for (final text in ['晚上好。', 'こんばんは。'])
          {
            'model': 'qwen3-tts-flash',
            'input': {
              'text': text,
              'voice': 'Ono Anna',
              'language_type': 'Auto',
            },
          },
      ]);
    },
  );

  test(
    'Qwen cancellation during credential lookup never submits text',
    () async {
      final lookup = Completer<QwenTtsSettings?>();
      var sent = 0;
      final qwen = QwenReaderTts(
        loadSettings: () => lookup.future,
        createClient:
            () => MockClient((_) async {
              sent++;
              return http.Response('', 500);
            }),
      );
      final request = ReadRequest();
      final result = qwen.synthesize('Chelsie', '测试', request);
      final cancelled = expectLater(result, throwsA(isA<ReadCancelled>()));
      request.cancel();
      await cancelled;
      lookup.complete(
        const QwenTtsSettings(region: QwenTtsRegion.beijing, apiKey: 'sk-test'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent, 0);
    },
  );

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
    final first = Completer<void>();
    final engine = _SpeechEngine()..initialization = first.future;
    final speech = ReaderSpeechController(engine: engine);
    addTearDown(engine.close);
    addTearDown(speech.dispose);

    speech.loadPlan(ReaderSpeechPlan('旧章节', 240), 0);
    final pending = speech.play();
    engine.initialization = null;
    speech.loadPlan(ReaderSpeechPlan('新章节', 240), 0);
    first.complete();
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
    'iOS uses solid grouped rows and shows online voices directly',
    (tester) async {
      ListeningVoice? chosen;
      await tester.pumpWidget(
        MaterialApp(
          theme: iosGlassTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () async {
                      chosen = await showListeningVoicePanel(
                        context,
                        ListeningVoice.xiaoxiao,
                        (_) async {},
                      );
                    },
                    child: const Text('打开音色'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开音色'));
      await tester.pumpAndSettle();
      expect(find.byType(IosSettingsSection), findsNWidgets(2));
      expect(find.byType(AppleGlassSurface), findsNothing);
      expect(find.text('在线音色'), findsOneWidget);
      expect(find.text('系统音色'), findsNothing);
      expect(find.text('自定义'), findsNothing);
      expect(find.text(ListeningVoice.xiaoxiao.name), findsOneWidget);
      expect(find.textContaining('男'), findsNothing);
      await tester.tap(find.text(ListeningVoice.xiaoyi.name));
      await tester.pumpAndSettle();
      expect(chosen, same(ListeningVoice.xiaoyi));
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'Qwen voices can be configured, previewed, selected and removed',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var chosen = ListeningVoice.xiaoxiao;
      ListeningVoice? previewed;
      await tester.pumpWidget(
        MaterialApp(
          theme:
              usesAppleGlass
                  ? iosGlassTheme(Brightness.dark)
                  : materialYouTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () async {
                      final result = await showListeningVoicePanel(
                        context,
                        chosen,
                        (voice) async {
                          previewed = voice;
                        },
                      );
                      if (result != null) chosen = result;
                    },
                    child: const Text('打开音色'),
                  ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开音色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小野杏'));
      await tester.pumpAndSettle();
      expect(find.text('百炼 API Key'), findsOneWidget);
      expect(previewed, isNull);
      await tester.tap(find.text('新加坡'));
      final field = find.byType(EditableText);
      expect(tester.widget<EditableText>(field).obscureText, isTrue);
      await tester.enterText(field, ' sk-test ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final settings = await QwenTtsSettings.load();
      expect(settings?.region, QwenTtsRegion.singapore);
      expect(settings?.apiKey, 'sk-test');
      final qwenRow = find.widgetWithText(
        usesAppleGlass ? IosSettingsRow : ListTile,
        '千雪',
      );
      await tester.tap(
        find.descendant(of: qwenRow, matching: find.byType(AppIconButton)),
      );
      await tester.pumpAndSettle();
      expect(previewed, same(ListeningVoice.qwenPresets.last));
      await tester.tap(find.text('千雪'));
      await tester.pumpAndSettle();
      expect(chosen, same(ListeningVoice.qwenPresets.last));
      await tester.runAsync(() async {
        await chosen.save();
        expect(await ListeningVoice.load(), same(chosen));
      });

      await tester.tap(find.text('打开音色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更换百炼 API Key'));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(field).controller.text, isEmpty);
      await tester.tap(find.text('移除密钥'));
      await tester.pumpAndSettle();
      expect(await QwenTtsSettings.load(), isNull);
      expect(chosen, same(ListeningVoice.xiaoxiao));
      expect(await tester.runAsync(ListeningVoice.load), same(chosen));
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'listening controls reserve their viewport and use the platform scrubber',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.reset);
      final engine = _SpeechEngine();
      addTearDown(engine.close);
      final ios = usesAppleGlass;
      final theme =
          ios
              ? iosGlassTheme(Brightness.dark, accent: Colors.redAccent)
              : materialYouTheme(
                Brightness.light,
                seedColor: Colors.deepPurple,
              );
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
            theme: theme,
            home: ReaderListeningPage(
              speechEngine: engine,
              progress: ReadingProgressQueue(write: (_) async {}),
              request: const ReaderListeningRequest(
                chapter: _chapter,
                volumes: [],
                info: _book,
                offset: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controls = find.byKey(const ValueKey('reader-listening-controls'));
      final panel = tester.getRect(controls);
      final body = tester.getRect(find.byType(ScrollablePositionedList));
      expect(body.bottom, closeTo(panel.top, .01));
      final palette = Theme.of(tester.element(controls)).colorScheme;
      expect(
        palette.primary,
        ios ? palette.onSurface : theme.colorScheme.primary,
      );
      if (ios) {
        expect(panel.height, closeTo(874 / 3, .01));
        expect(panel.bottom, 874);
        final panelMaterial = tester.widget<Material>(controls);
        expect(panelMaterial.color, palette.surfaceContainerHigh);
        final back = find.byType(IosReaderBackButton);
        expect(tester.getSize(back), const Size.square(44));
        final glass = tester.widget<AppleGlassSurface>(
          find.descendant(of: back, matching: find.byType(AppleGlassSurface)),
        );
        expect(glass.capsule, isTrue);
        final slider = tester.widget<AppleGlassSlider>(
          find.byType(AppleGlassSlider),
        );
        expect(slider.activeColor, theme.colorScheme.primary);
      } else {
        expect(panel.height, greaterThanOrEqualTo(874 * .30));
        expect(panel.bottom, lessThanOrEqualTo(874 - 34));
        final slider = find.byType(Slider);
        expect(
          SliderTheme.of(tester.element(slider)).trackShape,
          isA<WavySliderTrackShape>(),
        );
        final play = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text('播放'),
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          ),
        );
        expect(play.style!.shape!.resolve({}), isA<StadiumBorder>());
        await tester.tap(find.byTooltip('下一段'));
        await tester.pumpAndSettle();
        expect(find.text('第 2/2段'), findsOneWidget);
        final track = tester.getRect(slider);
        await tester.tapAt(Offset(track.left + 24, track.center.dy));
        await tester.pumpAndSettle();
        expect(find.text('第 1/2段'), findsOneWidget);
        expect(engine.calls, isEmpty);
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

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
      Color? actionColor(String id) =>
          tester
              .widget<Material>(
                find
                    .descendant(
                      of: find.byKey(ValueKey(id)),
                      matching: find.byType(Material),
                    )
                    .first,
              )
              .color;
      final disabledColor = actionColor('reader-speech');
      expect(
        tester
            .widget<ReaderRoundAction>(
              find.byKey(const ValueKey('reader-speech')),
            )
            .onPressed,
        isNull,
      );
      chapter.value = _chapter;
      await tester.pumpAndSettle();
      expect(actionColor('reader-speech'), actionColor('reader-catalog'));
      expect(actionColor('reader-speech'), actionColor('reader-settings'));
      expect(actionColor('reader-speech'), isNot(disabledColor));
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
      final engine = _SpeechEngine();
      addTearDown(engine.close);

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
                                    speechEngine: engine,
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
      await tester.tap(find.text('第一个段落。'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 360));
      expect(engine.calls.single.text, '第一个段落。');
      engine.emit(engine.calls.single.id, 'done');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 360));
      final second = engine.calls.last;
      expect(second.text, '第二个段落。');
      expect(find.text('第 2/2段'), findsOneWidget);
      await tester.tapAt(const Offset(748, 300));
      await tester.pump();
      expect(find.byTooltip('暂停'), findsOneWidget);
      engine.emit(second.id, 'done');
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放'), findsOneWidget);
      expect(source.requests, isEmpty);
      await tester.tap(find.text('下一章'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 360));
      expect(source.requests, ['3']);
      final speak = engine.calls.last;
      expect(speak.text, _ListeningSource.second);
      engine.emit(speak.id, 'range', start: 3);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('打开听书页'), findsOneWidget);
      expect(writes.single.chapterId, '3');
      expect(writes.single.characters, 3);
      expect(writes.single.page, scrollReaderProgressPage);
      expect(detailPosition, same(writes.single));
      expect(engine.stopped, contains(speak.id));
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
  final _events = StreamController<ReaderSpeechEvent>.broadcast(sync: true);
  final calls = <({String id, String text})>[];
  final stopped = <String>[];
  bool nativePause = false;
  Future<bool>? resumeResponse;
  Future<void>? initialization;

  @override
  Stream<ReaderSpeechEvent> get events => _events.stream;

  @override
  Future<void> initialize() => initialization ?? Future.value();

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

class _AudioPlayer extends Fake implements AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final _plays = StreamController<int>.broadcast(sync: true);
  Completer<void>? _completion;
  int playCount = 0;
  final loadedPaths = <String>[];
  Stream<int> get plays => _plays.stream;

  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<PlayerException> get errorStream => const Stream.empty();

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loadedPaths.add(filePath);
    processingState = ProcessingState.ready;
    _publish();
    return const Duration(seconds: 1);
  }

  @override
  Future<void> play() async {
    _plays.add(++playCount);
    if (playing) return;
    playing = true;
    final completion = _completion = Completer<void>();
    _publish();
    await completion.future;
  }

  void completeClip() {
    processingState = ProcessingState.completed;
    _publish();
    _finishCommand();
  }

  void _publish() => _states.add(PlayerState(playing, processingState));

  void _finishCommand() {
    _completion?.complete();
    _completion = null;
  }

  @override
  Future<void> pause() async {
    playing = false;
    _publish();
    _finishCommand();
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await _plays.close();
  }
}

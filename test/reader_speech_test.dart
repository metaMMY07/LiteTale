import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/services/reader_speech.dart';
import 'package:wild/widgets/reader_speech_scope.dart';

void main() {
  test('segments preserve punctuation and skip illustrations', () {
    expect(
      readerSpeechSegments(
        '第一句。第二句。\n<!--image-->https://example.com/a.png<!--image-->',
        7,
      ),
      ['第一句。', '第二句。'],
    );
    expect(readerSpeechSegments('甲🙂乙', 2), ['甲', '🙂', '乙']);
  });

  test(
    'pause resumes at the confirmed range and ignores older events',
    () async {
      final engine = _SpeechEngine();
      final speech = ReaderSpeechController(engine: engine);
      addTearDown(engine.close);
      addTearDown(speech.dispose);

      await speech.prepare((text: '甲乙丙丁\n戊己', encoded: false));
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

    await speech.prepare((text: '测试章节', encoded: false));
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

    final pending = speech.prepare((text: '旧章节', encoded: false));
    speech.reset();
    engine.initialization = null;
    await speech.prepare((text: '需要字库的正文', encoded: true));
    expect(speech.ready, isFalse);
    expect(speech.canRetryInitialization, isFalse);
    await speech.prepare((text: '新章节', encoded: false));
    first.complete(_SpeechEngine.info);
    await pending;
    await speech.play();
    expect(engine.calls.single.text, '新章节');
    speech.reset();
    expect(engine.stopped, [engine.calls.single.id]);
    engine.emit(engine.calls.single.id, 'done');
    expect(speech.ready, isFalse);
    expect(ReaderSpeechController.isAnyPlaying, isFalse);
  });

  testWidgets(
    'the reader closes its speech panel and stops on chapter change',
    (tester) async {
      const commands = MethodChannel('litetale/reader_speech');
      const events = MethodChannel('litetale/reader_speech/events');
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(commands, (call) async {
        calls.add(call);
        return call.method == 'voices' ? {'limit': 1000, 'voices': []} : null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(commands, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      final chapter = ValueNotifier('第一章');
      addTearDown(chapter.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: chapter,
              builder:
                  (context, text, _) => ReaderSpeechScope(
                    chapter: (aid: 'book', cid: text),
                    readText: () => (text: text, encoded: false),
                    child: Builder(
                      builder:
                          (context) => TextButton(
                            onPressed: ReaderSpeechScope.openOf(context),
                            child: const Text('打开朗读'),
                          ),
                    ),
                  ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开朗读'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始朗读'));
      await tester.pumpAndSettle();
      final arguments =
          calls.singleWhere((call) => call.method == 'speak').arguments as Map;
      expect(arguments['text'], '第一章');

      chapter.value = '第二章';
      await tester.pumpAndSettle();
      expect(find.text('朗读'), findsNothing);
      expect(
        calls.singleWhere((call) => call.method == 'stop').arguments,
        arguments['id'],
      );
      expect(ReaderSpeechController.isAnyPlaying, isFalse);
    },
  );
}

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

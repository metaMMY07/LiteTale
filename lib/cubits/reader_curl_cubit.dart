import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/src/rust/api/database.dart';

enum ReaderPageEffect {
  slide('平移', 360),
  paper('纸页翻动', 440),
  cover('覆盖', 340),
  fade('渐隐', 300),
  none('无动画', 0),
  nativeCurl('原有仿真', 360);

  const ReaderPageEffect(this.label, this.milliseconds);

  final String label;
  final int milliseconds;

  static Iterable<ReaderPageEffect> available({required bool isIos}) =>
      isIos ? values.where((effect) => effect != nativeCurl) : values;

  ReaderPageEffect forPlatform({required bool isIos}) =>
      isIos && this == nativeCurl ? slide : this;
}

class ReaderCurlCubit extends Cubit<ReaderPageEffect> {
  ReaderCurlCubit({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => loadProperty(key: 'reader_page_curl_v1')),
       _write =
           write ??
           ((value) => saveProperty(key: 'reader_page_curl_v1', value: value)),
       super(ReaderPageEffect.slide);

  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  Future<void> _pendingWrite = Future.value();
  int _revision = 0;

  Future<void> load() async {
    final revision = _revision;
    try {
      final value = await _read();
      if (isClosed || revision != _revision) return;
      emit(
        value == 'true'
            ? ReaderPageEffect.nativeCurl
            : ReaderPageEffect.values.asNameMap()[value] ??
                ReaderPageEffect.slide,
      );
    } catch (_) {
      // Keep the current effect when settings are temporarily unavailable.
    }
  }

  Future<void> setEffect(ReaderPageEffect effect) async {
    _revision++;
    emit(effect);
    final value = switch (effect) {
      ReaderPageEffect.nativeCurl => 'true',
      ReaderPageEffect.slide => 'false',
      _ => effect.name,
    };
    final next = _pendingWrite.then((_) => _write(value));
    _pendingWrite = next.catchError((Object _) {});
    await next;
  }
}

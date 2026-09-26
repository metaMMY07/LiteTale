import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/src/rust/api/database.dart';

/// The book-like page curl is opt-in; the original reader remains the default.
class ReaderCurlCubit extends Cubit<bool> {
  ReaderCurlCubit({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => loadProperty(key: 'reader_page_curl_v1')),
       _write =
           write ??
           ((value) => saveProperty(key: 'reader_page_curl_v1', value: value)),
       super(false);

  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  Future<void> _pendingWrite = Future.value();
  int _revision = 0;

  Future<void> load() async {
    final revision = _revision;
    try {
      final value = await _read();
      if (!isClosed && revision == _revision) emit(value == 'true');
    } catch (_) {
      // An unset preference keeps the original, unanimated tap turns.
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _revision++;
    emit(enabled);
    final next = _pendingWrite.then((_) => _write(enabled.toString()));
    _pendingWrite = next.catchError((Object _) {});
    await next;
  }
}

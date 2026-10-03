import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/services/wenku8_host.dart';
import 'package:wild/src/rust/api/wenku8.dart';

class ApiHostCubit extends Cubit<String> {
  ApiHostCubit({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? getApiHost,
       _write = write ?? ((value) => setApiHost(apiHost: value)),
       super('') {
    initialized = _loadApiHost();
  }

  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  late final Future<void> initialized;

  Future<void> _loadApiHost() async {
    try {
      final apiHost = normalizeWenku8Host(await _read());
      if (!isClosed) emit(apiHost.isEmpty ? defaultWenku8Host : apiHost);
    } catch (_) {
      if (!isClosed) emit(defaultWenku8Host);
    }
  }

  Future<void> updateApiHost(String apiHost) async {
    final normalized = normalizeWenku8Host(apiHost);
    await initialized;
    try {
      await _write(normalized);
      if (!isClosed) {
        emit(normalized.isEmpty ? defaultWenku8Host : normalized);
      }
    } catch (_) {
      // 如果设置失败，重新加载当前值
      await _loadApiHost();
      rethrow;
    }
  }

  Future<void> resetToDefault() async {
    await updateApiHost('');
  }
}

import 'dart:convert';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:http/http.dart' as http;
import 'package:wild/utils/app_info.dart';
import 'package:wild/settings/app_logs.dart';

enum UpdatePhase { idle, checking, current, available, unpublished, failed }

class UpdateState extends Equatable {
  const UpdateState({
    this.updateInfo,
    this.hasCheckedOnStartup = false,
    this.phase = UpdatePhase.idle,
    this.message = '',
  });
  final VersionInfo? updateInfo;
  final bool hasCheckedOnStartup;
  final UpdatePhase phase;
  final String message;
  @override
  List<Object?> get props => [updateInfo, hasCheckedOnStartup, phase, message];
}

class VersionInfo extends Equatable {
  const VersionInfo({
    required this.version,
    required this.url,
    required this.body,
  });
  final String version;
  final String url;
  final String body;
  @override
  List<Object?> get props => [version, url, body];
}

/// SemVer comparison accepts the development tags used by LiteTale too.
int compareUpdateVersions(String a, String b) {
  List<String> parse(String value) {
    final m = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(value);
    if (m == null) throw const FormatException('不支持的版本号');
    return [m[1]!, m[2]!, m[3]!, m[4] ?? ''];
  }

  final aa = parse(a);
  final bb = parse(b);
  for (var i = 0; i < 3; i++) {
    final c = int.parse(aa[i]).compareTo(int.parse(bb[i]));
    if (c != 0) return c;
  }
  if (aa[3] == bb[3]) return 0;
  if (aa[3].isEmpty) return 1;
  if (bb[3].isEmpty) return -1;
  final ap = aa[3].split('.');
  final bp = bb[3].split('.');
  for (var i = 0; i < ap.length && i < bp.length; i++) {
    final ai = int.tryParse(ap[i]);
    final bi = int.tryParse(bp[i]);
    final c =
        ai != null && bi != null
            ? ai.compareTo(bi)
            : ai != null
            ? -1
            : bi != null
            ? 1
            : ap[i].compareTo(bp[i]);
    if (c != 0) return c;
  }
  return ap.length.compareTo(bp.length);
}

class UpdateCubit extends Cubit<UpdateState> {
  UpdateCubit({http.Client? client, String Function()? version})
    : _client = client ?? http.Client(),
      _version = version ?? (() => AppInfo.version),
      super(const UpdateState());
  final http.Client _client;
  final String Function() _version;
  String? _checkedChannel;

  Future<VersionInfo?> checkUpdate({
    bool force = false,
    String channel = 'stable',
  }) async {
    if (state.phase == UpdatePhase.checking) return null;
    if (state.hasCheckedOnStartup && !force && channel == _checkedChannel) {
      return null;
    }
    emit(
      UpdateState(
        hasCheckedOnStartup: state.hasCheckedOnStartup,
        phase: UpdatePhase.checking,
        message: '正在检查…',
      ),
    );
    try {
      final uri = Uri.parse(
        'https://api.github.com/repos/metaMMY07/LiteTale/releases?per_page=30',
      );
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent': 'LiteTale/${_version()}',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw StateError('Update server unavailable');
      }
      final list = jsonDecode(response.body) as List;
      final releases = <Map<String, dynamic>>[];
      for (final item in list) {
        if (item is! Map ||
            item['draft'] == true ||
            item['tag_name'] is! String) {
          continue;
        }
        final row = Map<String, dynamic>.from(item);
        final tag = row['tag_name'] as String;
        if (channel == 'stable' &&
            (row['prerelease'] == true || tag.contains('-'))) {
          continue;
        }
        try {
          compareUpdateVersions(tag, _version());
          releases.add(row);
        } on FormatException {
          continue;
        }
      }
      releases.sort(
        (a, b) => compareUpdateVersions(b['tag_name'], a['tag_name']),
      );
      _checkedChannel = channel;
      if (releases.isEmpty) {
        emit(
          const UpdateState(
            hasCheckedOnStartup: true,
            phase: UpdatePhase.unpublished,
            message: '此渠道尚未发布版本',
          ),
        );
        return null;
      }
      final latest = releases.first;
      if (compareUpdateVersions(latest['tag_name'], _version()) <= 0) {
        emit(
          const UpdateState(
            hasCheckedOnStartup: true,
            phase: UpdatePhase.current,
            message: '已是最新版本',
          ),
        );
        return null;
      }
      final releaseUri = Uri.tryParse('${latest['html_url']}');
      if (releaseUri == null ||
          releaseUri.scheme != 'https' ||
          releaseUri.host != 'github.com' ||
          !releaseUri.path.startsWith('/metaMMY07/LiteTale/releases/')) {
        throw const FormatException('更新链接无效');
      }
      final info = VersionInfo(
        version: latest['tag_name'],
        url: releaseUri.toString(),
        body: latest['body'] is String ? latest['body'] : '',
      );
      emit(
        UpdateState(
          updateInfo: info,
          hasCheckedOnStartup: true,
          phase: UpdatePhase.available,
          message: '发现 ${info.version}',
        ),
      );
      await AppLogs.instance.record('info', '更新检查完成：发现新版本');
      return info;
    } catch (_) {
      if (!isClosed) {
        emit(
          const UpdateState(
            phase: UpdatePhase.failed,
            message: '检查失败，请检查网络后重试',
          ),
        );
      }
      await AppLogs.instance.record('error', '更新检查失败');
      return null;
    }
  }

  @override
  Future<void> close() {
    _client.close();
    return super.close();
  }
}

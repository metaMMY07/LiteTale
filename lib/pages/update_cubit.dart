import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
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

const _releaseRepository = 'metaMMY07/LiteTale';
final _versionPattern = RegExp(
  r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
);
final _buildTag = RegExp(r'(?:-build|\+(?:build\.)?)(\d+)$');

typedef _ReleasePackage = ({String version, int build});

int? _buildFromTag(String tag) =>
    int.tryParse(_buildTag.firstMatch(tag)?.group(1) ?? '');

int? _installedBuildNumber() {
  final number = int.tryParse(AppInfo.buildNumber);
  if (number == null) return null;
  // Flutter's split APKs add the ABI offset to the release build number.
  return defaultTargetPlatform == TargetPlatform.android &&
          number >= 1000 &&
          number < 5000
      ? number % 1000
      : number;
}

/// SemVer comparison accepts the development tags used by LiteTale too.
int compareUpdateVersions(String a, String b) {
  List<String> parse(String value) {
    final m = _versionPattern.firstMatch(value);
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
  UpdateCubit({
    http.Client? client,
    String Function()? version,
    int? Function()? buildNumber,
  }) : _client = client ?? http.Client(),
       _version = version ?? (() => AppInfo.version),
       _buildNumber = buildNumber ?? _installedBuildNumber,
       super(const UpdateState());
  final http.Client _client;
  final String Function() _version;
  final int? Function() _buildNumber;
  String? _checkedChannel;
  String? _checkingChannel;
  Future<VersionInfo?>? _pending;
  String? _promptedUrl;

  bool markPromptShown(VersionInfo info) {
    if (info != state.updateInfo || info.url == _promptedUrl) return false;
    _promptedUrl = info.url;
    return true;
  }

  Future<VersionInfo?> checkUpdate({
    bool force = false,
    String channel = 'stable',
  }) {
    if (isClosed) return Future.value();
    if (_pending case final pending?) {
      return channel == _checkingChannel
          ? pending
          : pending.then((_) => checkUpdate(force: force, channel: channel));
    }
    if (state.hasCheckedOnStartup && !force && channel == _checkedChannel) {
      return Future.value(state.updateInfo);
    }
    _checkingChannel = channel;
    return _pending = _checkUpdate(channel).whenComplete(() {
      _pending = null;
      _checkingChannel = null;
    });
  }

  Future<VersionInfo?> _checkUpdate(String channel) async {
    emit(
      UpdateState(
        hasCheckedOnStartup: state.hasCheckedOnStartup,
        phase: UpdatePhase.checking,
        message: '正在检查…',
      ),
    );
    try {
      final installedVersion = _version();
      final uri = Uri.parse(
        'https://api.github.com/repos/$_releaseRepository/releases?per_page=30',
      );
      final response = await _client
          .get(
            uri,
            headers: {
              'User-Agent': 'LiteTale/$installedVersion',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (isClosed) return null;
      if (response.statusCode != 200) {
        throw StateError('Update server unavailable');
      }
      final list = jsonDecode(utf8.decode(response.bodyBytes)) as List;
      final releases =
          <
            ({
              String tag,
              String version,
              int publishedAt,
              Map<String, dynamic> data,
            })
          >[];
      ({String tag, int publishedAt, Map<String, dynamic> data})? newestLabel;
      for (final item in list) {
        if (item is! Map ||
            item['draft'] == true ||
            item['tag_name'] is! String) {
          continue;
        }
        final row = Map<String, dynamic>.from(item);
        final tag = row['tag_name'] as String;
        final stable = row['prerelease'] != true;
        if (channel == 'stable' && !stable) continue;
        final publishedAt =
            DateTime.tryParse(
              '${row['published_at']}',
            )?.millisecondsSinceEpoch ??
            0;
        final parsed = _versionPattern.firstMatch(tag);
        if (parsed == null) {
          if (newestLabel == null || publishedAt > newestLabel.publishedAt) {
            newestLabel = (tag: tag, publishedAt: publishedAt, data: row);
          }
          continue;
        }
        // A published build or fix has the same public version as its package.
        releases.add((
          tag: tag,
          version: stable ? '${parsed[1]}.${parsed[2]}.${parsed[3]}' : tag,
          publishedAt: publishedAt,
          data: row,
        ));
      }
      _ReleasePackage? labelPackage;
      if (newestLabel case final label?) {
        labelPackage = await _releasePackage(
          label.data['target_commitish'],
          label.tag,
        );
        if (isClosed) return null;
        if (labelPackage != null) {
          releases.add((
            tag: label.tag,
            version: labelPackage.version,
            publishedAt: label.publishedAt,
            data: label.data,
          ));
        }
      }
      releases.sort((a, b) {
        final version = compareUpdateVersions(b.version, a.version);
        if (version != 0) return version;
        final published = b.publishedAt.compareTo(a.publishedAt);
        if (published != 0) return published;
        return (_buildFromTag(b.tag) ?? 0).compareTo(_buildFromTag(a.tag) ?? 0);
      });
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
      var order = compareUpdateVersions(latest.version, installedVersion);
      var currentMessage = '已是最新版本';
      final installedBuild = _buildNumber();
      if (order == 0 && installedBuild != null) {
        final package =
            latest.tag == newestLabel?.tag
                ? labelPackage
                : await _releasePackage(
                  latest.data['target_commitish'],
                  latest.tag,
                );
        if (isClosed) return null;
        // A label such as build10 can differ from the package's build number.
        final build =
            package == null
                ? _buildFromTag(latest.tag)
                : compareUpdateVersions(package.version, latest.version) == 0
                ? package.build
                : null;
        if (build == null) {
          currentMessage = '已发布版本号与当前相同';
        } else {
          order = build.compareTo(installedBuild);
        }
      }
      if (order <= 0) {
        emit(
          UpdateState(
            hasCheckedOnStartup: true,
            phase: UpdatePhase.current,
            message: currentMessage,
          ),
        );
        return null;
      }
      final releaseUri = Uri.tryParse('${latest.data['html_url']}');
      if (releaseUri == null ||
          releaseUri.scheme != 'https' ||
          releaseUri.host != 'github.com' ||
          !releaseUri.path.startsWith('/$_releaseRepository/releases/')) {
        throw const FormatException('更新链接无效');
      }
      final info = VersionInfo(
        version: latest.tag,
        url: releaseUri.toString(),
        body: latest.data['body'] is String ? latest.data['body'] : '',
      );
      emit(
        UpdateState(
          updateInfo: info,
          hasCheckedOnStartup: true,
          phase: UpdatePhase.available,
          message: '发现 ${info.version}',
        ),
      );
      unawaited(AppLogs.instance.record('info', '更新检查完成：发现新版本'));
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
      unawaited(AppLogs.instance.record('error', '更新检查失败'));
      return null;
    }
  }

  Future<_ReleasePackage?> _releasePackage(Object? revision, String tag) async {
    // A branch can move on to a different package after publication.
    final ref =
        revision is String && RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)
            ? revision
            : 'refs/tags/$tag';
    try {
      final response = await _client
          .get(
            Uri.https(
              'raw.githubusercontent.com',
              '/$_releaseRepository/$ref/pubspec.yaml',
            ),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return null;
      final match = RegExp(
        r'^version:[ \t]*(v?\d+\.\d+\.\d+)\+(\d+)[ \t]*\r?$',
        multiLine: true,
      ).firstMatch(response.body);
      if (match == null) return null;
      final build = int.tryParse(match[2]!);
      return build == null ? null : (version: match[1]!, build: build);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() {
    _client.close();
    return super.close();
  }
}

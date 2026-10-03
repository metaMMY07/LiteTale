import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wild/src/rust/api/database.dart';

const hanVariantNames = <String, String>{
  'system': '跟随应用语言',
  'zh-CN': '简体中文（中国大陆）',
  'zh-TW': '繁体中文（台湾）',
  'zh-HK': '繁体中文（香港）',
  'ja-JP': '日文',
  'ko-KR': '韩文',
};

Locale? hanLocale(String variant) {
  if (variant == 'system') return null;
  final parts = variant.split('-');
  return Locale(parts.first, parts.length > 1 ? parts.last : null);
}

// A font's regional glyph choice must be identical in text measurement and
// drawing. This value changes only after the durable preference is written.
Locale? readerHanLocale;

SettingsPreferences settingsPreferencesOf(
  BuildContext context, {
  bool listen = true,
}) {
  try {
    return BlocProvider.of<SettingsPreferencesCubit>(
      context,
      listen: listen,
    ).state;
  } catch (_) {
    return const SettingsPreferences();
  }
}

class SettingsPreferences {
  const SettingsPreferences({
    this.autoUpdate = true,
    this.updateChannel = 'stable',
    this.hanVariant = 'system',
    this.logLevel = 'error',
    this.blackTheme = false,
    this.tapToTurn = true,
    this.boundaryChapters = true,
    this.preventBack = false,
  });

  final bool autoUpdate;
  final String updateChannel;
  final String hanVariant;
  final String logLevel;
  final bool blackTheme;
  final bool tapToTurn;
  final bool boundaryChapters;
  final bool preventBack;

  Map<String, Object> toJson() => {
    'version': 1,
    'autoUpdate': autoUpdate,
    'updateChannel': updateChannel,
    'hanVariant': hanVariant,
    'logLevel': logLevel,
    'blackTheme': blackTheme,
    'tapToTurn': tapToTurn,
    'boundaryChapters': boundaryChapters,
    'preventBack': preventBack,
  };

  factory SettingsPreferences.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1) throw const FormatException('设置版本不支持');
    const defaults = SettingsPreferences();
    bool flag(String key, bool fallback) {
      final v = value[key];
      if (v == null) return fallback;
      if (v is! bool) throw const FormatException('设置内容无效');
      return v;
    }

    String option(String key, String fallback, Iterable<String> allowed) {
      final v = value[key] ?? fallback;
      if (v is! String || !allowed.contains(v)) {
        throw const FormatException('设置选项无效');
      }
      return v;
    }

    return SettingsPreferences(
      autoUpdate: flag('autoUpdate', defaults.autoUpdate),
      updateChannel: option('updateChannel', 'stable', ['stable', 'preview']),
      hanVariant: option('hanVariant', 'system', hanVariantNames.keys),
      logLevel: option('logLevel', 'error', ['off', 'error', 'info', 'debug']),
      blackTheme: flag('blackTheme', false),
      tapToTurn: flag('tapToTurn', true),
      boundaryChapters: flag('boundaryChapters', true),
      preventBack: flag('preventBack', false),
    );
  }

  SettingsPreferences copyWith({
    bool? autoUpdate,
    String? updateChannel,
    String? hanVariant,
    String? logLevel,
    bool? blackTheme,
    bool? tapToTurn,
    bool? boundaryChapters,
    bool? preventBack,
  }) => SettingsPreferences(
    autoUpdate: autoUpdate ?? this.autoUpdate,
    updateChannel: updateChannel ?? this.updateChannel,
    hanVariant: hanVariant ?? this.hanVariant,
    logLevel: logLevel ?? this.logLevel,
    blackTheme: blackTheme ?? this.blackTheme,
    tapToTurn: tapToTurn ?? this.tapToTurn,
    boundaryChapters: boundaryChapters ?? this.boundaryChapters,
    preventBack: preventBack ?? this.preventBack,
  );
}

class SettingsPreferencesCubit extends Cubit<SettingsPreferences> {
  SettingsPreferencesCubit({
    Future<String> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => loadProperty(key: propertyKey)),
       _write = write ?? ((v) => saveProperty(key: propertyKey, value: v)),
       super(const SettingsPreferences());

  static const propertyKey = 'litetale.settings_v1';
  final Future<String> Function() _read;
  final Future<void> Function(String) _write;
  Future<void> _pending = Future.value();
  int _revision = 0;

  Future<void> initialize() async {
    final revision = _revision;
    var value = const SettingsPreferences();
    try {
      final raw = await _read();
      if (raw.isNotEmpty) {
        value = SettingsPreferences.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      }
    } catch (_) {
      // A corrupt optional preference cannot prevent guest startup.
    }
    if (!isClosed && revision == _revision) {
      readerHanLocale = hanLocale(value.hanVariant);
      emit(value);
    }
  }

  Future<void> update(
    SettingsPreferences Function(SettingsPreferences) change,
  ) {
    _revision++;
    final next = _pending.then((_) async {
      final value = change(state);
      // Revalidate externally supplied values before persisting them.
      SettingsPreferences.fromJson(value.toJson());
      await _write(jsonEncode(value.toJson()));
      if (!isClosed) {
        readerHanLocale = hanLocale(value.hanVariant);
        emit(value);
      }
    });
    _pending = next.catchError((Object _) {});
    return next;
  }
}

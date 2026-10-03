import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wild/src/rust/api/database.dart';

class ReaderBackgroundCubit extends Cubit<ReaderBackgroundState> {
  String? _rootPath;

  ReaderBackgroundCubit() : super(const ReaderBackgroundState());

  Future<void> init(String root) async {
    _rootPath = root;
    try {
      final raw = await loadProperty(key: 'reader_background_v1');
      if (raw.isNotEmpty) {
        final saved = jsonDecode(raw) as Map;
        if (saved['version'] == 1) {
          emit(
            state.copyWith(
              enabled: saved['enabled'] is bool ? saved['enabled'] : true,
              builtin: saved['builtin'] == true,
              lightFile: _safePaperName(
                saved['lightFile'],
                'light_reader_background.png',
              ),
              darkFile: _safePaperName(
                saved['darkFile'],
                'dark_reader_background.png',
              ),
              opacity:
                  saved['opacity'] is num
                      ? (saved['opacity'] as num).toDouble().clamp(0.0, 1.0)
                      : 0.1,
            ),
          );
        }
      }
    } catch (_) {
      /* Optional paper preferences use defaults on corruption. */
    }
    await _ensurePaperTexture();
    await _checkBackgroundImages();
  }

  String _safePaperName(Object? value, String fallback) =>
      value is String &&
              (value.isEmpty ||
                  value == fallback ||
                  RegExp(r'^snapshot_[a-f0-9]{64}\.png$').hasMatch(value))
          ? value
          : fallback;

  Future<void> _ensurePaperTexture() async {
    final file = File('$_rootPath/reader_paper_texture.png');
    if (await file.exists()) return;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xFFF1E2C2), ui.BlendMode.src);
    final random = Random(8);
    final paint = ui.Paint();
    for (var i = 0; i < 1700; i++) {
      paint.color = ui.Color.fromARGB(12 + random.nextInt(20), 120, 100, 70);
      canvas.drawRect(
        ui.Rect.fromLTWH(
          random.nextDouble() * 256,
          random.nextDouble() * 256,
          0.5,
          1.5,
        ),
        paint,
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(256, 256);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) {
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    image.dispose();
    picture.dispose();
  }

  Future<void> _save() => saveProperty(
    key: 'reader_background_v1',
    value: jsonEncode({
      'version': 1,
      'enabled': state.enabled,
      'opacity': state.opacity,
      'builtin': state.builtin,
      'lightFile': state.lightFile,
      'darkFile': state.darkFile,
    }),
  );

  Future<void> setEnabled(bool value) async {
    emit(state.copyWith(enabled: value));
    await _save();
  }

  Future<void> setBuiltin(bool value) async {
    emit(state.copyWith(builtin: value));
    await _save();
  }

  Future<void> _checkBackgroundImages() async {
    if (_rootPath == null) return;

    final lightPath = '$_rootPath/${state.lightFile}';
    final darkPath = '$_rootPath/${state.darkFile}';

    final lightExists = await File(lightPath).exists();
    final darkExists = await File(darkPath).exists();

    emit(
      state.copyWith(
        lightBackgroundExists: lightExists,
        darkBackgroundExists: darkExists,
      ),
    );
  }

  Future<void> updateLightBackground() async {
    if (_rootPath == null) return;

    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );

      if (image != null) {
        final bytes = await image.readAsBytes();
        final file = File('$_rootPath/light_reader_background.png');
        await file.writeAsBytes(bytes);
        await FileImage(file).evict();

        emit(
          state.copyWith(
            lightBackgroundExists: true,
            enabled: true,
            builtin: false,
            lightFile: 'light_reader_background.png',
          ),
        );
        await _save();
      }
    } catch (e) {
      // 处理错误
      rethrow;
    }
  }

  Future<void> updateDarkBackground() async {
    if (_rootPath == null) return;

    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );

      if (image != null) {
        final bytes = await image.readAsBytes();
        final file = File('$_rootPath/dark_reader_background.png');
        await file.writeAsBytes(bytes);
        await FileImage(file).evict();

        emit(
          state.copyWith(
            darkBackgroundExists: true,
            enabled: true,
            builtin: false,
            darkFile: 'dark_reader_background.png',
          ),
        );
        await _save();
      }
    } catch (e) {
      // 处理错误
      rethrow;
    }
  }

  Future<void> deleteLightBackground() async {
    if (_rootPath == null) return;

    try {
      final file = File('$_rootPath/${state.lightFile}');
      await FileImage(file).evict();

      emit(state.copyWith(lightBackgroundExists: false, lightFile: ''));
      await _save();
    } catch (e) {
      // 处理错误
      rethrow;
    }
  }

  Future<void> deleteDarkBackground() async {
    if (_rootPath == null) return;

    try {
      final file = File('$_rootPath/${state.darkFile}');
      await FileImage(file).evict();

      emit(state.copyWith(darkBackgroundExists: false, darkFile: ''));
      await _save();
    } catch (e) {
      // 处理错误
      rethrow;
    }
  }

  String? getLightBackgroundPath() {
    if (!state.enabled) return null;
    if (_rootPath != null && state.builtin) {
      return '$_rootPath/reader_paper_texture.png';
    }
    if (_rootPath == null || !state.lightBackgroundExists) return null;
    return '$_rootPath/${state.lightFile}';
  }

  String? getDarkBackgroundPath() {
    if (!state.enabled) return null;
    if (_rootPath != null && state.builtin) {
      return '$_rootPath/reader_paper_texture.png';
    }
    if (_rootPath == null || !state.darkBackgroundExists) return null;
    return '$_rootPath/${state.darkFile}';
  }

  Future<void> updateOpacity(double opacity) async {
    emit(state.copyWith(opacity: opacity.clamp(0.0, 1.0)));
    await _save();
  }
}

class ReaderBackgroundState {
  final bool lightBackgroundExists;
  final bool darkBackgroundExists;
  final double opacity;
  final bool enabled;
  final bool builtin;
  final String lightFile;
  final String darkFile;

  const ReaderBackgroundState({
    this.lightBackgroundExists = false,
    this.darkBackgroundExists = false,
    this.opacity = 0.1,
    this.enabled = true,
    this.builtin = false,
    this.lightFile = 'light_reader_background.png',
    this.darkFile = 'dark_reader_background.png',
  });

  ReaderBackgroundState copyWith({
    bool? lightBackgroundExists,
    bool? darkBackgroundExists,
    double? opacity,
    bool? enabled,
    bool? builtin,
    String? lightFile,
    String? darkFile,
  }) {
    return ReaderBackgroundState(
      lightBackgroundExists:
          lightBackgroundExists ?? this.lightBackgroundExists,
      darkBackgroundExists: darkBackgroundExists ?? this.darkBackgroundExists,
      opacity: opacity ?? this.opacity,
      enabled: enabled ?? this.enabled,
      builtin: builtin ?? this.builtin,
      lightFile: lightFile ?? this.lightFile,
      darkFile: darkFile ?? this.darkFile,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReaderBackgroundState &&
          runtimeType == other.runtimeType &&
          lightBackgroundExists == other.lightBackgroundExists &&
          darkBackgroundExists == other.darkBackgroundExists &&
          opacity == other.opacity &&
          enabled == other.enabled &&
          builtin == other.builtin &&
          lightFile == other.lightFile &&
          darkFile == other.darkFile;

  @override
  int get hashCode =>
      lightBackgroundExists.hashCode ^
      darkBackgroundExists.hashCode ^
      opacity.hashCode ^
      enabled.hashCode ^
      builtin.hashCode ^
      lightFile.hashCode ^
      darkFile.hashCode;
}

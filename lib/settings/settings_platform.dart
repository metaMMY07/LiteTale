import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('litetale/settings');

Future<bool> saveSettingsDocument(
  String name,
  Uint8List bytes, {
  String mime = 'application/octet-stream',
}) async {
  if (Platform.isAndroid) {
    return await _channel.invokeMethod<bool>('saveDocument', {
          'name': name,
          'mime': mime,
          'bytes': bytes,
        }) ??
        false;
  }
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return false;
  await XFile.fromData(bytes, name: name, mimeType: mime).saveTo(location.path);
  return true;
}

Future<int> settingsAndroidSdk() async =>
    Platform.isAndroid ? await _channel.invokeMethod<int>('sdk') ?? 0 : 0;

Future<bool> openAppLanguageSettings() async =>
    Platform.isAndroid
        ? await _channel.invokeMethod<bool>('appLanguage') ?? false
        : false;

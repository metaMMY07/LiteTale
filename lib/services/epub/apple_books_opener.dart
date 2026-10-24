import 'dart:io';

import 'package:flutter/services.dart';
import 'local_epub_library.dart';

/// The system chooses the receiving app. iOS has no public silent Books import.
class AppleBooksOpener {
  AppleBooksOpener({MethodChannel? channel, bool? isIOS})
    : _channel = channel ?? const MethodChannel('litetale/apple_books'),
      isSupported = isIOS ?? Platform.isIOS;

  static final instance = AppleBooksOpener();
  final MethodChannel _channel;
  final bool isSupported;
  bool _opening = false;

  Future<bool> open(
    LocalEpubLibrary library,
    String bookId, {
    bool Function()? isActive,
  }) async {
    if (!isSupported || _opening) return false;
    _opening = true;
    try {
      final file = await library.originalFileForOpening(bookId);
      if (isActive?.call() == false) return false;
      final response = await _channel.invokeMapMethod<String, dynamic>('open', {
        'path': file.path,
        'title': library.book(bookId)?.title ?? 'EPUB 电子书',
      });
      return response?['completed'] == true;
    } finally {
      _opening = false;
    }
  }
}

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/platform_controls.dart';

Future<void> openReaderImage(BuildContext context, ReaderImageRef image) =>
    Navigator.of(context).push<void>(
      Platform.isIOS
          ? CupertinoPageRoute(builder: (_) => ReaderImageViewer(image: image))
          : MaterialPageRoute(builder: (_) => ReaderImageViewer(image: image)),
    );

class ReaderImageViewer extends StatefulWidget {
  const ReaderImageViewer({super.key, required this.image, this.repository});
  final ReaderImageRef image;
  final ReaderImageRepository? repository;
  @override
  State<ReaderImageViewer> createState() => _ReaderImageViewerState();
}

class _ReaderImageViewerState extends State<ReaderImageViewer> {
  late Future<({ReaderImageData data, ImageProvider provider})> _image;
  ReaderImageData? _data;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  Future<({ReaderImageData data, ImageProvider provider})> _load({
    bool refresh = false,
  }) async {
    final repository = widget.repository ?? ReaderImageRepository.instance;
    if (refresh) repository.invalidate(widget.image);
    final data = await repository.read(widget.image);
    final buffer = await ui.ImmutableBuffer.fromUint8List(data.bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      final ratio = math.min(
        1.0,
        math.min(4096 / math.max(w, h), math.sqrt(8 * 1024 * 1024 / (w * h))),
      );
      final provider = ResizeImage(
        MemoryImage(data.bytes),
        width: math.max(1, (w * ratio).round()),
        height: math.max(1, (h * ratio).round()),
      );
      if (mounted) setState(() => _data = data);
      return (data: data, provider: provider);
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> _save(bool export) async {
    if (_saving || _data == null) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final result = await ReaderImageExporter.save(_data!, export: export);
      if (!mounted) return;
      setState(
        () =>
            _message = switch (result) {
              ReaderImageSaveResult.saved => '已保存到相册',
              ReaderImageSaveResult.exported => '已导出图片',
              ReaderImageSaveResult.cancelled => null,
            },
      );
    } on Object {
      if (mounted) {
        setState(
          () => _message = export ? '导出失败，请重试' : '未能保存到相册，可使用右侧“导出原图”保存到文件',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _retry() => setState(() {
    _data = null;
    _image = _load(refresh: true);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder(
          future: _image,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('图片加载失败', style: TextStyle(color: Colors.white)),
                    AppButton.text(onPressed: _retry, child: const Text('重试')),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const CenteredLoadingIndicator();
            }
            return PhotoView(
              imageProvider: snapshot.data!.provider,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              minScale: PhotoViewComputedScale.contained,
              initialScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4,
              enableRotation: false,
              loadingBuilder: (_, _) => const CenteredLoadingIndicator(),
              errorBuilder:
                  (_, _, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '图片解码失败',
                          style: TextStyle(color: Colors.white),
                        ),
                        AppButton.text(
                          onPressed: _retry,
                          child: const Text('重新加载原图'),
                        ),
                      ],
                    ),
                  ),
            );
          },
        ),
        SafeArea(
          child: Column(
            children: [
              ColoredBox(
                color: Colors.black54,
                child: Row(
                  children: [
                    AppIconButton(
                      tooltip: '关闭预览',
                      color: Colors.white,
                      icon: Icon(
                        Platform.isIOS ? CupertinoIcons.xmark : Icons.close,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        '图片预览',
                        style: TextStyle(color: Colors.white, fontSize: 17),
                      ),
                    ),
                    AppIconButton(
                      tooltip: '保存到相册',
                      color: Colors.white,
                      icon: Icon(
                        Platform.isIOS
                            ? CupertinoIcons.arrow_down_to_line
                            : Icons.save_alt,
                      ),
                      onPressed:
                          _saving || _data == null ? null : () => _save(false),
                    ),
                    AppIconButton(
                      tooltip: '导出原图',
                      color: Colors.white,
                      icon: Icon(
                        Platform.isIOS ? CupertinoIcons.share : Icons.ios_share,
                      ),
                      onPressed:
                          _saving || _data == null ? null : () => _save(true),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (_saving)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CenteredLoadingIndicator(),
                ),
              if (_message != null)
                Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

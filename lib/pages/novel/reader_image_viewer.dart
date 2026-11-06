import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:wild/services/reader_images.dart';
import 'package:wild/widgets/app_loading_indicator.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/platform_controls.dart';

Future<void> openReaderImage(BuildContext context, ReaderImageRef image) =>
    Navigator.of(context).push<void>(
      usesAppleGlass
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
  late Future<({ImageProvider provider, Size size})> _image;
  ReaderImageData? _data;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  Future<({ImageProvider provider, Size size})> _load({
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
      final width = math.max(1, (w * ratio).round());
      final height = math.max(1, (h * ratio).round());
      final provider = ResizeImage(
        MemoryImage(data.bytes),
        width: width,
        height: height,
      );
      if (mounted) setState(() => _data = data);
      return (
        provider: provider,
        size: Size(width.toDouble(), height.toDouble()),
      );
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

  void _close() {
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Widget _photo(ImageProvider provider, Size size) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.biggest;
      return PhotoView(
        imageProvider: provider,
        semanticLabel: '插图',
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        basePosition: Alignment.center,
        minScale: PhotoViewComputedScale.contained,
        initialScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        enableRotation: false,
        // PhotoView resolves this tap together with its zoom and pan gestures.
        // Its tap callback carries the transform used to draw this frame.
        onTapUp: (_, details, transform) {
          final scale =
              transform.scale ??
              math.min(
                viewport.width / size.width,
                viewport.height / size.height,
              );
          final bounds = Rect.fromCenter(
            center: viewport.center(transform.position),
            width: size.width * scale,
            height: size.height * scale,
          );
          if (!bounds.contains(details.localPosition)) _close();
        },
        loadingBuilder: (_, _) => const CenteredLoadingIndicator(),
        errorBuilder: (_, _, _) => _loadError('图片解码失败', '重新加载原图'),
      );
    },
  );

  Widget _loadError(String message, String retryLabel) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, style: const TextStyle(color: Colors.white)),
        AppButton.text(onPressed: _retry, child: Text(retryLabel)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Semantics(
    namesRoute: true,
    label: '图片预览',
    child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Before the image loads (or after an error), the empty canvas can
          // still be dismissed. Once ready, PhotoView owns all image gestures.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: _close,
          ),
          FutureBuilder(
            future: _image,
            builder: (context, snapshot) {
              if (snapshot.hasError) return _loadError('图片加载失败', '重试');
              final image = snapshot.data;
              if (image == null) return const CenteredLoadingIndicator();
              return _photo(image.provider, image.size);
            },
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _PreviewActions(
                  onClose: _close,
                  onSave: _saving || _data == null ? null : () => _save(false),
                  onExport: _saving || _data == null ? null : () => _save(true),
                ),
              ),
            ),
          ),
          if (_saving || _message != null)
            Positioned(
              bottom: 0,
              left: 16,
              right: 16,
              child: IgnorePointer(
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 12),
                  child: Center(
                    child:
                        _saving
                            ? const CenteredLoadingIndicator()
                            : DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Text(
                                  _message!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _PreviewActions extends StatelessWidget {
  const _PreviewActions({required this.onClose, this.onSave, this.onExport});

  final VoidCallback onClose;
  final VoidCallback? onSave, onExport;

  @override
  Widget build(BuildContext context) {
    final ios = usesAppleGlass;
    final colors = Theme.of(context).colorScheme;
    Widget action(
      String label,
      IconData apple,
      IconData material,
      VoidCallback? onPressed,
    ) =>
        ios
            ? SizedBox.square(
              dimension: 48,
              child: AppIconButton(
                tooltip: label,
                color: colors.onSurface.withValues(
                  alpha: onPressed == null ? .38 : 1,
                ),
                icon: Icon(apple),
                onPressed: onPressed,
              ),
            )
            : IconButton.filledTonal(
              tooltip: label,
              style: IconButton.styleFrom(minimumSize: const Size.square(48)),
              icon: Icon(material),
              onPressed: onPressed,
            );

    final close = action('关闭预览', CupertinoIcons.xmark, Icons.close, onClose);
    final save = action(
      '保存到相册',
      CupertinoIcons.arrow_down_to_line,
      Icons.download_rounded,
      onSave,
    );
    final export = action(
      '导出原图',
      CupertinoIcons.share,
      Icons.ios_share_rounded,
      onExport,
    );

    return Row(
      children: [
        ios ? AppleGlassSurface(capsule: true, child: close) : close,
        const Spacer(),
        if (ios)
          AppleGlassSurface(
            capsule: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [save, export],
            ),
          )
        else ...[
          save,
          const SizedBox(width: 8),
          export,
        ],
      ],
    );
  }
}

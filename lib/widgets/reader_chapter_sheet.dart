import 'package:flutter/material.dart';
import 'package:wild/src/rust/wenku8/models.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/apple_reader_panel.dart';

/// Directory selection returns a value. Dismissing either platform's sheet
/// never pops the reader, and chapter loading starts after dismissal completes.
Future<Chapter?> showReaderChapterSheet(
  BuildContext context, {
  required List<Volume> volumes,
  required String currentAid,
  required String currentCid,
}) async {
  if (usesAppleGlass && await AppleReaderPanel.available) {
    if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
      return null;
    }
    final colors = Theme.of(context).colorScheme;
    final chapters = <String, Chapter>{};
    final sections = <Map<String, Object?>>[];
    for (var v = 0; v < volumes.length; v++) {
      final rows = <Map<String, Object?>>[];
      for (var c = 0; c < volumes[v].chapters.length; c++) {
        final chapter = volumes[v].chapters[c], id = '$v:$c';
        chapters[id] = chapter;
        rows.add({
          'id': id,
          'kind': 'chapter',
          'title': chapter.title,
          'value': chapter.aid == currentAid && chapter.cid == currentCid,
        });
      }
      sections.add({'title': volumes[v].title, 'rows': rows});
    }
    final selection = await AppleReaderPanel.show(
      context,
      configuration:
          () => {
            'title': '目录',
            'dark': colors.brightness == Brightness.dark,
            'accent': colors.primary.toARGB32(),
            'sections': sections,
          },
    );
    return chapters[selection?['id']];
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<Chapter>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    // The draggable content owns the one handle; the theme also enables one.
    showDragHandle: false,
    elevation: 0,
    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width),
    builder:
        (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .55,
          minChildSize: .35,
          maxChildSize: .94,
          builder:
              (context, controller) => ReaderChapterPanel(
                volumes: volumes,
                currentAid: currentAid,
                currentCid: currentCid,
                scrollController: controller,
                onSelect: (chapter) => Navigator.pop(context, chapter),
              ),
        ),
  );
}

class ReaderChapterPanel extends StatefulWidget {
  const ReaderChapterPanel({
    super.key,
    required this.volumes,
    required this.currentAid,
    required this.currentCid,
    required this.scrollController,
    required this.onSelect,
  });
  final List<Volume> volumes;
  final String currentAid, currentCid;
  final ScrollController scrollController;
  final ValueChanged<Chapter> onSelect;
  @override
  State<ReaderChapterPanel> createState() => _ReaderChapterPanelState();
}

class _ReaderChapterPanelState extends State<ReaderChapterPanel> {
  late final List<Object> _rows;
  bool _positioned = false;
  @override
  void initState() {
    super.initState();
    _rows = [
      for (final volume in widget.volumes) ...[
        volume.title,
        ...volume.chapters,
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final extent = 72.0 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2);
    if (!_positioned) {
      _positioned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.scrollController.hasClients) return;
        final index = _rows.indexWhere(
          (r) =>
              r is Chapter &&
              r.aid == widget.currentAid &&
              r.cid == widget.currentCid,
        );
        if (index > 0) {
          widget.scrollController.jumpTo(
            (index * extent - 100).clamp(
              0,
              widget.scrollController.position.maxScrollExtent,
            ),
          );
        }
      });
    }
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: ColoredBox(
        color: colors.surfaceContainerLow,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  key: const ValueKey('reader-chapter-drag-handle'),
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant.withValues(alpha: .4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '目录',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭目录',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(overscroll: false),
                  child: ListView.builder(
                    controller: widget.scrollController,
                    itemExtent: extent,
                    itemCount: _rows.length,
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      if (row is String) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              row,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        );
                      }
                      final chapter = row as Chapter;
                      final selected =
                          chapter.aid == widget.currentAid &&
                          chapter.cid == widget.currentCid;
                      // Ink must move and clip with this row. Painting on the
                      // outer sheet's Material leaks selection colour on scroll.
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        child: Material(
                          color:
                              selected
                                  ? colors.secondaryContainer
                                  : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            key: ValueKey('reader-chapter-$index'),
                            title: Text(
                              chapter.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            selected: selected,
                            selectedColor: colors.onSecondaryContainer,
                            tileColor: Colors.transparent,
                            selectedTileColor: Colors.transparent,
                            trailing: selected ? const Icon(Icons.check) : null,
                            onTap: () => widget.onSelect(chapter),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

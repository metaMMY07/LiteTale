import 'package:flutter/material.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/bookshelf_tile.dart';
import 'package:wild/widgets/platform_controls.dart';

typedef BookshelfDestination =
    ({String title, String? folderId, String? siteGroupId});

Future<String?> showBookshelfFolderName(
  BuildContext context, {
  String? initialName,
}) => showAppBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useGlass: false,
  useSafeArea: true,
  showDragHandle: true,
  builder:
      (sheetContext) => _ShelfSheet(
        title: initialName == null ? '新建文件夹' : '重命名文件夹',
        body: _FolderNameField(initialName: initialName),
      ),
);

Future<BookshelfDestination?> showBookshelfMoveSheet(
  BuildContext context, {
  required int bookCount,
  required List<BookshelfDestination> destinations,
}) => showAppBottomSheet<BookshelfDestination>(
  context: context,
  isScrollControlled: true,
  useGlass: false,
  useSafeArea: true,
  showDragHandle: true,
  builder:
      (sheetContext) => _ShelfSheet(
        title: '移动 $bookCount 本书',
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('选择目标文件夹', style: Theme.of(sheetContext).textTheme.bodySmall),
            const SizedBox(height: 12),
            Flexible(
              child: Material(
                color: Theme.of(sheetContext).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: destinations.length,
                  itemBuilder: (context, index) {
                    final destination = destinations[index];
                    return ListTile(
                      leading: ShelfIcon(
                        destination.folderId == null &&
                                destination.siteGroupId == null
                            ? ShelfSymbol.root
                            : ShelfSymbol.folder,
                        size: 21,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(destination.title),
                      subtitle:
                          destination.siteGroupId == null
                              ? null
                              : const Text('文库8原站分组'),
                      onTap: () => Navigator.of(sheetContext).pop(destination),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
);

class _ShelfSheet extends StatelessWidget {
  const _ShelfSheet({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final bottom =
        usesAppleGlass ? 0.0 : MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .62,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (usesAppleGlass) ...[
                  Center(
                    child: Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Flexible(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderNameField extends StatefulWidget {
  const _FolderNameField({this.initialName});

  final String? initialName;

  @override
  State<_FolderNameField> createState() => _FolderNameFieldState();
}

class _FolderNameFieldState extends State<_FolderNameField> {
  late final _controller = TextEditingController(text: widget.initialName);

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: '请输入文件夹名称',
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
            border: OutlineInputBorder(
              borderSide: BorderSide.none,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: ValueListenableBuilder(
            valueListenable: _controller,
            builder:
                (context, value, _) => FilledButton.icon(
                  onPressed: value.text.trim().isEmpty ? null : _submit,
                  icon: ShelfIcon(
                    ShelfSymbol.check,
                    size: 17,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  label: Text(widget.initialName == null ? '创建文件夹' : '确认重命名'),
                ),
          ),
        ),
      ],
    ),
  );
}

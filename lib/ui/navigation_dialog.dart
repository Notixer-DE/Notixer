import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart' show PdfOutlineItem;
import '../editor/navigation.dart';

/// The PDF outline is the single source of truth for imported and own bookmarks.
class NavigationDialog extends StatelessWidget {
  const NavigationDialog({
    super.key,
    required this.editing,
    required this.navigation,
  });

  final PdfEditingController editing;
  final PaneNavigation navigation;

  Future<void> _name(
    BuildContext context, {
    List<int>? path,
    String? title,
  }) async {
    final page = navigation.viewer.currentPage.clamp(
      0,
      editing.document.pageCount - 1,
    );
    var text = title ?? 'Page ${page + 1}';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(path == null ? 'Add bookmark' : 'Rename'),
          content: TextFormField(
            initialValue: text,
            autofocus: true,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (value) => setState(() => text = value),
            onFieldSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (context.mounted && result != null) {
      editing.finishInk();
      if (path == null) {
        editing.addBookmark(result, pageIndex: page);
      } else {
        // Rename only: preserve imported XYZ/FitH destinations and their zoom.
        editing.editBookmark(path, title: result);
      }
    }
  }

  Future<void> _delete(
    BuildContext context,
    List<int> path,
    PdfOutlineItem item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete bookmark?'),
        content: Text(
          '“${item.title}” will be deleted.'
          '${item.children.isEmpty ? '' : ' Child entries will also be deleted.'}'
          'You can undo this in the editor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (context.mounted && confirmed == true) {
      editing.finishInk();
      editing.deleteBookmark(path);
    }
  }

  List<Widget> _items(
    BuildContext context,
    List<PdfOutlineItem> items, [
    List<int> prefix = const [],
  ]) => [
    for (var i = 0; i < items.length; i++)
      _item(context, items[i], [...prefix, i]),
  ];

  Widget _item(BuildContext context, PdfOutlineItem item, List<int> path) {
    final destination = item.destination;
    final available =
        destination != null &&
        destination.pageIndex >= 0 &&
        destination.pageIndex < editing.document.pageCount;
    final tile = ListTile(
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        !available
            ? 'No available page target'
            : 'Page ${destination.pageIndex + 1}',
      ),
      onTap: !available
          ? null
          : () {
              navigation.showDestination(destination);
              Navigator.pop(context);
            },
      trailing: PopupMenuButton<String>(
        tooltip: 'Bookmark actions',
        onSelected: (action) {
          if (action == 'rename') {
            _name(context, path: path, title: item.title);
          } else {
            _delete(context, path, item);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
    if (item.children.isEmpty) return tile;
    return ExpansionTile(
      key: PageStorageKey(path.join('.')),
      initiallyExpanded: item.open,
      title: tile,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 16),
      children: _items(context, item.children, path),
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 520,
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        children: [
          ListTile(
            title: const Text('Bookmarks and table of contents'),
            trailing: IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: () => _name(context),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Bookmark current page'),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: editing,
              builder: (context, _) {
                final items = editing.outline.items;
                return items.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No bookmarks yet. This PDF has no table of contents.',
                          ),
                        ),
                      )
                    : ListView(children: _items(context, items));
              },
            ),
          ),
        ],
      ),
    ),
  );
}

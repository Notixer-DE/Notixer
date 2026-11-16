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
    final text = TextEditingController(text: title ?? 'Seite ${page + 1}');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(path == null ? 'Lesezeichen anlegen' : 'Umbenennen'),
          content: TextField(
            controller: text,
            autofocus: true,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: text.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, text.text.trim()),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    // The dialog route may still be animating out with the field attached.
    if (context.mounted && result != null) {
      editing.finishInk();
      if (path == null) {
        editing.addBookmark(result, pageIndex: page);
      } else {
        // Rename only: preserve imported XYZ/FitH destinations and their zoom.
        editing.editBookmark(path, title: result);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
  }

  Future<void> _delete(
    BuildContext context,
    List<int> path,
    PdfOutlineItem item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lesezeichen löschen?'),
        content: Text(
          '„${item.title}“ wird gelöscht.'
          '${item.children.isEmpty ? '' : ' Untergeordnete Einträge werden ebenfalls gelöscht.'}'
          ' Rückgängig ist im Editor möglich.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
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
            ? 'Kein verfügbares Seitenziel'
            : 'Seite ${destination.pageIndex + 1}',
      ),
      onTap: !available
          ? null
          : () {
              navigation.showDestination(destination);
              Navigator.pop(context);
            },
      trailing: PopupMenuButton<String>(
        tooltip: 'Lesezeichenaktionen',
        onSelected: (action) {
          if (action == 'rename') {
            _name(context, path: path, title: item.title);
          } else {
            _delete(context, path, item);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
          PopupMenuItem(value: 'delete', child: Text('Löschen')),
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
            title: const Text('Lesezeichen & Inhaltsverzeichnis'),
            trailing: IconButton(
              tooltip: 'Schließen',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: () => _name(context),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Aktuelle Seite merken'),
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
                            'Noch keine Lesezeichen. Dieses PDF enthält kein Inhaltsverzeichnis.',
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

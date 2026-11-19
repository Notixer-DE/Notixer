import 'package:flutter/material.dart';
import '../data/catalog.dart';
import '../data/notebook.dart';
import 'noter_theme.dart';
import 'workspace_chrome.dart';

/// The same organization controls serve the desktop sidebar and phone drawer.
class LibraryNavigation extends StatelessWidget {
  const LibraryNavigation({
    super.key,
    required this.notes,
    required this.folders,
    required this.folder,
    required this.tag,
    required this.enabled,
    required this.onFolder,
    required this.onTag,
    required this.onManage,
  });

  final List<Notebook> notes;
  final List<NoteFolder> folders;
  final String? folder, tag;
  final bool enabled;
  final ValueChanged<String?> onFolder, onTag;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final tags = notes.expand((n) => n.tags).toSet().toList()..sort();
    Widget entry(String title, IconData icon, String? id, int count) =>
        ListTile(
          selected: folder == id,
          leading: Icon(icon, size: 20),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(
            '$count',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          onTap: enabled ? () => onFolder(id) : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          selectedTileColor: NoterTheme.active,
        );
    return WorkspaceSidebar(
      child: Material(
        color: Colors.white,
        child: ListTileTheme(
          data: ListTileThemeData(
            minLeadingWidth: 18,
            horizontalTitleGap: 10,
            dense: NoterTheme.desktopControls(context),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            titleTextStyle: Theme.of(context).textTheme.bodyMedium,
          ),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Text(
                  'LIBRARY',
                  style: TextStyle(
                    letterSpacing: .8,
                    fontSize: 10,
                    color: NoterTheme.muted,
                  ),
                ),
              ),
              entry('All notes', Icons.grid_view_outlined, null, notes.length),
              entry(
                'Unfiled',
                Icons.folder_outlined,
                '',
                notes
                    .where(
                      (n) => !folders.any((folder) => folder.id == n.folderId),
                    )
                    .length,
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text(
                  'FOLDERS',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: .8,
                    color: NoterTheme.muted,
                  ),
                ),
                trailing: IconButton(
                  tooltip: 'Manage folders',
                  onPressed: enabled ? onManage : null,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                ),
              ),
              for (final f in folders)
                entry(
                  f.name,
                  Icons.folder_outlined,
                  f.id,
                  notes.where((n) => n.folderId == f.id).length,
                ),
              if (tags.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
                  child: Text(
                    'TAGS',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: .8,
                      color: NoterTheme.muted,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in tags)
                      FilterChip(
                        label: Text('#$t'),
                        selected: tag == t,
                        onSelected: enabled
                            ? (_) => onTag(tag == t ? null : t)
                            : null,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

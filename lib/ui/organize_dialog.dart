import 'package:flutter/material.dart';
import '../data/notebook.dart';

class OrganizeDialog extends StatefulWidget {
  const OrganizeDialog({
    super.key,
    required this.note,
    required this.repository,
  });
  final Notebook note;
  final NotebookRepository repository;
  @override
  State<OrganizeDialog> createState() => _OrganizeDialogState();
}

class _OrganizeDialogState extends State<OrganizeDialog> {
  late String folder =
      widget.repository.catalog.folderName(widget.note.folderId) == null
      ? ''
      : widget.note.folderId!;
  late final tags = TextEditingController(text: widget.note.tags.join(', '));
  @override
  void dispose() {
    tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Ordner und Tags'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: widget.repository.catalog.folderName(folder) == null
                ? ''
                : folder,
            decoration: const InputDecoration(labelText: 'Ordner'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Ohne Ordner')),
              for (final f in widget.repository.catalog.folders)
                DropdownMenuItem(
                  value: f.id,
                  child: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => folder = v!,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: tags,
            decoration: const InputDecoration(
              labelText: 'Tags',
              helperText: 'Mit Komma trennen, z. B. Mathe, Prüfung',
            ),
            maxLines: 2,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () {
          final unique = <String, String>{};
          for (final t in tags.text.split(',')) {
            final value = t.trim();
            if (value.isNotEmpty) {
              unique.putIfAbsent(value.toLowerCase(), () => value);
            }
          }
          Navigator.pop(
            context,
            widget.note.copy(
              folderId: folder.isEmpty ? null : folder,
              folderName: widget.repository.catalog.folderName(folder),
              clearFolder: folder.isEmpty,
              tags: unique.values.toList(),
            ),
          );
        },
        child: const Text('Speichern'),
      ),
    ],
  );
}

class FolderManager extends StatefulWidget {
  const FolderManager({super.key, required this.repository});
  final NotebookRepository repository;
  @override
  State<FolderManager> createState() => _FolderManagerState();
}

class _FolderManagerState extends State<FolderManager> {
  bool busy = false;
  String? error;
  Future<String?> _name(String initial) async {
    final form = GlobalKey<FormState>();
    var name = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(initial.isEmpty ? 'Ordner anlegen' : 'Ordner umbenennen'),
        content: Form(
          key: form,
          child: TextFormField(
            initialValue: initial,
            onChanged: (value) => name = value,
            autofocus: true,
            maxLength: 80,
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Bitte einen Ordnernamen eingeben.'
                : null,
            decoration: const InputDecoration(labelText: 'Ordnername'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, name.trim());
              }
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete(String id) async {
    final notes = (await widget.repository.list())
        .where((n) => n.folderId == id)
        .toList();
    if (!mounted) return;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Ordner löschen?'),
        content: Text(
          notes.length == 1
              ? 'Eine Notiz wird nach „Ohne Ordner“ verschoben. Die Notiz bleibt erhalten.'
              : '${notes.length} Notizen werden nach „Ohne Ordner“ verschoben. Die Notizen bleiben erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ordner löschen'),
          ),
        ],
      ),
    );
    if (answer != true) return;
    // Retain the folder if any document cannot be moved; never remove notes.
    for (final n in notes) {
      await widget.repository.save(
        n.copy(clearFolder: true),
        await widget.repository.load(n.id),
      );
    }
    await widget.repository.catalog.removeFolder(id);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      child: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Ordner verwalten',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Schließen',
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.repository.catalog,
                builder: (context, _) => ListView(
                  children: [
                    for (final folder in widget.repository.catalog.folders)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.name),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Ordner umbenennen',
                              onPressed: busy
                                  ? null
                                  : () => run(() async {
                                      final name = await _name(folder.name);
                                      if (name != null) {
                                        await widget.repository.catalog
                                            .renameFolder(folder.id, name);
                                      }
                                    }),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'Ordner löschen',
                              onPressed: busy
                                  ? null
                                  : () => run(() => _delete(folder.id)),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    if (widget.repository.catalog.folders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Noch keine Ordner. Lege zum Beispiel einen Ordner für ein Fach an.',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final name = await _name('');
                        if (name != null) {
                          await widget.repository.catalog.ensureFolder(name);
                        }
                      }),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Ordner anlegen'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

import 'markdown_document.dart';
import 'markdown_library.dart';
import 'notebook.dart';

class LibraryGraphNode {
  const LibraryGraphNode(this.id, this.label, {this.note});
  final String id, label;
  final Notebook? note;
  bool get isTag => note == null;
}

typedef LibraryGraphEdge = ({String from, String to});

/// Links to headings or PDF pages still connect their containing files.
class LibraryGraph {
  const LibraryGraph(this.nodes, this.edges, this.warnings);
  final List<LibraryGraphNode> nodes;
  final Set<LibraryGraphEdge> edges;
  final List<String> warnings;

  static Future<LibraryGraph> load(
    NotebookRepository repository, {
    Map<String, String> sourceOverrides = const {},
  }) async {
    final notes = await repository.list();
    final nodes = <LibraryGraphNode>[
      for (final note in notes)
        LibraryGraphNode('note:${note.id}', note.title, note: note),
    ];
    final tags = <String, String>{};
    final edges = <LibraryGraphEdge>{};
    final warnings = <String>[];
    for (final note in notes) {
      for (final raw in note.tags) {
        final tag = raw.trim();
        if (tag.isEmpty) continue;
        final id = 'tag:${tag.toLowerCase()}';
        tags.putIfAbsent(id, () => tag);
        edges.add((from: 'note:${note.id}', to: id));
      }
      if (!note.isMarkdown) continue;
      try {
        final source =
            sourceOverrides[note.id] ??
            (await decodeMarkdownAsync(await repository.load(note.id))).source;
        for (final link in markdownLinks(source).where((link) => !link.image)) {
          final target = MarkdownLibrary.target(notes, note, link.href);
          if (target != null && target.id != note.id) {
            edges.add((from: 'note:${note.id}', to: 'note:${target.id}'));
          }
        }
      } catch (error) {
        warnings.add('Could not read links in ${note.title}: $error');
      }
    }
    nodes.addAll(
      tags.entries.map(
        (entry) => LibraryGraphNode(entry.key, '#${entry.value}'),
      ),
    );
    return LibraryGraph(
      List.unmodifiable(nodes),
      Set.unmodifiable(edges),
      List.unmodifiable(warnings),
    );
  }
}

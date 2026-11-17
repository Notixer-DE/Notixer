import 'dart:isolate';
import 'dart:typed_data';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import '../data/notebook.dart';
import '../data/markdown_document.dart';
import 'notebook_cover.dart';
import 'noter_theme.dart';
import 'pdf_thumbnail.dart';

Future<Uint8List?> _extractFirstPage(Uint8List bytes) => Isolate.run(() {
  final document = pdf.PdfDocument.open(bytes);
  final page = document.extractPages([0]);
  return page.length <= 2 * 1024 * 1024 ? page : null;
});

class _PreviewRequest {
  _PreviewRequest(bool Function() wanted) : waiters = [wanted];
  final List<bool Function()> waiters;
  late Future<PdfDocument?> future;
  bool complete = false;
  bool get wanted => waiters.any((check) => check());
}

/// Visible cards request previews lazily. One document is processed at a time,
/// away from the UI isolate. Only eight small, single-page PDFs are retained.
/// Large or unreadable documents keep their paper-type cover.
class NotebookPreviewCache {
  NotebookPreviewCache(this.repository);
  final NotebookRepository repository;
  final _entries = <String, _PreviewRequest>{};
  Future<void> _queue = Future.value();
  bool _disposed = false;

  Future<PdfDocument?> load(Notebook note, bool Function() wanted) {
    if (note.isMarkdown) return Future.value(null);
    final key = '${note.id}:${note.modified.microsecondsSinceEpoch}';
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      if (!existing.complete) existing.waiters.add(wanted);
      return existing.future;
    }
    final request = _PreviewRequest(wanted);
    final result = _queue.then((_) async {
      var cancelled = false;
      try {
        if (_disposed || !request.wanted) {
          cancelled = true;
          return null;
        }
        final bytes = repository is LocalNotebookRepository
            ? await (repository as LocalNotebookRepository).loadPdf(note.id)
            : await repository.load(note.id);
        if (_disposed || !request.wanted) {
          cancelled = true;
          return null;
        }
        if (bytes.length > 32 * 1024 * 1024) {
          return null;
        }
        final page = await _extractFirstPage(bytes);
        return page == null || _disposed ? null : PdfDocument.open(page);
      } catch (_) {
        // A failed preview must not prevent opening/exporting a notebook.
        return null;
      } finally {
        request.complete = true;
        request.waiters.clear();
        if (cancelled && identical(_entries[key], request)) {
          _entries.remove(key);
        }
      }
    });
    request.future = result;
    _queue = result.then<void>((_) {});
    _entries[key] = request;
    while (_entries.length > 8) {
      _entries.remove(_entries.keys.first);
    }
    return result;
  }

  void dispose() {
    _disposed = true;
    _entries.clear();
  }
}

class NotebookPreview extends StatefulWidget {
  const NotebookPreview({
    super.key,
    required this.note,
    required this.cache,
    this.height = 136,
  });
  final Notebook note;
  final NotebookPreviewCache cache;
  final double height;
  @override
  State<NotebookPreview> createState() => _NotebookPreviewState();
}

class _NotebookPreviewState extends State<NotebookPreview> {
  late Future<PdfDocument?> _page = _load();
  Future<PdfDocument?> _load() => widget.cache.load(widget.note, () => mounted);

  @override
  void didUpdateWidget(covariant NotebookPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id ||
        oldWidget.note.modified != widget.note.modified ||
        oldWidget.cache != widget.cache) {
      _page = _load();
    }
  }

  @override
  Widget build(BuildContext context) => widget.note.isMarkdown
      ? _MarkdownPreview(
          key: ValueKey('${widget.note.id}:${widget.note.modified}'),
          note: widget.note,
          repository: widget.cache.repository,
          height: widget.height,
        )
      : FutureBuilder(
          future: _page,
          builder: (context, snapshot) {
            if (snapshot.data == null) {
              return NotebookCover(
                paper: widget.note.paper,
                height: widget.height,
              );
            }
            final page = snapshot.data!.page(0);
            return Semantics(
              label: 'First-page preview',
              child: ExcludeSemantics(
                child: Container(
                  height: widget.height,
                  color: NoterTheme.workspace,
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                  child: Stack(
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: page.rotation % 180 == 0
                              ? page.cropBox.width / page.cropBox.height
                              : page.cropBox.height / page.cropBox.width,
                          child: IgnorePointer(child: PdfThumbnail(page: page)),
                        ),
                      ),
                      Align(
                        alignment: Alignment.topLeft,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              NotebookCover(paper: widget.note.paper).label,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
}

Future<(String, int, int)> _markdownPreview(
  NotebookRepository repository,
  String id,
) async {
  final bytes = await repository.load(id);
  return Isolate.run(() {
    final source = MarkdownDocument.decode(bytes).source;
    final offsets = markdownTaskOffsets(source);
    final text = parseMarkdown(source).map((n) => n.textContent).join('\n');
    return (
      text.length > 280 ? '${text.substring(0, 280)}…' : text,
      offsets.where((i) => source[i].toLowerCase() == 'x').length,
      offsets.length,
    );
  });
}

class _MarkdownPreview extends StatefulWidget {
  const _MarkdownPreview({
    super.key,
    required this.note,
    required this.repository,
    required this.height,
  });
  final Notebook note;
  final NotebookRepository repository;
  final double height;
  @override
  State<_MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<_MarkdownPreview> {
  late final _preview = _markdownPreview(widget.repository, widget.note.id);
  @override
  Widget build(BuildContext context) => Container(
    height: widget.height,
    color: NoterTheme.workspace,
    padding: const EdgeInsets.fromLTRB(16, 14, 42, 12),
    child: FutureBuilder(
      future: _preview,
      builder: (context, snapshot) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MARKDOWN',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: NoterTheme.muted),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              snapshot.data?.$1 ?? 'Text note',
              overflow: TextOverflow.fade,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (snapshot.data != null && snapshot.data!.$3 > 0)
            Text(
              '${snapshot.data!.$2} / ${snapshot.data!.$3} erledigt',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    ),
  );
}

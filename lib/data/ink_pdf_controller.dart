import 'dart:typed_data';
import 'dart:ui';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import 'ink.dart';
import 'ink_pages.dart';

/// Keeps the library's shortcuts/toolbars on one chronological undo stack.
/// The library still owns PDF edits; ink edits never become PDF revisions.
class InkPdfController extends PdfEditingController {
  InkPdfController(super.bytes, {required super.preferences});
  void Function()? notebookUndo, notebookRedo;
  void Function(VoidCallback)? notebookTransaction;
  bool Function()? notebookCanUndo, notebookCanRedo;
  InkDocument Function()? inkSnapshot;
  InkController Function()? inkController;
  List<InkStroke> _clipboard = [];
  bool _clipboardHasPdf = false;
  bool _pdfHistory = false;
  // Match the PDF library's process-wide page clipboard by exact buffer
  // identity. Unrelated clipboard replacements cannot inherit stale ink.
  static final _pageInks = Expando<InkPages>();

  Future<InkPages> editablePages(List<int> indices) => extractInkPagesAsync(
    bytes,
    inkSnapshot?.call() ?? InkDocument(generation: newInkId()),
    indices,
  );

  void insertEditablePages(InkPages pages, {int? at}) => _transaction(() {
    final position = (at ?? document.pageCount).clamp(0, document.pageCount);
    final source = pdf.PdfDocument.open(pages.bytes);
    final ink = inkController?.call();
    if (ink == null && pages.ink.strokes.isNotEmpty) {
      throw StateError('The ink layer is not available yet.');
    }
    if (ink != null &&
        (ink.index.strokes.length + pages.ink.strokes.length >
                InkDocument.maxStrokes ||
            ink.index.strokes.fold<int>(0, (n, s) => n + s.pointCount) +
                    pages.ink.strokes.fold<int>(0, (n, s) => n + s.pointCount) >
                InkDocument.maxPoints)) {
      throw StateError('The ink layer is full. Please create a new note.');
    }
    super.insertPagesFromBytes(freshPageTapeIds(pages.bytes), at: position);
    if (ink == null) return;
    final strokes = copiedPageInk(
      pages.ink,
      source,
      List.generate(source.pageCount, (i) => i),
      document,
      at: position,
      order: ink.nextOrder,
    );
    if (strokes.isNotEmpty) ink.apply(InkEdit(add: strokes));
  });

  Future<bool> copyEditablePages(List<int> indices) async {
    final pages = await editablePages(indices);
    _setPageClipboard(pages);
    return true;
  }

  void _setPageClipboard(InkPages pages) {
    final count = pdf.PdfDocument.open(pages.bytes).pageCount;
    _pageInks[pages.bytes] = pages;
    pageClipboard.setPages(pages.bytes, count);
  }

  @override
  bool copyPages(Iterable<int> indices) {
    final targets =
        indices.where((i) => i >= 0 && i < document.pageCount).toSet().toList()
          ..sort();
    if (targets.isEmpty) return false;
    _setPageClipboard(
      extractInkPages(
        bytes,
        inkSnapshot?.call() ?? InkDocument(generation: newInkId()),
        targets,
      ),
    );
    return true;
  }

  @override
  bool cutPages(Iterable<int> indices) => _transaction(() {
    final targets =
        indices.where((i) => i >= 0 && i < document.pageCount).toSet().toList()
          ..sort();
    if (targets.isEmpty || targets.length >= document.pageCount) return false;
    copyPages(targets);
    return removePages(targets);
  });

  @override
  bool pastePages({int? at}) =>
      pasteEditablePages(at: at) || super.pastePages(at: at);

  @override
  bool duplicatePages(Iterable<int> indices) {
    final targets =
        indices.where((i) => i >= 0 && i < document.pageCount).toSet().toList()
          ..sort();
    if (targets.isEmpty) return false;
    final pages = extractInkPages(
      bytes,
      inkSnapshot?.call() ?? InkDocument(generation: newInkId()),
      targets,
    );
    insertEditablePages(pages, at: targets.last + 1);
    return true;
  }

  bool pasteEditablePages({int? at}) {
    final token = pageClipboard.bytes;
    final pages = token == null ? null : _pageInks[token];
    if (pages == null) return false;
    insertEditablePages(pages, at: at);
    return true;
  }

  T _transaction<T>(T Function() action) {
    final run = notebookTransaction;
    if (run == null) return action();
    late T result;
    run(() => result = action());
    return result;
  }

  @override
  bool get canUndo =>
      _pdfHistory ? super.canUndo : (notebookCanUndo?.call() ?? super.canUndo);
  @override
  bool get canRedo =>
      _pdfHistory ? super.canRedo : (notebookCanRedo?.call() ?? super.canRedo);
  @override
  void undo() => notebookUndo == null ? super.undo() : notebookUndo!();
  @override
  void redo() => notebookRedo == null ? super.redo() : notebookRedo!();

  void undoPdf() {
    _pdfHistory = true;
    try {
      super.undo();
    } finally {
      _pdfHistory = false;
    }
  }

  void redoPdf() {
    _pdfHistory = true;
    try {
      super.redo();
    } finally {
      _pdfHistory = false;
    }
  }

  void inkChanged() => notifyListeners();

  @override
  bool get hasAnnotationClipboard =>
      _clipboard.isNotEmpty || super.hasAnnotationClipboard;

  @override
  int copySelectedAnnotations() {
    final ink = inkController?.call();
    final copied = super.copySelectedAnnotations();
    _clipboard = ink == null
        ? []
        : [for (final id in ink.selected) ?ink.index[id]];
    _clipboardHasPdf = copied > 0;
    if (_clipboard.isNotEmpty) notifyListeners();
    return copied + _clipboard.length;
  }

  @override
  bool pasteAnnotations(
    int pageIndex, {
    (double, double)? at,
    bool selectPasted = true,
  }) => _transaction(
    () => _pasteAnnotations(pageIndex, at: at, selectPasted: selectPasted),
  );

  bool _pasteAnnotations(
    int pageIndex, {
    (double, double)? at,
    bool selectPasted = true,
  }) {
    if (pageIndex < 0 || pageIndex >= document.pageCount) return false;
    final ink = inkController?.call();
    if (ink == null || _clipboard.isEmpty) {
      return super.pasteAnnotations(
        pageIndex,
        at: at,
        selectPasted: selectPasted,
      );
    }
    final bounds = _clipboard
        .map((s) => s.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final delta = at == null
        ? const Offset(12, -12)
        : Offset(at.$1, at.$2) - bounds.center;
    final page = inkPageId(document, pageIndex);
    if (_clipboardHasPdf) {
      super.pasteAnnotations(pageIndex, at: at, selectPasted: selectPasted);
    }
    final prefix = newInkId();
    final groups = <String, String>{};
    final add = [
      for (var i = 0; i < _clipboard.length; i++)
        _clipboard[i].transform(
          id: '$prefix-$i',
          page: page,
          order: ink.nextOrder + i,
          group: groups.putIfAbsent(_clipboard[i].group, newInkId),
          delta: delta,
        ),
    ];
    ink.apply(InkEdit(add: add));
    if (selectPasted) ink.select(add.map((s) => s.id));
    return true;
  }

  @override
  void deleteSelected() => _transaction(() {
    super.deleteSelected();
    inkController?.call().deleteSelection();
  });

  @override
  void moveSelected(double dx, double dy) => _transaction(() {
    super.moveSelected(dx, dy);
    inkController?.call().transformSelection(delta: Offset(dx, dy));
  });

  @override
  bool get canRestyleSelected =>
      super.canRestyleSelected ||
      (inkController?.call().selected.isNotEmpty ?? false);

  @override
  bool restyleSelected({
    Color? color,
    (Color?,)? fill,
    double? strokeWidth,
    double? opacity,
    PdfLineStyle? lineStyle,
    double? cornerRadius,
    double? scale,
  }) => _transaction(() {
    final pdfChanged = super.restyleSelected(
      color: color,
      fill: fill,
      strokeWidth: strokeWidth,
      opacity: opacity,
      lineStyle: lineStyle,
      cornerRadius: cornerRadius,
      scale: scale,
    );
    final inkChanged =
        inkController?.call().restyleSelection(
          color: color?.toARGB32(),
          width: strokeWidth,
          opacity: opacity,
          scale: scale,
        ) ??
        false;
    return pdfChanged || inkChanged;
  });

  @override
  Uint8List exportPages(List<int> indices) {
    final ink = inkSnapshot?.call();
    if (ink == null || ink.strokes.isEmpty) return super.exportPages(indices);
    return pdf.PdfDocument.open(pdfWithInk(bytes, ink)).extractPages(indices);
  }
}

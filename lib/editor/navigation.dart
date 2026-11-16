import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_document/pdf_document.dart' show PdfDestination;

/// Also intercept page jumps from the PDF header and PDF link destinations.
class NavigationViewerController extends PdfViewerController {
  VoidCallback? beforeJump;
  Future<void> Function(int)? pageJump;
  PdfViewport Function(PdfViewport)? capturePageViewport;
  int? pinnedPage;

  @override
  int get currentPage => pinnedPage ?? super.currentPage;

  Future<void> jumpWithoutHistory(int index) =>
      super.animateToPage(index, duration: Duration.zero);

  @override
  PdfViewport? captureViewport() {
    final viewport = super.captureViewport();
    return viewport == null
        ? null
        : capturePageViewport?.call(viewport) ?? viewport;
  }

  @override
  Future<void> jumpToPage(int index) {
    beforeJump?.call();
    return pageJump?.call(index) ?? super.jumpToPage(index);
  }

  @override
  void showDestination(PdfDestination destination) {
    beforeJump?.call();
    if (pageJump != null) {
      pageJump!(destination.pageIndex);
    } else {
      super.showDestination(destination);
    }
  }

  @override
  void restoreViewport(PdfViewport viewport) {
    if (pageJump != null) pinnedPage = viewport.page;
    super.restoreViewport(viewport);
  }
}

/// Each pane owns its history; PDF page references survive reordering and undo.
class PaneNavigation extends ChangeNotifier {
  PaneNavigation(this.editing, this.viewer) {
    editing.addListener(_changed);
    if (viewer is NavigationViewerController) {
      (viewer as NavigationViewerController).beforeJump = _remember;
    }
  }

  final PdfEditingController editing;
  final PdfViewerController viewer;
  final List<({CosReference page, PdfViewport viewport})> _history = [];
  int? _revision;
  bool _restoring = false;

  int _indexOf(CosReference ref) {
    final page = editing.document.cos.resolve(ref);
    return page is CosDictionary ? editing.document.pageIndexOf(page) : -1;
  }

  bool get canGoBack => _history.any((entry) => _indexOf(entry.page) >= 0);

  void _remember() {
    if (_restoring) return;
    final viewport = viewer.captureViewport();
    if (viewport == null) return;
    final document = editing.document;
    final ref = document.cos.referenceTo(document.page(viewport.page).dict);
    if (ref == null) return;
    _history.add((page: ref, viewport: viewport));
    if (_history.length > 100) _history.removeAt(0);
    notifyListeners();
  }

  void jumpToPage(int page) {
    if (page < 0 || page >= editing.document.pageCount) return;
    if (viewer is! NavigationViewerController) _remember();
    viewer.jumpToPage(page);
  }

  Future<void> restorePage(int page) async {
    _restoring = true;
    try {
      await viewer.jumpToPage(page);
    } finally {
      _restoring = false;
    }
  }

  void showDestination(PdfDestination destination) {
    if (destination.pageIndex < 0 ||
        destination.pageIndex >= editing.document.pageCount) {
      return;
    }
    if (viewer is! NavigationViewerController) _remember();
    viewer.showDestination(destination);
  }

  void back() {
    while (_history.isNotEmpty) {
      final entry = _history.removeLast();
      final page = _indexOf(entry.page);
      if (page < 0) continue;
      viewer.restoreViewport(
        PdfViewport(
          page: page,
          top: entry.viewport.top,
          left: entry.viewport.left,
          zoom: entry.viewport.zoom,
        ),
      );
      break;
    }
    notifyListeners();
  }

  void _changed() {
    if (_revision == editing.revisionId) return;
    _revision = editing.revisionId;
    notifyListeners();
  }

  @override
  void dispose() {
    editing.removeListener(_changed);
    if (viewer is NavigationViewerController) {
      (viewer as NavigationViewerController).beforeJump = null;
    }
    super.dispose();
  }
}

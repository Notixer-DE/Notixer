import 'dart:async';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSemanticsAnnotations;
import 'package:flutter/services.dart';
import 'package:pdf_document/pdf_document.dart'
    show PdfRect, PdfGoToAction, PdfNamedAction, PdfAnnotationEditing;
import '../data/document_session.dart';
import '../data/file_gateway.dart';
import '../data/knowledge.dart';
import '../data/notebook.dart';
import 'markdown_editor.dart';
import '../data/learning.dart';
import '../data/tapes.dart';
import '../data/ink.dart';
import '../editor/ink_gestures.dart';
import '../editor/pdf_stroke_eraser.dart';
import '../editor/operations.dart';
import '../editor/navigation.dart';
import 'navigation_dialog.dart';
import 'noter_theme.dart';
import 'workspace_chrome.dart';
import 'text_selection_toolbar.dart';
import 'ink_layer.dart';
import 'single_page_view.dart';
import 'eraser_cursor.dart';
import 'selection_transform_overlay.dart';
import '../input/stylus_eraser.dart';

enum _Mode { normal, lasso, tape }

class EditorPane extends StatefulWidget {
  const EditorPane({
    super.key,
    required this.session,
    required this.active,
    required this.split,
    required this.onActivate,
    this.onModeChanged,
    this.showChrome = true,
    this.initialPage,
    this.initialQuery = '',
    this.onSaveAll,
    this.useDefaultSaveShortcut = true,
    this.initialTapeId,
    this.onReviewRated,
    this.onOpenSourceNote,
  });
  final DocumentSession session;
  final bool active, split, showChrome, useDefaultSaveShortcut;
  final int? initialPage;
  final String initialQuery;
  final String? initialTapeId;
  final VoidCallback? onModeChanged;
  final VoidCallback onActivate;
  final VoidCallback? onReviewRated;
  final Future<void> Function(Notebook)? onOpenSourceNote;
  final Future<bool> Function()? onSaveAll;
  @override
  State<EditorPane> createState() => EditorPaneState();
}

class EditorPaneState extends State<EditorPane> {
  final viewer = NavigationViewerController();
  late final PaneNavigation navigation;
  final _pdfKey = GlobalKey();
  late final _searchText = TextEditingController(text: widget.initialQuery);
  late bool _showSearch = widget.initialQuery.isNotEmpty;
  int? _customPointer, _customPage;
  PdfPageGeometry? _customGeometry;
  Offset _customOrigin = Offset.zero;
  List<Offset> _customPoints = [];
  final _inkCache = InkPathCache();
  LiveInk? _liveInk;
  InkEraserGesture? _inkErase;
  PdfWholeStrokeEraser? _pdfWholeErase;
  final _eraserContact = ValueNotifier<EraserContact?>(null);
  InkMoveGesture? _inkMove;
  List<InkStroke>? _transformOriginal;
  List<InkStroke> _transformPreview = [];
  int? _transformRevision;
  Offset _inkMoveStart = Offset.zero;
  int? _inkPointer;
  Offset _lastInkPosition = Offset.zero;
  PdfPageGeometry? _inkGeometry;
  Offset _inkOrigin = Offset.zero;
  double _inkPressure = .5;
  bool _pressureSensitive = true;
  final _inkPages = <int>{};
  (int, int)? _overviewPreviewKey;
  Widget? _overviewPreview;
  int _inkSelectionCount = 0;
  String? _tappedCover;
  _Mode _mode = _Mode.normal;
  bool _learning = false, _loupe = false, _framePending = false;
  bool? _showPages;
  bool? _lastSidebar;
  (int, PdfEditTool?, bool)? _lastChrome;
  late final _pageTilesChanges = ValueNotifier((
    editing.revisionId,
    viewer.currentPage,
  ));
  late final _overviewChanges = Listenable.merge([
    viewer,
    viewer.viewportChanges,
  ]);
  final Set<String> _revealed = {};
  String? _selectedTape;
  bool _rating = false;
  PdfEditTool? _returnTool = PdfEditTool.ink;
  PdfEditTool? _normalTool = PdfEditTool.ink;
  PdfEditingController get editing => widget.session.editing;
  bool _positionReady = false;
  final _initialPosition = Completer<void>();
  Future<bool> revealLinkedPage(int page, {String query = ''}) async {
    await _initialPosition.future;
    if (!mounted || page < 0 || page >= editing.document.pageCount) {
      return false;
    }
    if (query.isNotEmpty) {
      await viewer.search(
        query,
        options: const PdfSearchOptions(searchAnnotations: false),
      );
    }
    if (!mounted) return false;
    navigation.jumpToPage(page);
    return true;
  }

  bool _creatingSource = false;
  Future<void> _sourceNote() async {
    if (_creatingSource) return;
    final repository = widget.session.repository;
    if (repository is! LocalNotebookRepository || !viewer.hasSelection) return;
    _creatingSource = true;
    final text = viewer.selectedText;
    final page = viewer.selectionPages.isEmpty
        ? viewer.currentPage
        : viewer.selectionPages.first;
    try {
      if (widget.onSaveAll != null && !await widget.onSaveAll!()) {
        throw const FormatException(
          'Save the PDF before creating its source note.',
        );
      }
      final note = await KnowledgeStore(
        repository,
      ).sourceNote(widget.session.note, page + 1, text);
      if (!mounted) return;
      viewer.clearSelection();
      if (widget.onOpenSourceNote != null) {
        await widget.onOpenSourceNote!(note);
      } else {
        final bytes = await repository.load(note.id);
        if (mounted) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => MarkdownEditorPage(
                note: note,
                bytes: bytes,
                repository: repository,
              ),
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create source note: $error')),
        );
      }
    } finally {
      _creatingSource = false;
    }
  }

  bool get lassoActive => _mode == _Mode.lasso;
  bool get tapeActive => _mode == _Mode.tape;
  bool get learningActive => _learning;
  bool singlePage = false;
  final _maskedPointers = <int>{};
  final _touches = <int>{};
  bool _touchNavigation = false;
  bool _restoreFingerDrawing = false;

  void toggleSinglePage() {
    if (_inkPointer != null || _customPointer != null) return;
    final page = viewer.currentPage;
    setState(() => singlePage = !singlePage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) viewer.jumpToPage(page);
    });
  }

  int? get pageForPersistence => _positionReady
      ? viewer.currentPage.clamp(0, editing.document.pageCount - 1)
      : null;
  @override
  void initState() {
    super.initState();
    navigation = PaneNavigation(editing, viewer);
    viewer.setSearchOptions(const PdfSearchOptions(searchAnnotations: false));
    editing.addListener(_documentChanged);
    viewer.addListener(_updatePageTiles);
    widget.session.ready.then((_) {
      if (!mounted) return;
      _liveInk = LiveInk(widget.session.ink);
      widget.session.ink.addListener(_inkSelectionChanged);
      setState(() {});
    });
    _lastChrome = (
      editing.revisionId,
      editing.tool,
      editing.selectedAnnotationSlots.isNotEmpty,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.session.toolReady;
      if (!mounted) return;
      _normalTool = widget.session.baseTool;
      if (mounted && widget.active) activateTools();
      if (!mounted) return;
      final positions = widget.session.repository.catalog.readingPositions;
      await positions.load();
      if (!mounted) return;
      if (widget.initialQuery.isNotEmpty) {
        await viewer.search(
          widget.initialQuery,
          options: const PdfSearchOptions(searchAnnotations: false),
        );
      }
      if (mounted && widget.initialTapeId == null) {
        final page =
            (widget.initialPage ??
                    positions.pageFor(
                      widget.session.note.id,
                      editing.document.pageCount,
                    ))
                .clamp(0, editing.document.pageCount - 1);
        await navigation.restorePage(page);
      }
      if (mounted && widget.initialTapeId != null) {
        await beginReview(widget.initialTapeId!);
      }
      if (mounted) _positionReady = true;
      if (!_initialPosition.isCompleted) _initialPosition.complete();
    });
  }

  void toggleSearch() {
    setState(() => _showSearch = !_showSearch);
    if (!_showSearch) {
      _searchText.clear();
      viewer.clearSearch();
    }
  }

  void _viewChanged() {
    if (_framePending) return;
    _framePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _framePending = false;
      if (!mounted) return;
      final previousMode = (_mode, _learning);
      if (widget.active) {
        if (_mode != _Mode.normal &&
            editing.tool != PdfEditTool.select &&
            editing.tool != PdfEditTool.eraser) {
          _mode = _Mode.normal;
        }
        if (_learning &&
            editing.tool != null &&
            editing.tool != PdfEditTool.eraser) {
          _learning = false;
        }
        if (_mode == _Mode.normal &&
            !_learning &&
            !widget.session.eraser.held) {
          _normalTool = editing.tool;
        }
        widget.session.temporaryTool = _mode != _Mode.normal || _learning;
        widget.session.recordToolChoice();
      }
      setState(() {});
      if (previousMode != (_mode, _learning)) widget.onModeChanged?.call();
    });
  }

  void _documentChanged() {
    if (_transformOriginal != null &&
        (editing.tool != PdfEditTool.select ||
            _transformRevision != editing.revisionId)) {
      _clearTransformPreview();
    }
    _updatePageTiles();
    final chrome = (
      editing.revisionId,
      editing.tool,
      editing.selectedAnnotationSlots.isNotEmpty,
    );
    if (chrome == _lastChrome) return;
    _lastChrome = chrome;
    _viewChanged();
  }

  void _updatePageTiles() {
    _pageTilesChanges.value = (editing.revisionId, viewer.currentPage);
  }

  void _inkSelectionChanged() {
    final count = widget.session.ink.selected.length;
    if (_inkSelectionCount == count || !mounted) return;
    setState(() => _inkSelectionCount = count);
  }

  void activateTools() {
    widget.session.temporaryTool = _mode != _Mode.normal || _learning;
    widget.session.eraser.setBaseTool(
      _learning
          ? null
          : _mode != _Mode.normal
          ? PdfEditTool.select
          : _normalTool,
    );
  }

  void normalTool() {
    widget.session.temporaryTool = false;
    setState(() {
      _mode = _Mode.normal;
      _learning = false;
    });
    widget.onModeChanged?.call();
  }

  void selectText() {
    normalTool();
    _normalTool = null;
    _returnTool = null;
    widget.session.eraser.setBaseTool(null);
  }

  void _setMode(_Mode mode) {
    editing.finishInk();
    if (_mode == _Mode.normal && !_learning) _returnTool = editing.tool;
    setState(() {
      _mode = _mode == mode ? _Mode.normal : mode;
      _learning = false;
    });
    widget.session.temporaryTool = _mode != _Mode.normal;
    editing.tool = _mode == _Mode.normal ? _returnTool : PdfEditTool.select;
    widget.onModeChanged?.call();
  }

  void toggleLasso() => _setMode(_Mode.lasso);
  void toggleTape() => _setMode(_Mode.tape);
  void toggleLearning() {
    editing.finishInk();
    if (!_learning) _returnTool = editing.tool;
    setState(() {
      _learning = !_learning;
      _mode = _Mode.normal;
    });
    widget.session.temporaryTool = _learning;
    editing.tool = _learning ? null : _returnTool;
    widget.onModeChanged?.call();
  }

  void toggleLoupe() {
    setState(() => _loupe = !_loupe);
    if (_loupe) {
      _focusRegion(const Offset(.5, .25));
    } else {
      viewer.setZoom(1);
    }
  }

  void revealAll() {
    if (!_learning) toggleLearning();
    setState(() {
      for (var p = 0; p < editing.document.pageCount; p++) {
        final annotations = editing.document.page(p).annotations;
        for (var i = 0; i < annotations.length; i++) {
          if (isTape(annotations[i])) {
            final id = _tapeKey(p, i);
            _revealed.add(id);
            _selectedTape ??= id;
          }
        }
      }
    });
  }

  void coverAll() {
    if (!_learning) toggleLearning();
    setState(_revealed.clear);
  }

  Future<void> openNavigation() => showDialog<void>(
    context: context,
    builder: (_) => NavigationDialog(editing: editing, navigation: navigation),
  );

  Future<void> _pageNumber() async {
    final text = TextEditingController(text: '${viewer.currentPage + 1}');
    final page = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: text,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Page (1–${editing.document.pageCount})',
          ),
          onSubmitted: (value) {
            final page = int.tryParse(value);
            if (page != null &&
                page > 0 &&
                page <= editing.document.pageCount) {
              Navigator.pop(context, page - 1);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(text.text);
              if (page != null &&
                  page > 0 &&
                  page <= editing.document.pageCount) {
                Navigator.pop(context, page - 1);
              }
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
    if (mounted && page != null) navigation.jumpToPage(page);
    WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
  }

  Widget _pageTiles({bool closeOnTap = false}) => ListenableBuilder(
    listenable: _pageTilesChanges,
    builder: (context, _) => ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: editing.document.pageCount,
      itemBuilder: (context, index) {
        final page = editing.document.page(index);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: InkWell(
            onTap: () {
              navigation.jumpToPage(index);
              if (closeOnTap) Navigator.pop(context);
            },
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: viewer.currentPage == index
                          ? NoterTheme.accent
                          : NoterTheme.border,
                      width: 1,
                    ),
                    color: viewer.currentPage == index
                        ? NoterTheme.active
                        : Colors.white,
                  ),
                  child: AspectRatio(
                    aspectRatio: page.rotation % 180 == 0
                        ? page.cropBox.width / page.cropBox.height
                        : page.cropBox.height / page.cropBox.width,
                    child: InkPagePreview(
                      page: page,
                      pageId: inkPageId(editing.document, index),
                      controller: widget.session.ink,
                      cache: _inkCache,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${index + 1}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  void _togglePages(bool pagesVisible, bool compact) {
    if (compact) {
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => SizedBox(
          key: const ValueKey('editor-page-sheet'),
          width: 240,
          child: _pageTiles(closeOnTap: true),
        ),
      );
    } else {
      setState(() => _showPages = !pagesVisible);
    }
  }

  Widget _navigationBar(bool pagesVisible, bool compact) => ListenableBuilder(
    listenable: Listenable.merge([viewer, navigation, widget.session]),
    builder: (context, _) => WorkspaceToolbar(
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Page overview',
                    onPressed: () => _togglePages(pagesVisible, compact),
                    isSelected: !compact && pagesVisible,
                    icon: const Icon(Icons.view_module_outlined),
                    selectedIcon: const Icon(Icons.view_module),
                  ),
                  IconButton(
                    tooltip: singlePage
                        ? 'Continuous view'
                        : 'Single-page view',
                    onPressed: toggleSinglePage,
                    isSelected: singlePage,
                    icon: const Icon(Icons.menu_book_outlined),
                  ),
                  IconButton(
                    tooltip: 'Back to previous position',
                    onPressed: navigation.canGoBack ? navigation.back : null,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  IconButton(
                    tooltip: 'Bookmarks and table of contents',
                    onPressed: openNavigation,
                    icon: const Icon(Icons.bookmarks_outlined),
                  ),
                  IconButton(
                    tooltip: 'Previous page',
                    onPressed: viewer.currentPage > 0
                        ? () => navigation.jumpToPage(viewer.currentPage - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: _pageNumber,
                    child: Text(
                      '${viewer.currentPage + 1} / ${editing.document.pageCount}',
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next page',
                    onPressed:
                        viewer.currentPage < editing.document.pageCount - 1
                        ? () => navigation.jumpToPage(viewer.currentPage + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  TextButton(
                    onPressed: () => viewer.setZoom(
                      viewer.zoom >= 2 ? 1 : viewer.zoom + .25,
                    ),
                    child: Text('${(viewer.zoom * 100).round()} %'),
                  ),
                ],
              ),
            ),
          ),
          if (!compact)
            SizedBox(
              width: 156,
              child: Text(
                widget.session.saveStatus,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Semantics(
            label: widget.session.saveStatus,
            child: IconButton(
              tooltip: 'Save',
              onPressed: () => (widget.onSaveAll ?? widget.session.save)(),
              icon: Icon(
                widget.session.error != null
                    ? Icons.error_outline
                    : widget.session.saving
                    ? Icons.sync
                    : widget.session.dirty
                    ? Icons.save_outlined
                    : Icons.check_circle_outline,
                color: widget.session.error != null
                    ? Theme.of(context).colorScheme.error
                    : NoterTheme.accent,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  String _tapeKey(int page, int index) =>
      tapeIdentity(editing.document, page, index) ?? 'untracked:$page:$index';

  void _toggleCover(String id) => setState(() {
    _selectedTape = id;
    if (!_revealed.remove(id)) _revealed.add(id);
  });

  /// Resolve the durable target again, never trust an old page/index pair.
  Future<void> beginReview(String id) async {
    final tape = widget.session.tapes.where((t) => t.id == id).firstOrNull;
    if (tape == null) return;
    if (!_learning) toggleLearning();
    setState(() {
      _selectedTape = id;
      _revealed.remove(id);
    });
    await viewer.jumpToPage(tape.page);
    if (mounted) viewer.showRect(tape.page, tape.rect);
  }

  Future<void> _rate(ReviewRating rating) async {
    final id = _selectedTape;
    if (_rating || id == null || !_revealed.contains(id)) return;
    setState(() => _rating = true);
    try {
      final saved = await widget.session.rateTape(id, rating);
      if (!mounted) return;
      setState(() => _revealed.remove(id));
      if (saved) {
        if (widget.onReviewRated != null) {
          widget.onReviewRated!();
        } else {
          final next = widget.session.dueTapes
              .where((t) => t.id != id)
              .firstOrNull;
          if (next != null) await beginReview(next.id);
        }
      }
      if (!saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Rating not saved yet. Please choose “Retry” on the save error.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _rating = false);
    }
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    final l10n = MaterialLocalizations.of(context);
    return '${l10n.formatShortDate(local)} ${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  Future<void> _reviewHistory(String id) => showDialog<void>(
    context: context,
    builder: (context) {
      final events =
          widget.session.note.learning.events
              .where((e) => e.tapeId == id)
              .toList()
            ..sort((a, b) {
              final time = b.at.compareTo(a.at);
              return time == 0 ? a.id.compareTo(b.id) : time;
            });
      return AlertDialog(
        title: Text(
          'Study history · ${events.length} ${events.length == 1 ? 'rating' : 'ratings'}',
        ),
        content: SizedBox(
          width: 420,
          height: 300,
          child: ListView.builder(
            itemCount: events.length,
            itemBuilder: (_, index) => ListTile(
              title: Text(events[index].rating.label),
              subtitle: Text(_date(events[index].at)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );

  Widget _reviewControls() => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final tape = widget.session.tapes
          .where((t) => t.id == _selectedTape)
          .firstOrNull;
      final schedule = tape == null
          ? null
          : widget.session.note.learning.schedule(tape.id);
      final revealed = tape != null && _revealed.contains(tape.id);
      final description = tape == null
          ? 'Tap a study cover to review'
          : schedule == null
          ? 'New task · due now'
          : '${schedule.concurrent ? "Concurrent ratings · " : ""}'
                '${schedule.count} ${schedule.count == 1 ? 'rating' : 'ratings'} · due ${_date(schedule.due)}';
      return WorkspaceToolbar(
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (constraints.maxWidth >= 480)
                        SizedBox(
                          width: 180,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        )
                      else
                        Tooltip(
                          message: description,
                          child: Semantics(
                            label: description,
                            child: const SizedBox(
                              width: 40,
                              child: Icon(Icons.school_outlined, size: 18),
                            ),
                          ),
                        ),
                      if (tape != null)
                        IconButton(
                          tooltip: 'Study history',
                          onPressed: () => _reviewHistory(tape.id),
                          icon: const Icon(Icons.history, size: 18),
                        ),
                      IconButton(
                        tooltip: 'Next due cover',
                        onPressed: _rating
                            ? null
                            : (() {
                                final next = widget.session.dueTapes
                                    .where((t) => t.id != tape?.id)
                                    .firstOrNull;
                                return next == null
                                    ? null
                                    : () => beginReview(next.id);
                              })(),
                        icon: const Icon(Icons.skip_next),
                      ),
                      if (tape != null && !revealed)
                        TextButton.icon(
                          onPressed: _rating
                              ? null
                              : () => _toggleCover(tape.id),
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          label: const Text('Reveal answer'),
                        ),
                      for (final rating in ReviewRating.values)
                        TextButton(
                          onPressed: revealed && !_rating
                              ? () => _rate(rating)
                              : null,
                          child: Text(rating.label),
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.showChrome)
                IconButton(
                  tooltip: 'Exit mode',
                  onPressed: () {
                    final old = _returnTool;
                    normalTool();
                    editing.tool = old;
                  },
                  icon: const Icon(Icons.close, size: 18),
                ),
            ],
          ),
        ),
      );
    },
  );
  void _clearTransformPreview() {
    final originals = _transformOriginal;
    _transformOriginal = null;
    if (originals == null) return;
    final ink = widget.session.ink;
    ink.clearPreview(_transformPreview.map((s) => s.id));
    for (final stroke in originals) {
      ink.hide(stroke, false);
    }
    _transformPreview = [];
  }

  Widget _selectionHandles() => ListenableBuilder(
    listenable: Listenable.merge([
      editing,
      widget.session.ink,
      viewer.viewportChanges,
    ]),
    builder: (context, _) {
      if (!widget.active ||
          editing.tool != PdfEditTool.select ||
          _mode != _Mode.normal ||
          _learning) {
        return const SizedBox.shrink();
      }
      final ink = widget.session.ink;
      final strokes = [for (final id in ink.selected) ?ink.index[id]];
      // Native PDF-only selections already have handles. A lasso containing
      // vector ink needs one common frame for the mixed selection.
      if (strokes.isEmpty) return const SizedBox.shrink();
      final page =
          List.generate(editing.document.pageCount, (i) => i)
              .where(
                (i) => inkPageId(editing.document, i) == strokes.first.page,
              )
              .firstOrNull ??
          -1;
      if (page < 0 || strokes.any((s) => s.page != strokes.first.page)) {
        return const SizedBox.shrink();
      }
      final slots = editing.selectedAnnotationSlots.toList();
      if (slots.any((slot) => slot.$1 != page)) return const SizedBox.shrink();
      final bounds = [
        for (final s in strokes) s.bounds,
        for (final slot in slots)
          (() {
            final rect = editing.document.page(page).annotations[slot.$2].rect;
            return Rect.fromLTRB(rect.left, rect.bottom, rect.right, rect.top);
          })(),
      ].reduce((a, b) => a.expandToInclude(b));
      final model = editing.document.page(page);
      final global = viewer.globalRectOf(page, model.cropBox);
      final box = _pdfKey.currentContext?.findRenderObject();
      if (global == null || box is! RenderBox || !box.hasSize) {
        return const SizedBox.shrink();
      }
      final origin = global.topLeft - box.localToGlobal(Offset.zero);
      final geometry = PdfPageGeometry(
        cropBox: model.cropBox,
        rotation: (model.rotation + viewer.viewRotation) % 360,
        viewSize: global.size,
      );
      return SelectionTransformOverlay(
        key: ValueKey(('selection-handles', page)),
        // Keep move and 44px resize targets disjoint even for a dot or a
        // single thin line. The shared frame intentionally includes padding.
        bounds: Rect.fromCenter(
          center: bounds.center,
          width: bounds.width.clamp(112 / geometry.scale, double.infinity),
          height: bounds.height.clamp(112 / geometry.scale, double.infinity),
        ),
        toLocal: (p) => geometry.toViewOffset(p.dx, p.dy) + origin,
        toPage: (p) {
          final v = geometry.toPagePoint(p - origin);
          return Offset(v.$1, v.$2);
        },
        onStart: () {
          _clearTransformPreview();
          _transformRevision = editing.revisionId;
          _transformOriginal = strokes;
          for (final stroke in strokes) {
            ink.hide(stroke, true);
          }
        },
        onUpdate: (value) {
          if (_transformOriginal == null) return;
          ink.clearPreview(_transformPreview.map((s) => s.id));
          try {
            _transformPreview = [
              for (final s in _transformOriginal!)
                s.transform(
                  origin: value.origin,
                  delta: value.delta,
                  scaleX: value.scaleX,
                  scaleY: value.scaleY,
                  rotation: value.rotation,
                ),
            ];
            for (final stroke in _transformPreview) {
              ink.showPreview(stroke);
            }
          } catch (_) {
            // Oversized transformations must never replace valid originals.
            _clearTransformPreview();
          }
        },
        onFinish: (value, cancel) {
          final valid =
              _transformOriginal != null &&
              _transformRevision == editing.revisionId;
          _clearTransformPreview();
          if (cancel || !valid || value.isIdentity) return;
          try {
            widget.session.transaction(
              () => transformNotebookSelection(
                editing,
                ink,
                anchor: value.origin,
                delta: value.delta,
                scaleX: value.scaleX,
                scaleY: value.scaleY,
                rotation: value.rotation,
              ),
            );
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Could not transform the selection: $e'),
                ),
              );
            }
          }
        },
      );
    },
  );

  void _transform({double scale = 1, double rotation = 0}) {
    try {
      widget.session.transaction(
        () => transformNotebookSelection(
          editing,
          widget.session.ink,
          scale: scale,
          rotation: rotation,
        ),
      );
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not transform the selection: $error')),
      );
    }
  }

  Future<void> _transformDialog() async {
    var scale = '100';
    var angle = '0';
    final result = await showDialog<(double, double)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final factor = double.tryParse(scale.replaceAll(',', '.'));
          final degrees = double.tryParse(angle.replaceAll(',', '.'));
          final valid =
              factor != null &&
              factor.isFinite &&
              factor > 0 &&
              degrees != null &&
              degrees.isFinite;
          return AlertDialog(
            title: const Text('Transform selection'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: scale,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Size (%)'),
                  onChanged: (value) => update(() => scale = value),
                ),
                TextFormField(
                  initialValue: angle,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Rotation (°)'),
                  onChanged: (value) => update(() => angle = value),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(context, (
                        factor / 100,
                        degrees * 0.017453292519943295,
                      ))
                    : null,
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted && result != null) {
      _transform(scale: result.$1, rotation: result.$2);
    }
  }

  void _focusRegion(Offset fraction) {
    final page = viewer.currentPage.clamp(0, editing.document.pageCount - 1);
    final model = editing.document.page(page);
    final geometry = PdfPageGeometry(
      cropBox: model.cropBox,
      rotation: model.rotation,
      viewSize: Size(
        model.rotation % 180 == 0 ? model.cropBox.width : model.cropBox.height,
        model.rotation % 180 == 0 ? model.cropBox.height : model.cropBox.width,
      ),
    );
    final center = Offset(
      fraction.dx.clamp(0.0, 1.0) * geometry.viewSize.width,
      fraction.dy.clamp(0.0, 1.0) * geometry.viewSize.height,
    );
    final rect = geometry.toPageRect(
      Rect.fromCenter(
        center: center,
        width: geometry.viewSize.width * .28,
        height: geometry.viewSize.height * .12,
      ),
    );
    viewer.showRect(page, rect);
  }

  void _nextLine() {
    final index = viewer.currentPage.clamp(0, editing.document.pageCount - 1);
    final r =
        viewer.visiblePageRegion(index) ?? const Rect.fromLTWH(.3, .2, .3, .1);
    _focusRegion(
      Offset(
        (r.left + r.right) / 2,
        ((r.top + r.bottom) / 2 + .08).clamp(0.0, 1.0),
      ),
    );
  }

  Widget _overview(double height) {
    final pageIndex = viewer.currentPage.clamp(
      0,
      editing.document.pageCount - 1,
    );
    final page = editing.document.page(pageIndex);
    final previewKey = (editing.revisionId, pageIndex);
    if (_overviewPreviewKey != previewKey) {
      _overviewPreviewKey = previewKey;
      _overviewPreview = RepaintBoundary(
        child: InkPagePreview(
          page: page,
          pageId: inkPageId(editing.document, pageIndex),
          controller: widget.session.ink,
          cache: _inkCache,
        ),
      );
    }
    final sideways = page.rotation % 180 != 0;
    final ratio = sideways
        ? page.cropBox.height / page.cropBox.width
        : page.cropBox.width / page.cropBox.height;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          const SizedBox(width: 8),
          AspectRatio(
            aspectRatio: ratio,
            child: LayoutBuilder(
              builder: (context, c) {
                final region =
                    viewer.visiblePageRegion(pageIndex) ??
                    const Rect.fromLTWH(.35, .15, .3, .15);
                void move(Offset position) => _focusRegion(
                  Offset(position.dx / c.maxWidth, position.dy / c.maxHeight),
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => move(d.localPosition),
                  onPanUpdate: (d) => move(d.localPosition),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _overviewPreview!,
                      Positioned.fromRect(
                        rect: Rect.fromLTRB(
                          region.left * c.maxWidth,
                          region.top * c.maxHeight,
                          region.right * c.maxWidth,
                          region.bottom * c.maxHeight,
                        ),
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              color: NoterTheme.accent.withValues(alpha: .13),
                              border: Border.all(
                                color: NoterTheme.accent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: height < 90
                ? Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Writing magnifier',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next line',
                        onPressed: _nextLine,
                        icon: const Icon(Icons.keyboard_return),
                      ),
                      IconButton(
                        tooltip: 'Close writing magnifier',
                        onPressed: toggleLoupe,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Writing magnifier',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton.icon(
                              onPressed: _nextLine,
                              icon: const Icon(Icons.keyboard_return),
                              label: const Text(
                                'Next line',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close writing magnifier',
                            onPressed: toggleLoupe,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _overlays(
    BuildContext context,
    int page,
    PdfPageGeometry geometry,
  ) {
    _inkPages.removeWhere(
      (index) =>
          index >= editing.document.pageCount ||
          viewer.visiblePageRegion(index) == null,
    );
    if (viewer.visiblePageRegion(page) != null) _inkPages.add(page);
    final annotations = editing.document.page(page).annotations;
    return [
      if (!widget.session.loadingInk)
        Positioned.fill(
          child: ListenableBuilder(
            listenable: viewer.viewportChanges,
            builder: (context, _) {
              final region = viewer.visiblePageRegion(page);
              if (region == null && page != viewer.currentPage) {
                return const SizedBox.shrink();
              }
              return InkLayer(
                controller: widget.session.ink,
                page: inkPageId(editing.document, page),
                geometry: geometry,
                rasterScale:
                    viewer.viewSync?.transform.getMaxScaleOnAxis() ?? 1,
                visible: region ?? const Rect.fromLTWH(0, 0, 1, 1),
                cache: _inkCache,
                live: _liveInk,
              );
            },
          ),
        ),
      for (var i = 0; i < annotations.length; i++)
        if (isTape(annotations[i]))
          Positioned.fromRect(
            rect: geometry.toViewRect(annotations[i].rect),
            child: _cover(page, i),
          ),
      if (_customPage == page && _customPoints.length > 1)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _GesturePainter([
                for (final p in _customPoints)
                  geometry.toViewOffset(p.dx, p.dy),
              ], _mode == _Mode.tape),
            ),
          ),
        ),
    ];
  }

  bool _within(GlobalKey key, Offset position) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox &&
        box.hasSize &&
        (box.localToGlobal(Offset.zero) & box.size).contains(position);
  }

  /// Custom page gestures run before the library's own editing overlay. That
  /// overlay intentionally sits above pageOverlayBuilder, so an outer widget
  /// listener cannot reliably implement lasso/learning taps there.
  bool handleCustomInput(PointerEvent event) {
    if (event is PointerDownEvent && _within(_pdfKey, event.position)) {
      // Page overlays contain real buttons (selection toolbars and PDF chips).
      // Their hit targets take precedence over ink underneath them.
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(hit, event.position, event.viewId);
      if (hit.path.any((entry) {
        final target = entry.target;
        return target is RenderSemanticsAnnotations &&
            target.properties.button == true;
      })) {
        return false;
      }
    }
    if (event.kind == PointerDeviceKind.touch) {
      if (event is PointerDownEvent && _within(_pdfKey, event.position)) {
        _touches.add(event.pointer);
        if (_touches.length > 1 && !NoterBinding.stylusContactActive) {
          if (!_touchNavigation) {
            NoterBinding.replayTouchPointer = _touches.first;
            _restoreFingerDrawing = widget.session.preferences.fingerDrawsInk;
            _touchNavigation = true;
            // Cancel provisional edits before allowing the viewer to pinch.
            if (_inkPointer != null) {
              _handleInkInput(
                PointerCancelEvent(
                  pointer: _inkPointer!,
                  kind: PointerDeviceKind.touch,
                  position: event.position,
                ),
              );
            }
            _customPointer = null;
            _customPage = null;
            _customPoints = [];
            widget.session.preferences.fingerDrawsInk = false;
          }
        }
      }
      if (event is PointerUpEvent || event is PointerCancelEvent) {
        _touches.remove(event.pointer);
      }
      if (_touchNavigation) {
        if (_touches.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _touches.isNotEmpty) return;
            _touchNavigation = false;
            widget.session.preferences.fingerDrawsInk = _restoreFingerDrawing;
          });
        }
        return false;
      }
    }
    if (_maskedPointers.contains(event.pointer)) {
      if (event is PointerUpEvent || event is PointerCancelEvent) {
        _maskedPointers.remove(event.pointer);
      }
      return true;
    }
    if (singlePage &&
        event is PointerDownEvent &&
        (event.kind != PointerDeviceKind.touch ||
            widget.session.preferences.fingerDrawsInk ||
            _mode != _Mode.normal ||
            _learning) &&
        _within(_pdfKey, event.position)) {
      final rect = viewer.globalRectOf(
        viewer.currentPage,
        editing.document.page(viewer.currentPage).cropBox,
      );
      if (rect == null || !rect.contains(event.position)) {
        _maskedPointers.add(event.pointer);
        return true;
      }
    }
    final inkHandled = _handleInkInput(event);
    if (inkHandled != null) return inkHandled;
    if (_customPointer != null) {
      if (event.pointer != _customPointer) return false;
      final point = _customGeometry!.toPagePoint(
        event.position - _customOrigin,
      );
      if (event is PointerMoveEvent) {
        setState(() => _customPoints.add(Offset(point.$1, point.$2)));
      }
      if (event is PointerUpEvent ||
          event is PointerCancelEvent ||
          event is PointerRemovedEvent) {
        final page = _customPage!;
        final points = [..._customPoints, Offset(point.$1, point.$2)];
        final cover = _tappedCover;
        setState(() {
          _customPointer = null;
          _customPage = null;
          _customPoints = [];
          _tappedCover = null;
        });
        if (event is PointerUpEvent) {
          if (cover != null) {
            if ((points.first - points.last).distance * _customGeometry!.scale <
                18) {
              _toggleCover(cover);
            }
          } else if (_mode == _Mode.tape && points.length > 2) {
            final rect = Rect.fromPoints(points.first, points.last);
            if (rect.width > 2 && rect.height > 2) {
              addTape(
                editing,
                page,
                PdfRect(rect.left, rect.top, rect.right, rect.bottom),
              );
            }
          } else if (_mode == _Mode.lasso && points.length > 3) {
            lassoSelect(editing, page, points);
            final region = points.fold(
              Rect.fromCircle(center: points.first, radius: .01),
              (r, p) =>
                  r.expandToInclude(Rect.fromCircle(center: p, radius: .01)),
            );
            final hits = widget.session.ink.index
                .query(inkPageId(editing.document, page), region)
                .where(
                  (s) => strokeHitsPolygon([
                    for (var i = 0; i < s.points.length; i += 3)
                      (s.points[i], s.points[i + 1]),
                  ], points),
                )
                .toList();
            widget.session.ink.select({
              for (final s in hits)
                for (final part in widget.session.ink.index.group(s.group))
                  part.id,
            });
            setState(() => _mode = _Mode.normal);
            widget.onModeChanged?.call();
          }
        }
      }
      return true;
    }
    if (event is! PointerDownEvent ||
        (_mode == _Mode.normal && !_learning) ||
        editing.tool == PdfEditTool.eraser) {
      return false;
    }
    if (!_within(_pdfKey, event.position)) {
      return false;
    }
    if (!_learning &&
        event.kind == PointerDeviceKind.touch &&
        !widget.session.preferences.fingerDrawsInk) {
      return false;
    }
    for (var page = 0; page < editing.document.pageCount; page++) {
      final model = editing.document.page(page);
      final bounds = viewer.globalRectOf(page, model.cropBox);
      if (bounds == null || !bounds.contains(event.position)) continue;
      final geometry = PdfPageGeometry(
        cropBox: model.cropBox,
        rotation: (model.rotation + viewer.viewRotation) % 360,
        viewSize: bounds.size,
      );
      final point = geometry.toPagePoint(event.position - bounds.topLeft);
      String? cover;
      if (_learning) {
        final annotations = model.annotations;
        for (var i = annotations.length - 1; i >= 0; i--) {
          if (isTape(annotations[i]) &&
              annotations[i].rect.contains(point.$1, point.$2)) {
            cover = _tapeKey(page, i);
            break;
          }
        }
        if (cover == null) return false;
      }
      setState(() {
        _customPointer = event.pointer;
        _customPage = page;
        _customGeometry = geometry;
        _customOrigin = bounds.topLeft;
        _customPoints = [Offset(point.$1, point.$2)];
        _tappedCover = cover;
      });
      return true;
    }
    return false;
  }

  void finishInput() {
    _clearTransformPreview();
    if (_inkPointer != null) {
      _handleInkInput(
        PointerUpEvent(
          pointer: _inkPointer!,
          position: _lastInkPosition,
          kind: PointerDeviceKind.stylus,
        ),
      );
    }
    _touches.clear();
    if (_touchNavigation) {
      _touchNavigation = false;
      widget.session.preferences.fingerDrawsInk = _restoreFingerDrawing;
    }
    if (_customPointer != null) {
      setState(() {
        _customPointer = null;
        _customPage = null;
        _customPoints = [];
        _tappedCover = null;
      });
    }
    editing.finishInk();
  }

  bool? _handleInkInput(PointerEvent event) {
    if (event.kind == PointerDeviceKind.touch &&
        NoterBinding.stylusContactActive &&
        event is PointerDownEvent) {
      return _within(_pdfKey, event.position) ? true : null;
    }
    if (event.pointer == _inkPointer) {
      _lastInkPosition = event.position;
      final erasing = _inkErase != null;
      final wholeErasing = _pdfWholeErase != null;
      final p = _inkGeometry!.toPagePoint(event.position - _inkOrigin);
      if (event is PointerMoveEvent) {
        if (wholeErasing) _updateEraserContact(event.position);
        if (_inkMove != null) {
          _inkMove!.update(Offset(p.$1, p.$2) - _inkMoveStart);
        } else if (erasing) {
          _inkErase!.add(Offset(p.$1, p.$2));
          _pdfWholeErase?.add(Offset(p.$1, p.$2));
        } else {
          _inkPressure = _pressure(event);
          _liveInk!.add(p.$1, p.$2, _inkPressure);
        }
      }
      if (event is PointerUpEvent ||
          event is PointerCancelEvent ||
          event is PointerRemovedEvent) {
        final canceled = event is! PointerUpEvent;
        try {
          if (_inkMove != null) {
            widget.session.transaction(() {
              final delta = _inkMove!.delta;
              _inkMove!.finish(cancel: canceled);
              if (!canceled && delta != Offset.zero) {
                final slots = editing.selectedAnnotationSlots.toList();
                editing.apply((editor) {
                  for (final slot in slots) {
                    editor.moveAnnotation(
                      slot.$1,
                      editing.document.page(slot.$1).annotations[slot.$2],
                      delta.dx,
                      delta.dy,
                    );
                  }
                });
              }
            });
          } else if (erasing) {
            widget.session.transaction(() {
              _pdfWholeErase?.finish(cancel: canceled);
              _inkErase!.finish(cancel: canceled);
            });
          } else if (canceled) {
            _liveInk!.cancel();
          } else {
            _liveInk!.add(p.$1, p.$2, _inkPressure);
            _liveInk!.finish();
          }
        } catch (e) {
          _inkMove?.finish(cancel: true);
          _inkErase?.finish(cancel: true);
          _liveInk?.cancel();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Could not commit handwriting: $e')),
          );
        } finally {
          _eraserContact.value = null;
          _inkPointer = null;
          _inkErase = null;
          _pdfWholeErase = null;
          _inkMove = null;
        }
      }
      // Legacy PDF annotations must still receive the eraser gesture.
      return !erasing || wholeErasing;
    }
    if (event is! PointerDownEvent ||
        _inkPointer != null ||
        ((_mode != _Mode.normal || _learning) &&
            editing.tool != PdfEditTool.eraser) ||
        !_within(_pdfKey, event.position)) {
      return null;
    }
    if (event.kind == PointerDeviceKind.touch &&
        !widget.session.preferences.fingerDrawsInk) {
      return null;
    }
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryButton) {
      return null;
    }
    if (editing.tool != PdfEditTool.ink &&
        editing.tool != PdfEditTool.highlight &&
        editing.tool != PdfEditTool.eraser &&
        editing.tool != PdfEditTool.select) {
      return null;
    }
    if (!widget.session.inkReady ||
        !widget.session.toolsReady ||
        _liveInk == null) {
      // Navigation remains usable if ink cannot be recovered. Only editing
      // gestures are blocked, so the unchanged PDF can still be inspected.
      return editing.tool == PdfEditTool.select ? null : true;
    }
    for (final page in {viewer.currentPage, ..._inkPages}) {
      if (page >= editing.document.pageCount) continue;
      final model = editing.document.page(page);
      final bounds = viewer.globalRectOf(page, model.cropBox);
      if (bounds == null || !bounds.contains(event.position)) continue;
      _inkGeometry = PdfPageGeometry(
        cropBox: model.cropBox,
        rotation: (model.rotation + viewer.viewRotation) % 360,
        viewSize: bounds.size,
      );
      _inkOrigin = bounds.topLeft;
      final p = _inkGeometry!.toPagePoint(event.position - _inkOrigin);
      _inkPointer = event.pointer;
      _lastInkPosition = event.position;
      final key = inkPageId(editing.document, page);
      if (editing.tool == PdfEditTool.select) {
        final point = Offset(p.$1, p.$2), radius = 6 / _inkGeometry!.scale;
        final hits = widget.session.ink.index
            .query(key, Rect.fromCircle(center: point, radius: radius))
            .where((s) => inkHitsSegment(s, point, point, radius))
            .toList();
        if (hits.isEmpty) {
          _inkPointer = null;
          final selectedPdfHit = editing.selectedAnnotationSlots.any(
            (slot) =>
                slot.$1 == page &&
                editing.document
                    .page(page)
                    .annotations[slot.$2]
                    .rect
                    .contains(p.$1, p.$2),
          );
          if (!selectedPdfHit) widget.session.ink.select([]);
          return null;
        }
        final hit = hits.last;
        if (!widget.session.ink.selected.contains(hit.id)) {
          editing.clearAnnotationSelection();
          widget.session.ink.select(
            widget.session.ink.index.group(hit.group).map((s) => s.id),
          );
        }
        _inkMoveStart = point;
        _inkMove = InkMoveGesture(widget.session.ink);
        return true;
      }
      if (editing.tool == PdfEditTool.eraser) {
        final whole = widget
            .session
            .repository
            .catalog
            .drawingPreferences
            .wholeStrokeEraser;
        _inkErase = InkEraserGesture(
          widget.session.ink,
          key,
          widget.session.preferences.eraserRadius,
          wholeStroke: whole,
        );
        if (whole) {
          _updateEraserContact(event.position);
          _pdfWholeErase = PdfWholeStrokeEraser(
            editing,
            page,
            widget.session.preferences.eraserRadius,
          )..add(Offset(p.$1, p.$2));
        }
        _inkErase!.add(Offset(p.$1, p.$2));
        return whole;
      }
      widget.session.ink.select([]);
      _pressureSensitive = widget.session.repository.catalog.drawingPreferences
          .pressureSensitive(
            editing.tool == PdfEditTool.highlight ? 'highlight' : 'ink',
          );
      _liveInk!.begin(
        key,
        editing.color.toARGB32(),
        widget.session.preferences.strokeWidth,
        opacity: widget.session.preferences.opacity,
        straight: widget
            .session
            .repository
            .catalog
            .drawingPreferences
            .straightStrokes,
      );
      _inkPressure = _pressure(event);
      _liveInk!.add(p.$1, p.$2, _inkPressure);
      return true;
    }
    return null;
  }

  double _pressure(PointerEvent event) {
    if (!_pressureSensitive) return .5;
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return .5;
    }
    final range = event.pressureMax - event.pressureMin;
    return range > 0
        ? ((event.pressure - event.pressureMin) / range).clamp(0.0, 1.0)
        : .5;
  }

  void _updateEraserContact(Offset globalPosition) {
    final box = _pdfKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    _eraserContact.value = (
      center: box.globalToLocal(globalPosition),
      radius: widget.session.preferences.eraserRadius * _inkGeometry!.scale,
    );
  }

  Widget _cover(int page, int index) {
    final annotation = editing.document.page(page).annotations[index];
    final key = _tapeKey(page, index);
    final revealed = _learning && _revealed.contains(key);
    final color = Color(0xFF000000 | (annotation.interiorColor ?? 0xF0C55B));
    final cover = Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: revealed ? .12 : 1),
        border: Border.all(color: color),
      ),
      child: revealed
          ? null
          : const Center(
              child: Icon(
                Icons.visibility_off_outlined,
                size: 16,
                color: Color(0xFF41350F),
              ),
            ),
    );
    if (!_learning) return IgnorePointer(child: cover);
    return Semantics(
      button: true,
      label: revealed ? 'Hide answer' : 'Reveal answer',
      child: GestureDetector(onTap: () => _toggleCover(key), child: cover),
    );
  }

  @override
  void dispose() {
    if (!_initialPosition.isCompleted) _initialPosition.complete();
    _clearTransformPreview();
    _inkMove?.finish(cancel: true);
    _inkErase?.finish(cancel: true);
    _liveInk?.dispose();
    _inkCache.clear();
    _eraserContact.dispose();
    widget.session.ink.removeListener(_inkSelectionChanged);
    editing.removeListener(_documentChanged);
    viewer.removeListener(_updatePageTiles);
    _pageTilesChanges.dispose();
    navigation.dispose();
    _searchText.dispose();
    viewer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact =
          constraints.maxHeight < 360 ||
          (constraints.maxWidth < 480 &&
              MediaQuery.textScalerOf(context).scale(16) > 24);
      final compactPages = NoterTheme.mobileLayout(constraints.maxWidth);
      final pagesVisible =
          !compactPages && (_showPages ?? constraints.maxWidth >= 900);
      final sidebarVisible = widget.showChrome && pagesVisible;
      if (_lastSidebar != null && _lastSidebar != sidebarVisible) {
        final viewport = viewer.captureViewport();
        final scale = viewer.zoom;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || viewport == null) return;
          final resized = viewer.captureViewport();
          if (resized == null || viewer.zoom <= 0) return;
          // PdfViewport stores a fit-width multiple; viewer.zoom is actual
          // pixels per PDF point. Keep the latter invariant when a panel
          // changes the available width, as well as the reading anchor.
          viewer.restoreViewport(
            PdfViewport(
              page: viewport.page,
              top: viewport.top,
              left: viewport.left,
              zoom: resized.zoom * scale / viewer.zoom,
            ),
          );
        });
      }
      _lastSidebar = sidebarVisible;
      return Focus(
        onFocusChange: (focused) {
          if (focused) widget.onActivate();
        },
        onKeyEvent: (_, event) {
          if (widget.useDefaultSaveShortcut &&
              singlePage &&
              event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.keyS &&
              (HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed)) {
            (widget.onSaveAll ?? widget.session.save)();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            if (_learning) _reviewControls(),
            if (_showSearch && widget.showChrome)
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: PdfSearchField(
                        controller: viewer,
                        searchController: _searchText,
                        hintText: 'Search PDF',
                        showOptions: false,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close search',
                    onPressed: toggleSearch,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            if (widget.split && widget.showChrome)
              SizedBox(
                height:
                    12 +
                    MediaQuery.textScalerOf(context).scale(16).clamp(20, 48),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      widget.session.note.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            if (widget.showChrome && _mode != _Mode.normal && !_learning)
              Container(
                decoration: const BoxDecoration(
                  color: NoterTheme.workspace,
                  border: Border(bottom: BorderSide(color: NoterTheme.border)),
                ),
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _learning
                            ? 'Study mode · tap to reveal'
                            : _mode == _Mode.lasso
                            ? 'Circle content with the pen'
                            : 'Draw a study cover with the pen',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Exit mode',
                      onPressed: () {
                        final old = _returnTool;
                        normalTool();
                        editing.tool = old;
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            if (widget.showChrome &&
                widget.active &&
                (editing.selectedAnnotationSlots.isNotEmpty ||
                    widget.session.ink.selected.isNotEmpty))
              SizedBox(
                height: 48,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: editing.copySelectedAnnotations,
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy'),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          editing.pasteAnnotations(viewer.currentPage);
                        },
                        icon: const Icon(Icons.paste),
                        label: const Text('Paste'),
                      ),
                      IconButton(
                        tooltip: 'Transform selection',
                        onPressed: _transformDialog,
                        icon: const Icon(Icons.transform),
                      ),
                      IconButton(
                        tooltip: 'Delete selection',
                        onPressed: editing.deleteSelected,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
            if (_loupe && widget.showChrome)
              ListenableBuilder(
                listenable: _overviewChanges,
                builder: (context, _) => _overview(compact ? 64 : 112),
              ),
            Expanded(
              child: Row(
                children: [
                  if (sidebarVisible)
                    WorkspaceSidebar(
                      child: SizedBox(
                        key: const ValueKey('editor-page-sidebar'),
                        width: 144,
                        child: _pageTiles(),
                      ),
                    ),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (singlePage)
                          SinglePageView(
                            viewer: viewer,
                            editing: editing,
                            background: NoterTheme.workspace,
                            canSwipe: () =>
                                !widget.session.preferences.fingerDrawsInk &&
                                _mode == _Mode.normal &&
                                !_learning &&
                                _inkPointer == null &&
                                _customPointer == null,
                            child: PdfViewer(
                              key: _pdfKey,
                              editing: editing,
                              controller: viewer,
                              minZoom: .001,
                              backgroundColor: NoterTheme.workspace,
                              pageColor: Colors.white,
                              presenter: NoterTextSelectionPresenter(
                                hideAnnotationActions: () =>
                                    widget.session.ink.selected.isNotEmpty,
                              ),
                              onAnnotationTap: (details) {
                                final action = details.annotation.action;
                                final target = switch (action) {
                                  PdfGoToAction() =>
                                    action.destination.pageIndex,
                                  PdfNamedAction(name: 'NextPage') =>
                                    viewer.currentPage + 1,
                                  PdfNamedAction(name: 'PrevPage') =>
                                    viewer.currentPage - 1,
                                  PdfNamedAction(name: 'FirstPage') => 0,
                                  PdfNamedAction(name: 'LastPage') =>
                                    editing.document.pageCount - 1,
                                  _ => null,
                                };
                                if (target != null) viewer.jumpToPage(target);
                              },
                              imagePicker: (_) => FileGateway().pickImage(),
                              pageOverlayBuilder: _overlays,
                            ),
                          )
                        else
                          PdfEditorView(
                            key: _pdfKey,
                            controller: editing,
                            viewerController: viewer,
                            backgroundColor: NoterTheme.workspace,
                            pageColor: Colors.white,
                            viewerTheme: PdfViewerThemeData(
                              canvasColor: NoterTheme.workspace,
                              selectionColor: NoterTheme.accent.withValues(
                                alpha: .16,
                              ),
                              selectionHandleColor: NoterTheme.accent,
                              annotationChromeColor: NoterTheme.accent,
                              elementChromeColor: NoterTheme.accent,
                              searchMatchColor: NoterTheme.markupYellow
                                  .withValues(alpha: .4),
                              currentSearchMatchColor: NoterTheme.markupYellow
                                  .withValues(alpha: .75),
                              chipColor: Colors.white,
                              chipForegroundColor: NoterTheme.ink,
                            ),
                            showSaveButton: false,
                            presenter: NoterTextSelectionPresenter(
                              hideAnnotationActions: () =>
                                  widget.session.ink.selected.isNotEmpty,
                            ),
                            onSave: widget.useDefaultSaveShortcut
                                ? (_) async {
                                    await widget.session.save();
                                  }
                                : null,
                            imagePicker: (_) => FileGateway().pickImage(),
                            pageOverlayBuilder: _overlays,
                            features: PdfEditorFeatures(
                              toolbar: false,
                              headerBar: false,
                              author: false,
                              authorEditable: false,
                              reflowView: false,
                              pageColorEditable: false,
                              bookmarks: false,
                              pageEditing: false,
                              thumbnails: false,
                              annotationSidebar: false,
                              annotationLibrary: false,
                              propertiesPanel: false,
                              markup: true,
                              flatten: false,
                              colorProcessing: false,
                              tools: {
                                PdfEditTool.select,
                                PdfEditTool.ink,
                                PdfEditTool.highlight,
                                PdfEditTool.eraser,
                                PdfEditTool.freeText,
                                PdfEditTool.image,
                              },
                            ),
                          ),
                        if (widget.active &&
                            _mode == _Mode.normal &&
                            !_learning)
                          Positioned.fill(
                            child: NoterTextSelectionOverlay(
                              onCreateSourceNote:
                                  widget.session.repository
                                      is LocalNotebookRepository
                                  ? _sourceNote
                                  : null,
                              viewer: viewer,
                              editing: editing,
                            ),
                          ),
                        Positioned.fill(child: _selectionHandles()),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: EraserCursorPainter(_eraserContact),
                              ),
                            ),
                          ),
                        ),
                        if (!widget.session.toolsReady)
                          const Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: Color(0xCCFFFFFF),
                                child: Center(child: Text('Loading tool …')),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (widget.showChrome || singlePage)
              _navigationBar(pagesVisible, compactPages),
          ],
        ),
      );
    },
  );
}

class _GesturePainter extends CustomPainter {
  _GesturePainter(this.points, this.tape);
  final List<Offset> points;
  final bool tape;
  @override
  bool? hitTest(Offset position) => false;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = NoterTheme.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    if (tape) {
      canvas.drawRect(Rect.fromPoints(points.first, points.last), paint);
    } else {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final p in points.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GesturePainter old) => true;
}

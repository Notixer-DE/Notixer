// Headless UI journey. Run through tools/preview.py.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show kPrimaryStylusButton, kSecondaryStylusButton, kStylusContact;
import 'package:flutter/rendering.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart'
    show PdfDocument, PdfEditorView, PdfEditTool;
import 'package:noter/data/file_gateway.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/main.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/editor/operations.dart';
import 'package:noter/input/stylus_eraser.dart';

class PreviewBinding extends NoterBinding {
  static Size size = const Size(1100, 800);
  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) =>
      ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(size),
        physicalConstraints: BoxConstraints.tight(size),
        devicePixelRatio: 1,
      );
}

final boundary = GlobalKey();
final errors = <String>[];
Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 700));
Element find(bool Function(Widget) matches, {bool last = false}) {
  Element? result;
  void visit(Element element) {
    if (result != null && !last) return;
    if (matches(element.widget)) {
      result = element;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  if (result == null) throw StateError('Widget not found');
  return result!;
}

Future<void> tap(String label) async {
  final text = findAll((w) => w is Text && w.data == label);
  await tapElement(
    text.isNotEmpty
        ? text.last
        : find((w) => w is Tooltip && w.message == label),
  );
}

List<Element> findAll(bool Function(Widget) matches) {
  final result = <Element>[];
  void visit(Element e) {
    if (matches(e.widget)) result.add(e);
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return result;
}

Future<void> tapElement(Element element) async {
  await Scrollable.ensureVisible(element, alignment: .5);
  await pause();
  final box = element.findRenderObject()! as RenderBox;
  final center = box.localToGlobal(box.size.center(Offset.zero));
  WidgetsBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: 11, position: center),
  );
  WidgetsBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: 11, position: center),
  );
  await pause();
}

Future<void> command(String action) async {
  final menu =
      find(
            (w) =>
                w is PopupMenuButton<String> && w.tooltip == 'Tools and export',
          ).widget
          as PopupMenuButton<String>;
  menu.onSelected!(action);
  await pause();
}

Future<void> draw(
  List<Offset> points, {
  int pointer = 20,
  int buttons = kStylusContact,
}) async {
  WidgetsBinding.instance.handlePointerEvent(
    PointerDownEvent(
      pointer: pointer,
      kind: ui.PointerDeviceKind.stylus,
      position: points.first,
      buttons: buttons,
    ),
  );
  for (var i = 1; i < points.length; i++) {
    WidgetsBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        pointer: pointer,
        kind: ui.PointerDeviceKind.stylus,
        position: points[i],
        delta: points[i] - points[i - 1],
        buttons: buttons,
      ),
    );
  }
  WidgetsBinding.instance.handlePointerEvent(
    PointerUpEvent(
      pointer: pointer,
      kind: ui.PointerDeviceKind.stylus,
      position: points.last,
    ),
  );
  await pause();
}

Rect pageVisible(EditorPaneState pane) {
  final element = findAll((w) => w is PdfEditorView).firstWhere(
    (e) => (e.widget as PdfEditorView).viewerController == pane.viewer,
  );
  final box = element.findRenderObject()! as RenderBox;
  final region = box.localToGlobal(Offset.zero) & box.size;
  final page = pane.editing.document.page(pane.viewer.currentPage);
  final pageRect = pane.viewer.globalRectOf(
    pane.viewer.currentPage,
    page.cropBox,
  )!;
  return pageRect.intersect(
    Rect.fromLTRB(
      region.left + 6,
      region.top +
          ((element.widget as PdfEditorView).features.headerBar ? 60 : 6),
      region.right - 6,
      region.bottom - 46,
    ),
  );
}

Future<void> capture(String name) async {
  await pause();
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await render.toImage();
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  await File('build/$name.png').writeAsBytes(png.buffer.asUint8List());
  image.dispose();
}

Future<void> main() async {
  final largeText = Platform.environment['NOTER_PREVIEW_SMALL'] == '3';
  final small = Platform.environment['NOTER_PREVIEW_SMALL'] == '1' || largeText;
  final landscape = Platform.environment['NOTER_PREVIEW_SMALL'] == '2';
  PreviewBinding.size = landscape
      ? const Size(812, 375)
      : small
      ? const Size(375, 812)
      : const Size(1100, 800);
  PreviewBinding();
  FileGateway.initialize();
  FlutterError.onError = (details) {
    errors.add(details.toString());
    stderr.writeln(details);
  };
  final repo = LocalNotebookRepository(
    await Directory.systemTemp.createTemp('noter-ui-preview-'),
  );
  try {
    runApp(
      RepaintBoundary(
        key: boundary,
        child: largeText
            ? Builder(
                builder: (context) {
                  final app =
                      NoterApp(repository: repo).build(context) as MaterialApp;
                  return MaterialApp(
                    title: app.title,
                    theme: app.theme,
                    locale: app.locale,
                    supportedLocales: app.supportedLocales,
                    localizationsDelegates: app.localizationsDelegates,
                    debugShowCheckedModeBanner: false,
                    home: app.home,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: const TextScaler.linear(2)),
                      child: child!,
                    ),
                  );
                },
              )
            : NoterApp(repository: repo),
      ),
    );
    await pause();
    await capture(
      landscape
          ? 'library-landscape'
          : small
          ? largeText
                ? 'library-large-text'
                : 'library-phone'
          : 'library-desktop',
    );
    final syncButtons = findAll(
      (w) => w is IconButton && w.tooltip == 'Eigenen Server synchronisieren',
    );
    await tapElement(
      syncButtons.isNotEmpty
          ? syncButtons.first
          : find((w) => w is NavigationDestination && w.label == 'Sync'),
    );
    // Lazy list children can initially be below the cache extent at large fonts.
    for (
      var step = 0;
      step < 12 &&
          findAll((w) => w is Text && w.data == 'Connect to server').isEmpty;
      step++
    ) {
      ScrollableState? scroll;
      void visit(Element e) {
        if (e is StatefulElement && e.state is ScrollableState) {
          scroll ??= e.state as ScrollableState;
        }
        e.visitChildren(visit);
      }

      find((w) => w is ListView, last: true).visitChildren(visit);
      final position = scroll!.position;
      position.jumpTo(
        (position.pixels + 400).clamp(0, position.maxScrollExtent),
      );
      await pause();
    }
    find((w) => w is Text && w.data == 'Connect to server');
    await tap('Connect to server');
    await tap('Safely saved');
    ScrollableState? syncScroll;
    void findSyncScroll(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        syncScroll ??= e.state as ScrollableState;
      }
      e.visitChildren(findSyncScroll);
    }

    find((w) => w is ListView, last: true).visitChildren(findSyncScroll);
    syncScroll!.position.jumpTo(0);
    await pause();
    find(
      (w) =>
          w is Text &&
          w.data ==
              'HTTPS-Server address ohne Pfad angeben. HTTP ist nur lokal erlaubt.',
    );
    await capture(
      'sync-${largeText
          ? 'large-text'
          : landscape
          ? 'landscape'
          : small
          ? 'phone'
          : 'desktop'}',
    );
    await tapElement(find((w) => w is BackButton));
    await pause();
    if (Platform.environment['NOTER_PREVIEW_SYNC_ONLY'] == '1') {
      if (errors.isNotEmpty) {
        throw StateError('${errors.length} Flutter errors');
      }
      // ignore: avoid_print
      print(
        'PASS: E2EE server setup, recovery confirmation, validation and navigation without Flutter errors',
      );
      exit(0);
    }
    await tap('New note');
    await tap('Create');
    await pause();
    find((w) => w is Text && w.data == 'New note');
    final focusedPaneElement = find((w) => w is EditorPane) as StatefulElement;
    final focusedPane = focusedPaneElement.state as EditorPaneState;
    final initialView =
        find((w) => w is PdfEditorView).findRenderObject()! as RenderBox;
    final initialHeight = initialView.size.height;
    focusedPane.viewer.setZoom(1.5);
    await pause();
    final initialZoom = focusedPane.viewer.zoom;
    final initialTool = focusedPane.editing.tool;
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Hide toolbars'),
    );
    final hiddenPane = find((w) => w is EditorPane) as StatefulElement;
    final focusedView =
        find((w) => w is PdfEditorView).findRenderObject()! as RenderBox;
    if (!identical(hiddenPane.state, focusedPane) ||
        focusedView.size.height < initialHeight + 80 ||
        (focusedPane.viewer.zoom - initialZoom).abs() > .01 ||
        focusedPane.editing.tool != initialTool ||
        findAll(
          (w) =>
              w is PopupMenuButton<String> && w.tooltip == 'Tools and export',
        ).isNotEmpty) {
      throw StateError(
        'Focus mode lost editor state or did not enlarge the PDF: '
        'samePane=${identical(hiddenPane.state, focusedPane)}, '
        'height=${focusedView.size.height}/$initialHeight, '
        'zoom=${focusedPane.viewer.zoom}/$initialZoom, '
        'tool=${focusedPane.editing.tool}/$initialTool',
      );
    }
    final focusedArea = pageVisible(focusedPane);
    final previousInk = focusedPane.editing.document
        .page(focusedPane.viewer.currentPage)
        .annotations
        .length;
    await draw([
      focusedArea.center,
      focusedArea.center + const Offset(20, 4),
      focusedArea.center + const Offset(40, 8),
    ], pointer: 70);
    focusedPane.editing.finishInk();
    if (focusedPane.editing.document
            .page(focusedPane.viewer.currentPage)
            .annotations
            .length <=
        previousInk) {
      throw StateError('Writing with hidden bars failed');
    }
    focusedPane.editing.undo();
    await capture(
      'focus-${largeText
          ? 'large-text'
          : landscape
          ? 'landscape'
          : small
          ? 'phone'
          : 'desktop'}',
    );
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Show toolbars'),
    );
    if (!identical(
          (find((w) => w is EditorPane) as StatefulElement).state,
          focusedPane,
        ) ||
        (focusedPane.viewer.zoom - initialZoom).abs() > .01) {
      throw StateError('Restoring bars reset the viewport');
    }
    if (Platform.environment['NOTER_PREVIEW_FOCUS_ONLY'] == '1') {
      if (errors.isNotEmpty) {
        throw StateError('${errors.length} Flutter errors');
      }
      // ignore: avoid_print
      print(
        'PASS: PDF focus mode enlarges canvas, accepts stylus input and retains viewport and session',
      );
      exit(0);
    }
    focusedPane.viewer.setZoom(1);
    await focusedPane.viewer.jumpToPage(0);
    await pause();
    // Draw using real stylus pointer events, then verify the saved PDF.
    final editorBefore = find((w) => w is PdfEditorView);
    final pdfView = editorBefore.widget as PdfEditorView;
    final bounds = editorBefore.findRenderObject()! as RenderBox;
    final viewRect = (bounds.localToGlobal(Offset.zero) & bounds.size);
    final pageRect = pdfView.viewerController!.globalRectOf(
      0,
      pdfView.controller!.document.page(0).cropBox,
    )!;
    final visible = pageRect.intersect(
      Rect.fromLTRB(
        viewRect.left + 24,
        viewRect.top + (pdfView.features.headerBar ? 60 : 12),
        viewRect.right - 24,
        viewRect.bottom - 90,
      ),
    );
    final x = visible.center.dx - 30;
    final y = visible.top + 12;
    WidgetsBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: 2,
        kind: ui.PointerDeviceKind.stylus,
        position: Offset(x, y),
        pressure: 0.2,
        pressureMin: 0,
        pressureMax: 1,
      ),
    );
    for (var i = 1; i <= 15; i++) {
      WidgetsBinding.instance.handlePointerEvent(
        PointerMoveEvent(
          pointer: 2,
          kind: ui.PointerDeviceKind.stylus,
          position: Offset(x + i * 4, y + i * 1),
          delta: const Offset(4, 1),
          pressure: i / 15,
          pressureMin: 0,
          pressureMax: 1,
        ),
      );
    }
    WidgetsBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: 2,
        kind: ui.PointerDeviceKind.stylus,
        position: Offset(x + 60, y + 15),
      ),
    );
    await pause();
    void expectStableCanvas() {
      if ((bounds.localToGlobal(Offset.zero) & bounds.size) != viewRect) {
        throw StateError('Save status shifted the writing surface');
      }
    }

    expectStableCanvas();
    await tap('Save');
    expectStableCanvas();
    final note = (await repo.list()).single;
    final saved = PdfDocument.open(await repo.load(note.id));
    if (saved.page(0).annotations.isEmpty) {
      throw StateError('Stylus stroke was not saved');
    }
    final editor = find((w) => w is PdfEditorView).widget as PdfEditorView;
    final editing = editor.controller!;
    // A held side button must erase from the very first contact, then return
    // to the pen when lifted, even when the final up has no button bits.
    for (final button in [kPrimaryStylusButton, kSecondaryStylusButton]) {
      editing.tool = PdfEditTool.ink;
      WidgetsBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: 3,
          kind: ui.PointerDeviceKind.stylus,
          position: Offset(x, y),
          buttons: kStylusContact | button,
        ),
      );
      if (editing.tool != PdfEditTool.eraser) {
        throw StateError('Side button did not arm eraser');
      }
      for (var i = 1; i <= 15; i++) {
        WidgetsBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            pointer: 3,
            kind: ui.PointerDeviceKind.stylus,
            position: Offset(x + i * 4, y + i * 1),
            delta: const Offset(4, 1),
            buttons: kStylusContact | button,
          ),
        );
      }
      WidgetsBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: 3,
          kind: ui.PointerDeviceKind.stylus,
          position: Offset(x + 60, y + 15),
        ),
      );
      if (editing.tool != PdfEditTool.ink) {
        throw StateError('Pen was not restored');
      }
      await pause();
      await tap('Save');
      if (PdfDocument.open(
        await repo.load(note.id),
      ).page(0).annotations.isNotEmpty) {
        throw StateError('Side-button eraser did not remove the stroke');
      }
      // Restore the stroke to test the second button against the same ink.
      editing.undo();
      await pause();
    }
    // Press and release during an existing contact: every segment must use
    // the correct tool without leaving the pointer/gesture state stuck.
    editing.tool = PdfEditTool.highlight;
    WidgetsBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: 4,
        kind: ui.PointerDeviceKind.stylus,
        position: Offset(x, y + 30),
      ),
    );
    WidgetsBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        pointer: 4,
        kind: ui.PointerDeviceKind.stylus,
        position: Offset(x + 10, y + 30),
        buttons: kStylusContact | kPrimaryStylusButton,
      ),
    );
    if (editing.tool != PdfEditTool.eraser) {
      throw StateError('Mid-stroke press did not erase');
    }
    WidgetsBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        pointer: 4,
        kind: ui.PointerDeviceKind.stylus,
        position: Offset(x + 20, y + 30),
        buttons: kStylusContact,
      ),
    );
    if (editing.tool != PdfEditTool.highlight) {
      throw StateError('Highlighter was not restored');
    }
    WidgetsBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: 4,
        kind: ui.PointerDeviceKind.stylus,
        position: Offset(x + 30, y + 30),
      ),
    );
    await pause();
    await tap('Save');
    // Exercise new tools through the actual page overlays.
    final paneElement = find((w) => w is EditorPane) as StatefulElement;
    final pane = paneElement.state as EditorPaneState;
    await tap('Highlight');
    if (editing.tool != PdfEditTool.highlight ||
        editing.preferences.strokeWidth != 14) {
      throw StateError('Pen favorite did not apply');
    }
    pane.toggleTape();
    await pause();
    final area = pageVisible(pane);
    final start = Offset(
      area.left + area.width * .2,
      area.top + area.height * .25,
    );
    final end = Offset(
      area.left + area.width * .65,
      area.top + area.height * .45,
    );
    await draw([start, Offset(end.dx, start.dy), end]);
    if (!editing.document
        .page(pane.viewer.currentPage)
        .annotations
        .any(isTape)) {
      throw StateError('Drawing a cover did not create it');
    }
    pane.normalTool();
    pane.toggleLearning();
    await pause();
    await tapElement(
      find((w) => w is Semantics && w.properties.label == 'Reveal answer'),
    );
    find((w) => w is Semantics && w.properties.label == 'Hide answer');
    await capture(
      landscape
          ? 'learning-landscape'
          : small
          ? largeText
                ? 'learning-large-text'
                : 'learning-phone'
          : 'learning-desktop',
    );
    // Learning input must not swallow the floating reveal button.
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Hide toolbars'),
    );
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Show toolbars'),
    );
    find((w) => w is Semantics && w.properties.label == 'Hide answer');
    // Two views of one document share edits while retaining independent modes.
    await command('split');
    await tap('Open the same note again');
    await pause();
    final paneElements = findAll(
      (w) => w is EditorPane,
    ).cast<StatefulElement>();
    if (paneElements.length != 2) throw StateError('Split view missing');
    final left = paneElements[0].state as EditorPaneState,
        right = paneElements[1].state as EditorPaneState;
    if (!identical(left.editing, right.editing)) {
      throw StateError('Same document opened as conflicting sessions');
    }
    right.normalTool();
    right.editing.tool = PdfEditTool.ink;
    await pause();
    final splitArea = pageVisible(right);
    final before = editing.document
        .page(right.viewer.currentPage)
        .annotations
        .length;
    await draw([
      splitArea.center,
      splitArea.center + const Offset(8, 2),
      splitArea.center + const Offset(16, 4),
    ], pointer: 21);
    await tap('Save');
    if (editing.document.page(right.viewer.currentPage).annotations.length <=
        before) {
      throw StateError('Writing in second view failed');
    }
    // A cover revealed in the left pane must remain revealed when right writes.
    find((w) => w is Semantics && w.properties.label == 'Hide answer');
    right.toggleLoupe();
    await pause();
    await capture(
      landscape
          ? 'split-landscape'
          : small
          ? largeText
                ? 'split-large-text'
                : 'split-phone'
          : 'split-desktop',
    );
    right.toggleLoupe();
    await pause();
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Hide toolbars'),
    );
    final hiddenSplit = findAll((w) => w is EditorPane).cast<StatefulElement>();
    if (!identical(hiddenSplit[0].state, left) ||
        !identical(hiddenSplit[1].state, right)) {
      throw StateError('Hiding bars recreated split panes');
    }
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Show toolbars'),
    );
    await command('closeSplit');
    await pause();
    // A second document owns a separate controller/save queue. Erasing in it
    // must never remove ink from the first document.
    final another = await repo.create(
      'Second Note',
      await createPaper('blank'),
    );
    await command('split');
    await tap('Second Note');
    await pause();
    final independent = findAll((w) => w is EditorPane).cast<StatefulElement>();
    final reference = independent[0].state as EditorPaneState;
    final separate = independent[1].state as EditorPaneState;
    if (identical(reference.editing, separate.editing)) {
      throw StateError('Different notes share a controller');
    }
    final originalCount = reference.editing.document.page(0).annotations.length;
    final targetArea = pageVisible(separate);
    final targetStroke = [
      targetArea.center,
      targetArea.center + const Offset(8, 2),
      targetArea.center + const Offset(16, 4),
    ];
    await draw(targetStroke, pointer: 30);
    await tap('Save');
    if (PdfDocument.open(
      await repo.load(another.id),
    ).page(0).annotations.isEmpty) {
      throw StateError('Second document did not save');
    }
    await draw(
      targetStroke,
      pointer: 31,
      buttons: kStylusContact | kPrimaryStylusButton,
    );
    await tap('Save');
    if (separate.editing.document.page(0).annotations.isNotEmpty ||
        reference.editing.document.page(0).annotations.length !=
            originalCount) {
      throw StateError('Stylus eraser affected the wrong note');
    }
    await tapElement(independent[0]);
    await command('pages');
    await tapElement(
      find(
        (w) => w is IconButton && w.tooltip == 'Copy to another note',
        last: true,
      ),
    );
    await tap('Second Note');
    await pause();
    if (separate.editing.document.pageCount != 2 ||
        PdfDocument.open(await repo.load(another.id)).pageCount != 2) {
      throw StateError('Page copy into live session failed');
    }
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Close', last: true),
    );
    await command('closeSplit');
    await pause();
    await repo.delete(another.id);
    left.normalTool();
    left.editing.tool = PdfEditTool.ink;
    await pause();
    // Lasso input goes through the custom page hit-test layer.
    left.toggleLasso();
    await pause();
    final lassoArea = pageVisible(left);
    await draw([
      lassoArea.topLeft + const Offset(2, 2),
      lassoArea.topRight - const Offset(2, -2),
      lassoArea.bottomRight - const Offset(2, 2),
      lassoArea.bottomLeft + const Offset(2, -2),
      lassoArea.topLeft + const Offset(2, 2),
    ], pointer: 22);
    if (editing.selectedAnnotationSlots.isEmpty) {
      throw StateError('Lasso gesture selected nothing');
    }
    editing.clearAnnotationSelection();
    await pause();
    // Open page management and duplicate using its actual control.
    final pagesBefore = editing.document.pageCount;
    await command('pages');
    await tapElement(
      find(
        (w) => w is IconButton && w.tooltip == 'Duplicate pages',
        last: true,
      ),
    );
    if (editing.document.pageCount != pagesBefore + 1) {
      throw StateError('Page management duplication failed');
    }
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Close', last: true),
    );
    await tap('Save');
    // Organization dialog and persistence after leaving the workspace.
    await tapElement(
      find((w) => w is IconButton && w.tooltip == 'Back to library'),
    );
    await pause();
    final folder = await repo.catalog.ensureFolder('Schule');
    await tapElement(
      find((w) => w is PopupMenuButton<String> && w.tooltip == 'Note actions'),
    );
    await tap('Folders and tags');
    final field =
        find(
              (w) =>
                  w is DropdownButtonFormField<String> &&
                  w.decoration.labelText == 'Folder',
            ).widget
            as DropdownButtonFormField<String>;
    field.onChanged!(folder.id);
    final tagField =
        find((w) => w is TextField && w.decoration?.labelText == 'Tags').widget
            as TextField;
    tagField.controller!.text = 'Maths, Exam';
    await tap('Save');
    await pause();
    if (findAll((w) => w is Text && w.data == '#Maths').isEmpty) {
      await tapElement(find((w) => w is DrawerButton));
    }
    await tap('#Maths');
    await pause();
    find((w) => w is Text && w.data == 'New note');
    await tap('Reset filters');
    await pause();
    final organized = (await repo.list()).single;
    if (organized.tags.length != 2 || organized.folderId != folder.id) {
      throw StateError('Organization dialog did not save tags and folder');
    }
    await capture(
      landscape
          ? 'organized-landscape'
          : small
          ? largeText
                ? 'organized-large-text'
                : 'organized-phone'
          : 'organized-desktop',
    );
    if (errors.isNotEmpty) throw StateError('${errors.length} Flutter errors');
    // ignore: avoid_print
    print(
      'PASS: ${landscape
          ? 'landscape'
          : small
          ? 'phone'
          : 'desktop'} library → create note → stylus drawing → side-button erasing → covers → split editing → loupe → lasso → pages → organization succeeds without Flutter errors',
    );
    exit(0);
  } catch (e, stack) {
    stderr.writeln('$e\n$stack');
    exit(1);
  }
}

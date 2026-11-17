import 'dart:io';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/catalog.dart';
import 'package:noter/data/document_session.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/editor.dart';
import 'package:noter/ui/editor_pane.dart';
import 'package:noter/ui/editor_toolbar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repository;
  late DocumentSession session;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-toolbar-');
    repository = LocalNotebookRepository(directory);
    final bytes = await createPaper('blank');
    final note = await repository.create('Toolbar', bytes);
    session = DocumentSession(
      note,
      bytes,
      repository,
      preferencesStore: PdfMemoryPreferencesStore(),
    );
    await Future.wait([session.ready, session.toolReady]);
  });
  tearDown(() async {
    session.dispose();
    await directory.delete(recursive: true);
  });

  bool selected(WidgetTester tester, String label) =>
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == label,
            ),
          )
          .isSelected ??
      false;
  List<int> presets(WidgetTester tester) => [
    for (var i = 0; i < repository.catalog.presets.length; i++)
      if (tester
              .widget<Semantics>(find.byKey(ValueKey('pen-preset-$i')))
              .properties
              .selected ==
          true)
        i,
  ];

  Future<void> mount(WidgetTester tester, {PenPreset? preferred}) async {
    await tester.binding.setSurfaceSize(const Size(1600, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              EditorToolbar(
                session: session,
                catalog: repository.catalog,
                preferredPreset: preferred,
                onTextSelection: () {},
                onTool: (_) {},
                onLasso: () {},
                onTape: () {},
                onImage: () {},
                onPreset: (_) {},
                onEditPreset: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void apply(PenPreset preset) {
    session.editing.tool = PdfEditTool.values.byName(preset.tool);
    session.preferences
      ..color = Color(preset.color)
      ..strokeWidth = preset.width
      ..opacity = preset.opacity;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var done = false;
    final flushing = repository.flush().then((_) => done = true);
    for (var i = 0; i < 150 && !done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(done, isTrue);
    await flushing;
  }

  testWidgets(
    'eraser diameter is independent of pen width and configurable for the side button',
    (tester) async {
      await mount(tester);
      final originalWidth = session.preferences.strokeWidth;
      await tester.tap(find.byTooltip('Tool settings'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('eraser-diameter'));
      await tester.ensureVisible(slider);
      final rect = tester.getRect(slider);
      await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
      await tester.pump();
      expect(session.preferences.eraserRadius, greaterThan(8));
      expect(session.preferences.strokeWidth, originalWidth);
      expect(find.textContaining('Eraser diameter:'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'tracks the actual marker style, including pressure and manual changes',
    (tester) async {
      final marker = repository.catalog.presets[2];
      apply(marker);
      await mount(tester);
      expect(selected(tester, 'Highlighter'), isTrue);
      expect(selected(tester, 'Pen'), isFalse);
      expect(presets(tester), [2]);
      for (final change in [
        () => session.preferences.color = Colors.red,
        () => session.preferences.strokeWidth = marker.width + 1,
        () => session.preferences.opacity = .7,
      ]) {
        change();
        await tester.pump();
        expect(presets(tester), isEmpty);
        apply(marker);
        await tester.pump();
        expect(presets(tester), [2]);
      }
      final changing = repository.catalog.drawingPreferences
          .setPressureSensitive('highlight', false);
      var done = false;
      changing.then((_) => done = true);
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(done, isTrue);
      await tester.pump();
      expect(presets(tester), isEmpty);
      session.editing.tool = PdfEditTool.freeText;
      await tester.pump();
      expect(selected(tester, 'Insert text'), isTrue);
      expect(selected(tester, 'Highlighter'), isFalse);
      await finish(tester);
    },
  );

  testWidgets(
    'identical favourites have one winner and retain the clicked choice',
    (tester) async {
      final first = repository.catalog.presets.first;
      final duplicate = PenPreset(
        'Kopie',
        first.tool,
        first.color,
        first.width,
        first.opacity,
      );
      await tester.runAsync(() => repository.catalog.setPreset(1, duplicate));
      apply(first);
      await mount(tester, preferred: repository.catalog.presets[1]);
      expect(presets(tester), [1]);
      await finish(tester);
    },
  );

  testWidgets(
    'lasso and tape show their own activity instead of the select tool',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: EditorPage(
            note: session.note,
            bytes: session.editing.bytes,
            repository: repository,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pane = tester.state<EditorPaneState>(find.byType(EditorPane));
      pane.toggleLasso();
      await tester.pumpAndSettle();
      expect(selected(tester, 'Lasso selection'), isTrue);
      expect(selected(tester, 'Select'), isFalse);
      pane.toggleTape();
      await tester.pumpAndSettle();
      expect(selected(tester, 'Draw study cover'), isTrue);
      expect(selected(tester, 'Lasso selection'), isFalse);
      pane.normalTool();
      pane.widget.session.eraser.setBaseTool(PdfEditTool.highlight);
      await tester.pumpAndSettle();
      expect(selected(tester, 'Draw study cover'), isFalse);
      expect(selected(tester, 'Highlighter'), isTrue);
      await finish(tester);
    },
  );
}

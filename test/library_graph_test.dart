import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/library_graph.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/data/markdown_library.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/library_graph_page.dart';
import 'package:noter/ui/noter_theme.dart';

void main() {
  late Directory directory;
  late LocalNotebookRepository repository;
  late Notebook a, b, pdf;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-graph-');
    repository = LocalNotebookRepository(directory);
    a = await MarkdownLibrary(repository).create('Alpha');
    b = await MarkdownLibrary(repository).create('Beta');
    pdf = await repository.create(
      'Reference PDF',
      await createPaper('blank', pages: 3),
    );
    b = await repository.save(
      b.copy(tags: ['Study', 'study']),
      MarkdownDocument('## Target').encode(),
    );
    a = await repository.save(
      a.copy(tags: ['study', 'Exam']),
      MarkdownDocument('''
[B](<${MarkdownLibrary.linkTo(a, b)}#target>)
[Again](<${MarkdownLibrary.linkTo(a, b)}>)
[Page](<${MarkdownLibrary.linkTo(a, pdf)}#page=2>)
[Local](#same)
[Web](https://example.com)
![Image](assets/image.png)
[Missing](missing.md)
''').encode(),
    );
  });
  tearDown(() async {
    await repository.flush();
    await directory.delete(recursive: true);
  });

  test(
    'graph deduplicates file links and tags, and includes PDF destinations',
    () async {
      final graph = await LibraryGraph.load(repository);
      expect(graph.nodes.where((node) => !node.isTag).length, 3);
      expect(graph.nodes.where((node) => node.isTag).length, 2);
      expect(graph.edges, {
        (from: 'note:${a.id}', to: 'note:${b.id}'),
        (from: 'note:${a.id}', to: 'note:${pdf.id}'),
        (from: 'note:${a.id}', to: 'tag:study'),
        (from: 'note:${a.id}', to: 'tag:exam'),
        (from: 'note:${b.id}', to: 'tag:study'),
      });
      expect(graph.warnings, isEmpty);
      final edited = await LibraryGraph.load(
        repository,
        sourceOverrides: {a.id: '[Self](#local)'},
      );
      expect(
        edited.edges.where((edge) => edge.to.startsWith('note:')),
        isEmpty,
      );
    },
  );

  test(
    'PDF page fragments are positive, one-based, and bounded by integer parsing',
    () {
      expect(markdownPdfPage('page=12'), 12);
      for (final fragment in [
        '',
        'page=0',
        'page=-1',
        'page=x',
        'page=1.5',
        'section',
        'page=2&zoom=100',
      ]) {
        expect(markdownPdfPage(fragment), isNull);
      }
    },
  );

  for (final (width, textScale) in [
    (390.0, 1.0),
    (1200.0, 1.0),
    (390.0, 2.0),
  ]) {
    testWidgets(
      'graph fits width $width at text scale $textScale, filters tags and opens a file',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Notebook? selected;
        await tester.pumpWidget(
          MaterialApp(
            theme: NoterTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open graph'),
                  onPressed: () async {
                    selected = await Navigator.push<Notebook>(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            LibraryGraphPage(repository: repository),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open graph'));
        for (var i = 0; i < 150; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (find
              .byKey(const ValueKey('graph-counts'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Semantics>(find.byKey(const ValueKey('graph-counts')))
              .properties
              .label,
          '3 files · 5 connections',
        );
        if (width == 1200) {
          final viewer = find.byType(InteractiveViewer);
          final transform = tester
              .widget<InteractiveViewer>(viewer)
              .transformationController!;
          final node = find.byKey(ValueKey('graph-node-note:${a.id}'));
          final fittedCenter = tester.getCenter(node);
          for (var i = 0; i < 6; i++) {
            final gesture = await tester.startGesture(
              tester.getTopLeft(viewer) + const Offset(40, 40),
            );
            await gesture.moveBy(const Offset(360, 80));
            await tester.pump(const Duration(milliseconds: 100));
            await gesture.up();
            await tester.pumpAndSettle();
          }
          expect(
            tester.getCenter(node).dx - fittedCenter.dx,
            greaterThan(1500),
          );
          final sceneCenter = transform.toScene(
            tester.getSize(viewer).center(Offset.zero),
          );
          tester.view.physicalSize = const Size(1000, 750);
          await tester.pumpAndSettle();
          final resizedCenter = transform.toScene(
            tester.getSize(viewer).center(Offset.zero),
          );
          expect((sceneCenter - resizedCenter).distance, lessThan(.001));
          await tester.tap(find.byTooltip('Fit graph'));
          await tester.pumpAndSettle();
          expect(node.hitTestable(), findsOneWidget);
        }
        await tester.tap(find.byTooltip('Graph options'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'Show tags'),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('graph-node-tag:study')),
          findsNothing,
        );
        expect(
          tester
              .widget<Semantics>(find.byKey(const ValueKey('graph-counts')))
              .properties
              .label,
          '3 files · 2 connections',
        );
        await tester.tap(find.byTooltip('Graph options'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'Show tags'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('graph-node-tag:study')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('graph-node-note:${pdf.id}')), findsNothing);
        await tester.tap(find.byKey(ValueKey('graph-node-note:${b.id}')));
        await tester.pumpAndSettle();
        expect(selected?.id, b.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

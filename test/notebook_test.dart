import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dart_pdf_editor/dart_pdf_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_document/pdf_document.dart' show PdfRect;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNotebookRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-test-');
    repository = LocalNotebookRepository(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test('all paper templates create valid multipage documents', () async {
    for (final paper in ['blank', 'lined', 'grid']) {
      final bytes = await createPaper(paper, pages: 3);
      validatePdf(bytes);
      expect(PdfDocument.open(bytes).pageCount, 3);
    }
  });
  test('save, reopen, rename and import preserve PDF and metadata', () async {
    final pdf = await createPaper('grid', pages: 2);
    var note = await repository.create('Übung – ÄÖÜ', pdf, paper: 'grid');
    note = await repository.save(note.copy(title: 'Neuer Title'), pdf);
    final reopened = LocalNotebookRepository(directory);
    expect((await reopened.list()).single.title, 'Neuer Title');
    expect(await reopened.load(note.id), pdf);
    final archive = await reopened.exportArchive(note);
    final imported = await reopened.importArchive(archive);
    expect(imported.id, isNot(note.id));
    expect(imported.paper, 'grid');
    expect(await reopened.load(imported.id), pdf);
    await reopened.delete(note.id);
    expect((await reopened.list()).single.id, imported.id);
  });
  test('concurrent saves are serialized and use byte snapshots', () async {
    final first = await createPaper('blank');
    final second = await createPaper('lined', pages: 2);
    final note = await repository.create('Note', first);
    final mutable = Uint8List.fromList(second);
    final saving = repository.save(note.copy(title: 'Zuerst'), mutable);
    mutable.fillRange(0, mutable.length, 0);
    await saving;
    expect(await repository.load(note.id), second);
    await Future.wait([
      repository.save(note.copy(title: 'Secondns'), first),
      repository.save(note.copy(title: 'Zuletzt'), second),
    ]);
    expect((await repository.list()).single.title, 'Zuletzt');
    expect(await repository.load(note.id), second);
  });
  test(
    'failed write leaves old document intact and queue remains usable',
    () async {
      final pdf = await createPaper('blank');
      final note = await repository.create('Gesichert', pdf);
      final obstacle = Directory('${directory.path}/${note.id}.noter.tmp');
      await obstacle.create();
      await expectLater(
        repository.save(note.copy(title: 'Not saved'), pdf),
        throwsA(isA<FileSystemException>()),
      );
      expect((await repository.list()).single.title, 'Gesichert');
      await obstacle.delete();
      await repository.save(note.copy(title: 'Restored'), pdf);
      expect((await repository.list()).single.title, 'Restored');
    },
  );
  test(
    'corruption and unsafe archive metadata are rejected without overwriting notes',
    () async {
      final pdf = await createPaper('blank');
      final note = await repository.create('Behalten', pdf);
      await File('${directory.path}/broken.noter').writeAsString('broken');
      expect((await repository.list()).single.id, note.id);
      expect(repository.readErrors, ['broken.noter']);
      expect(
        () => validatePdf(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      await expectLater(repository.load('../escape'), throwsFormatException);
      final manifest = Uint8List.fromList('{"version":99}'.codeUnits);
      final archive = Archive()
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
        ..addFile(ArchiveFile('document.pdf', pdf.length, pdf));
      await expectLater(
        repository.importArchive(
          Uint8List.fromList(ZipEncoder().encode(archive)),
        ),
        throwsFormatException,
      );
      expect((await repository.list()).single.title, 'Behalten');
    },
  );
  test(
    'ink and text edits survive archive round trip, undo and redo preserve original PDF text',
    () async {
      final source = pw.Document()
        ..addPage(
          pw.Page(build: (_) => pw.Text('Searchable original text 12345')),
        );
      final original = await source.save();
      final prefs = PdfEditingPreferences(store: PdfMemoryPreferencesStore());
      await prefs.ready;
      final editing = PdfEditingController(original, preferences: prefs);
      addTearDown(() {
        editing.dispose();
        prefs.dispose();
      });
      editing.addInkStroke(
        0,
        [(50, 50), (60, 70), (100, 100)],
        pressures: [0.2, 0.7, 1],
      );
      editing.finishInk();
      final ink = Uint8List.fromList(editing.bytes);
      expect(editing.canUndo, isTrue);
      editing.undo();
      expect(editing.bytes, original);
      editing.redo();
      expect(editing.bytes, ink);
      // PDF revisions append to the exact original bytes, retaining its text objects.
      expect(editing.bytes.sublist(0, original.length), original);
      editing.tool = PdfEditTool.highlight;
      editing.addInkStroke(0, [(40, 200), (200, 200)]);
      editing.finishInk();
      editing.addFreeText(0, const PdfRect(40, 300, 250, 350), 'Getippte Note');
      expect(editing.document.page(0).annotations.length, 3);
      final edited = Uint8List.fromList(editing.bytes);
      final note = await repository.create('Mit Handschrift', edited);
      final restored = await repository.importArchive(
        await repository.exportArchive(note),
      );
      final output = await repository.load(restored.id);
      expect(output, edited);
      expect(PdfDocument.open(output).page(0).annotations.length, 3);
      final file = File('${directory.path}/export.pdf');
      await file.writeAsBytes(output);
      if (File('/usr/bin/pdftotext').existsSync()) {
        final result = await Process.run('pdftotext', [file.path, '-']);
        expect(result.exitCode, 0);
        expect(result.stdout, contains('Searchable original text 12345'));
      }
    },
  );
}

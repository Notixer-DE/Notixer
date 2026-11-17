import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:noter/data/notebook.dart';
import 'package:noter/data/paper.dart';
import 'package:noter/ui/notebook_preview.dart';
import 'package:pdf_document/pdf_document.dart';

class _Repository extends LocalNotebookRepository {
  _Repository(super.directory);
  int loads = 0, concurrent = 0, maximum = 0;
  bool fail = false;
  @override
  Future<Uint8List> load(String id) async {
    loads++;
    concurrent++;
    if (concurrent > maximum) maximum = concurrent;
    try {
      if (fail) throw const FormatException('unreadable preview');
      return await super.load(id);
    } finally {
      concurrent--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Repository repository;
  late Notebook note;
  late NotebookPreviewCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('noter-preview-');
    repository = _Repository(directory);
    final document = PdfDocument.open(await createPaper('lined'));
    final editor = PdfEditor(document)
      ..appendPagesFrom(PdfDocument.open(await createPaper('grid')));
    note = await repository.create('Note', editor.save());
    cache = NotebookPreviewCache(repository);
  });
  tearDown(() async {
    cache.dispose();
    await directory.delete(recursive: true);
  });

  test('extracts and caches only the first page of a document', () async {
    final first = await cache.load(note, () => true);
    expect(first, isNotNull);
    expect(first!.pageCount, 1);
    expect(await cache.load(note, () => true), same(first));
    expect(repository.loads, 1);
    await cache.load(
      note.copy(modified: note.modified.add(const Duration(seconds: 1))),
      () => true,
    );
    expect(repository.loads, 2);
  });

  test('serializes work and evicts older cached documents', () async {
    final requests = [
      for (var i = 0; i < 10; i++)
        cache.load(
          note.copy(modified: note.modified.add(Duration(seconds: i))),
          () => true,
        ),
    ];
    expect(await Future.wait(requests), everyElement(isNotNull));
    expect(repository.maximum, 1);
    expect(repository.loads, 10);
    await cache.load(note, () => true);
    expect(repository.loads, 11);
  });

  test('a new visible card can reuse a request from a disposed card', () async {
    final old = cache.load(note, () => false);
    final current = cache.load(note, () => true);
    expect(current, same(old));
    expect(await current, isNotNull);
    expect(repository.loads, 1);
  });

  test(
    'skips offscreen or disposed work and tolerates unreadable PDFs',
    () async {
      expect(await cache.load(note, () => false), isNull);
      expect(repository.loads, 0);
      repository.fail = true;
      expect(await cache.load(note, () => true), isNull);
      expect(repository.loads, 1);
      cache.dispose();
      expect(await cache.load(note, () => true), isNull);
      expect(repository.loads, 1);
    },
  );
}

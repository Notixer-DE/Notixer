import 'package:flutter/material.dart';

import '../data/keyboard_shortcuts.dart';
import '../data/notebook.dart';
import '../data/pdf_search.dart';
import 'editor.dart';

class PdfSearchPage extends StatefulWidget {
  const PdfSearchPage({
    super.key,
    required this.notes,
    required this.repository,
    this.shortcuts,
  });
  final List<Notebook> notes;
  final NotebookRepository repository;
  final KeyboardShortcuts? shortcuts;

  @override
  State<PdfSearchPage> createState() => _PdfSearchPageState();
}

class _PdfSearchPageState extends State<PdfSearchPage> {
  late List<Notebook> _notes = widget.notes.where((n) => n.isPdf).toList();
  final _query = TextEditingController();
  final _selected = <String>{};
  final _hits = <(Notebook, PdfSearchHit)>[];
  final _messages = <String>[];
  bool _choosing = true, _searching = false;
  bool _cancelled = false;
  int _generation = 0, _completed = 0;
  String _searchedQuery = '';
  String? _openError;

  Future<void> _reload() async {
    final notes = (await widget.repository.list())
        .where((n) => n.isPdf)
        .toList();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _selected.removeWhere((id) => !notes.any((note) => note.id == id));
    });
  }

  void _cancel() => setState(() {
    _generation++;
    _searching = false;
    _cancelled = true;
  });

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty || _selected.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    final selected = Set<String>.of(_selected);
    final titles = {for (final note in _notes) note.id: note.title};
    setState(() {
      _choosing = false;
      _searching = true;
      _cancelled = false;
      _completed = 0;
      _searchedQuery = query;
      _hits.clear();
      _messages.clear();
      _openError = null;
    });
    try {
      await _reload();
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _searching = false;
          _openError = 'Could not refresh the note list: $e';
        });
      }
      return;
    }
    if (!mounted || generation != _generation) return;
    final missing = selected.difference(_notes.map((n) => n.id).toSet());
    if (missing.isNotEmpty) {
      setState(() {
        for (final id in missing) {
          _messages.add(
            '„${titles[id] ?? id}“: Search failed. The note is no longer available.',
          );
        }
      });
    }
    final notes = _notes.where((n) => _selected.contains(n.id)).toList();
    for (final note in notes) {
      try {
        final bytes = await widget.repository.load(note.id);
        if (!mounted || generation != _generation) return;
        final result = await searchPdf(bytes, query);
        if (!mounted || generation != _generation) return;
        setState(() {
          _hits.addAll(result.hits.map((hit) => (note, hit)));
          if (result.truncated) {
            _messages.add(
              '„${note.title}“: Only the first 500 matches are shown.',
            );
          }
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(
          () => _messages.add(
            '„${note.title}“: Search failed. The file cannot be read.',
          ),
        );
      }
      if (!mounted || generation != _generation) return;
      setState(() => _completed++);
    }
    if (mounted && generation == _generation) {
      setState(() => _searching = false);
    }
  }

  Future<void> _open(Notebook note, PdfSearchHit hit) async {
    try {
      final current = (await widget.repository.list()).where(
        (n) => n.id == note.id,
      );
      if (current.isEmpty) throw StateError('The note was deleted.');
      note = current.single;
      final bytes = await widget.repository.load(note.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditorPage(
            note: note,
            bytes: bytes,
            repository: widget.repository,
            shortcuts: widget.shortcuts,
            initialPage: hit.pageIndex,
            initialQuery: _searchedQuery,
          ),
        ),
      );
      await _reload();
    } catch (e) {
      if (mounted) setState(() => _openError = 'Could not open: $e');
    }
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_searching,
    child: Scaffold(
      appBar: AppBar(title: const Text('Search PDFs')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Searches PDF text, excluding scans and handwriting. '
                    'This selection is independent of the library filters.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      labelText: 'Search for a word or text',
                      prefixIcon: Icon(Icons.search),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _search(),
                  ),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            _searching ||
                                _selected.isEmpty ||
                                _query.text.trim().isEmpty
                            ? null
                            : _search,
                        icon: const Icon(Icons.search),
                        label: Text(
                          'Search ${_selected.length} ${_selected.length == 1 ? 'document' : 'documents'}',
                        ),
                      ),
                      if (_searching)
                        TextButton(
                          onPressed: _cancel,
                          child: const Text('Cancel search'),
                        )
                      else if (!_choosing)
                        TextButton(
                          onPressed: () => setState(() => _choosing = true),
                          child: const Text('Change selection'),
                        ),
                      if (_choosing)
                        TextButton(
                          onPressed: () => setState(() {
                            if (_selected.length == _notes.length) {
                              _selected.clear();
                            } else {
                              _selected.addAll(_notes.map((n) => n.id));
                            }
                          }),
                          child: Text(
                            _selected.length == _notes.length
                                ? 'Clear selection'
                                : 'Select all',
                          ),
                        ),
                    ],
                  ),
                  if (!_choosing)
                    Text(
                      '${_hits.length} matches for „$_searchedQuery“ · '
                      '$_completed/${_selected.length} ${_selected.length == 1 ? 'document' : 'documents'} searched',
                    ),
                  if (_searching) const LinearProgressIndicator(),
                  if (_cancelled) const Text('Search cancelled.'),
                  if (_openError != null) Text(_openError!),
                ],
              ),
            ),
            Expanded(
              child: _choosing
                  ? ListView.builder(
                      itemCount: _notes.length,
                      itemBuilder: (context, index) {
                        final note = _notes[index];
                        return CheckboxListTile(
                          title: Text(note.title),
                          value: _selected.contains(note.id),
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              _selected.add(note.id);
                            } else {
                              _selected.remove(note.id);
                            }
                          }),
                        );
                      },
                    )
                  : ListView.builder(
                      itemCount:
                          _messages.length +
                          _hits.length +
                          (!_searching && !_cancelled && _hits.isEmpty ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index < _messages.length) {
                          return ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: Text(_messages[index]),
                          );
                        }
                        final hitIndex = index - _messages.length;
                        if (hitIndex >= _hits.length) {
                          return const ListTile(
                            title: Text('No matches found.'),
                          );
                        }
                        final (note, hit) = _hits[hitIndex];
                        return ListTile(
                          leading: const Icon(Icons.picture_as_pdf_outlined),
                          title: Text(
                            '${note.title} · Page ${hit.pageIndex + 1}',
                          ),
                          subtitle: Text(hit.snippet),
                          onTap: _searching ? null : () => _open(note, hit),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

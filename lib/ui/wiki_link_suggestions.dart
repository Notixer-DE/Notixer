import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/markdown_document.dart';
import '../data/markdown_library.dart';
import '../data/notebook.dart';

Future<List<MarkdownHeading>> _headings(String source) =>
    Isolate.run(() => markdownHeadingTargets(source));

Future<bool> _allowsCompletion(String source, int start, int end) =>
    Isolate.run(() {
      var marker = 'noter-completion:target';
      while (source.contains(marker)) {
        marker += 'x';
      }
      final marked = source.replaceRange(start, end, '[candidate](<$marker>)');
      return markdownLinks(marked).any((link) => link.href == marker);
    });

class WikiLinkSuggestions extends StatefulWidget {
  const WikiLinkSuggestions({
    super.key,
    required this.controller,
    required this.note,
    required this.notes,
    required this.repository,
  });
  final TextEditingController controller;
  final Notebook note;
  final List<Notebook> notes;
  final NotebookRepository repository;
  @override
  State<WikiLinkSuggestions> createState() => WikiLinkSuggestionsState();
}

class WikiLinkSuggestionsState extends State<WikiLinkSuggestions> {
  Timer? _debounce;
  int _generation = 0, _selected = 0, _start = 0, _end = 0;
  String? _active, _error;
  List<({String label, String href, String detail})> _options = [];
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(WikiLinkSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id ||
        oldWidget.notes != widget.notes) {
      _active = null;
      _changed();
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final value = widget.controller.value;
    if (!value.selection.isValid || !value.selection.isCollapsed) {
      _hide();
      return;
    }
    final end = value.selection.extentOffset;
    final start = value.text.lastIndexOf('[[', end);
    if (start < 0 ||
        start + 2 > end ||
        value.text.substring(start + 2, end).contains(RegExp(r'[\]\n]'))) {
      _hide();
      return;
    }
    final query = value.text.substring(start + 2, end);
    final unchanged = _active == query && _start == start && _end == end;
    _start = start;
    _end = end;
    if (unchanged) return;
    if (mounted) {
      setState(() {
        _options = [];
        _error = null;
        _selected = 0;
      });
    }
    _active = query;
    _debounce?.cancel();
    final generation = ++_generation;
    _debounce = Timer(
      const Duration(milliseconds: 160),
      () => _find(query, generation),
    );
  }

  void _hide() {
    _debounce?.cancel();
    _active = null;
    _generation++;
    if ((_options.isNotEmpty || _error != null) && mounted) {
      setState(() {
        _options = [];
        _error = null;
      });
    }
  }

  Future<void> _find(String query, int generation) async {
    final options = <({String label, String href, String detail})>[];
    try {
      final allowed = await _allowsCompletion(
        widget.controller.text,
        _start,
        _end,
      );
      if (!mounted || generation != _generation) return;
      if (!allowed) {
        setState(() {
          _options = [];
          _error = null;
        });
        return;
      }
      final separator = query.indexOf('#');
      if (separator >= 0) {
        final title = query.substring(0, separator).trim().toLowerCase();
        final needle = query.substring(separator + 1).toLowerCase();
        final notes = title.isEmpty
            ? [widget.note]
            : widget.notes
                  .where(
                    (note) =>
                        note.isMarkdown && note.title.toLowerCase() == title,
                  )
                  .toList();
        for (final note in notes) {
          final source = note.id == widget.note.id
              ? widget.controller.text
              : (await decodeMarkdownAsync(
                  await widget.repository.load(note.id),
                )).source;
          for (final heading in await _headings(source)) {
            if (!heading.title.toLowerCase().contains(needle)) continue;
            options.add((
              label: heading.title,
              href: Uri.parse(
                note.id == widget.note.id
                    ? ''
                    : MarkdownLibrary.linkTo(widget.note, note),
              ).replace(fragment: heading.slug).toString(),
              detail: '${note.title} · H${heading.level} · #${heading.slug}',
            ));
            if (options.length >= 8) break;
          }
          if (options.length >= 8) break;
        }
      } else {
        for (final note
            in widget.notes
                .where(
                  (note) =>
                      note.title.toLowerCase().contains(query.toLowerCase()),
                )
                .take(8)) {
          options.add((
            label: note.title,
            href: MarkdownLibrary.linkTo(widget.note, note),
            detail: note.documentPath,
          ));
        }
      }
      if (mounted && generation == _generation) {
        setState(() {
          _options = options;
          _selected = 0;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _options = [];
          _error = 'Could not load link suggestions: $error';
        });
      }
    }
  }

  bool handleKey(KeyEvent event) {
    if (_options.isEmpty || event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _hide();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _selected =
            (_selected + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
            _options.length,
      );
      return true;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _insert(_selected);
      return true;
    }
    return false;
  }

  void _insert(int index, {int? generation}) {
    if (!mounted ||
        (generation != null && generation != _generation) ||
        index < 0 ||
        index >= _options.length) {
      return;
    }
    final value = widget.controller.value;
    final text = value.text;
    if (_active == null ||
        !value.selection.isCollapsed ||
        value.selection.extentOffset != _end ||
        _start < 0 ||
        _end > text.length ||
        text.substring(_start, _end) != '[[$_active') {
      _hide();
      return;
    }
    final option = _options[index];
    final end = text.substring(_end).startsWith(']]') ? _end + 2 : _end;
    final replacement = '[${markdownLabel(option.label)}](<${option.href}>)';
    _active = null;
    widget.controller.value = TextEditingValue(
      text: text.replaceRange(_start, end, replacement),
      selection: TextSelection.collapsed(offset: _start + replacement.length),
    );
    _hide();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!, maxLines: 2);
    if (_options.isEmpty) return const SizedBox.shrink();
    final generation = _generation;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 190),
      child: Material(
        elevation: 2,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _options.length,
          itemBuilder: (context, index) => ListTile(
            dense: true,
            selected: index == _selected,
            title: Text(
              _options[index].label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _options[index].detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _insert(index, generation: generation),
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'dart:isolate';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../data/markdown_document.dart';
import '../data/keyboard_shortcuts.dart';
import 'markdown_style.dart';

class _PreviewBlock {
  _PreviewBlock(this.node, this.key, this.offsets, this.headings, this.edit);
  final md.Node node;
  final String key;
  final List<int> offsets;
  final List<String> headings;
  final _BlockEdit? edit;
}

typedef _BlockEdit = ({
  MarkdownPreviewRange range,
  String label,
  String prefix,
  String previewPrefix,
});

Object _nodeKey(md.Node node) => node is md.Element
    ? [
        node.tag,
        node.attributes,
        [for (final child in node.children ?? <md.Node>[]) _nodeKey(child)],
      ]
    : (node as md.Text).text;

int _taskCount(md.Node node) => node is md.Element
    ? (node.tag == 'li' && node.attributes['class'] == 'task-list-item'
              ? 1
              : 0) +
          (node.children ?? <md.Node>[]).fold<int>(
            0,
            (sum, child) => sum + _taskCount(child),
          )
    : 0;

List<_PreviewBlock> _parsePreview(String source, bool editable) {
  final nodes = <md.Node>[];
  final ranges = editable ? <md.Node, MarkdownPreviewRange>{} : null;
  for (final node in parseMarkdownForPreview(source, editableRanges: ranges)) {
    if (node is md.Element && (node.tag == 'ul' || node.tag == 'ol')) {
      var index = int.tryParse(node.attributes['start'] ?? '') ?? 1;
      for (final item in node.children!) {
        nodes.add(
          md.Element(node.tag, [item])
            ..attributes.addAll(node.attributes)
            ..attributes['start'] = '${index++}',
        );
      }
    } else {
      nodes.add(node);
    }
  }
  final offsets = markdownTaskOffsets(source, renderingOrder: true);
  var checkbox = 0, heading = 0;
  final headings = markdownHeadingsFromNodes(nodes);
  final occurrences = <String, int>{};
  return [
    for (final node in nodes)
      (() {
        final count = _taskCount(node);
        final tasks = offsets.sublist(checkbox, checkbox + count);
        checkbox += count;
        final fingerprint = jsonEncode(_nodeKey(node));
        final occurrence = occurrences.update(
          fingerprint,
          (value) => value + 1,
          ifAbsent: () => 0,
        );
        final headingCount = markdownHeadingsFromNodes([node]).length;
        final slugs = headings.sublist(heading, heading + headingCount);
        heading += headingCount;
        final range = ranges?[node];
        final edit = range != null
            ? (
                range: range,
                label: slugs.isEmpty ? 'Paragraph' : 'Heading',
                prefix: '',
                previewPrefix: slugs.isNotEmpty && node is md.Element
                    ? '${'#' * int.parse(node.tag.substring(1))} '
                    : '',
              )
            : (editable && tasks.isNotEmpty
                  ? _taskEdit(source, node, tasks.first)
                  : null);
        return _PreviewBlock(
          node,
          '$fingerprint:$occurrence',
          tasks,
          slugs,
          edit,
        );
      })(),
  ];
}

_BlockEdit? _taskEdit(String source, md.Node node, int checkbox) {
  if (node is! md.Element || (node.tag != 'ul' && node.tag != 'ol')) {
    return null;
  }
  final item = node.children!.single;
  if (item is! md.Element || item.attributes['class'] != 'task-list-item') {
    return null;
  }
  final labelStart = checkbox + 2;
  final newline = source.indexOf(RegExp(r'\r|\n'), labelStart);
  final end = newline < 0 ? source.length : newline;
  var start = labelStart;
  while (start < end && (source[start] == ' ' || source[start] == '\t')) {
    start++;
  }
  return (
    range: (start: start, end: end, singleLine: true),
    label: 'Checklist item',
    prefix: start == labelStart ? ' ' : '',
    previewPrefix: '- [${source[checkbox]}] ',
  );
}

Future<List<_PreviewBlock>> _parseOffThread(String source, bool editable) =>
    Isolate.run(
      () => _parsePreview(source, editable),
      debugName: 'noter:markdown-preview',
    );

/// Parse large documents off the UI isolate; build and retain only nearby
/// Markdown blocks. Scrolling and save-status updates never parse the source.
class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    super.key,
    required this.document,
    this.zoom = 1,
    required this.scrollController,
    required this.onToggle,
    required this.onFollow,
    this.onEdit,
    this.shortcuts,
  });
  final MarkdownDocument document;
  final double zoom;
  final ScrollController scrollController;
  final void Function(int offset, bool checked) onToggle;
  final void Function(String href) onFollow;
  final void Function(int start, int end, String text)? onEdit;
  final KeyboardShortcuts? shortcuts;
  @override
  State<MarkdownPreview> createState() => MarkdownPreviewState();
}

class MarkdownPreviewState extends State<MarkdownPreview> {
  final _anchors = <String, GlobalKey>{};
  final _widgets = <String, Widget>{};
  List<_PreviewBlock>? _blocks;
  SliverChildBuilderDelegate? _delegate;
  Future<void> _ready = Future.value();
  Future<void> get ready => _ready;
  int _generation = 0, _navigation = 0;
  String? _pendingSource, _error;
  final _draft = TextEditingController();
  final _appendKey = GlobalKey();
  ({String? key, _BlockEdit edit})? _editing;
  int debugParses = 0, debugBlockBuilds = 0;
  int get debugCachedBlocks => _widgets.length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final assetsChanged = !mapEquals(
      oldWidget.document.assets,
      widget.document.assets,
    );
    final zoomChanged = oldWidget.zoom != widget.zoom;
    if (assetsChanged || zoomChanged) _widgets.clear();
    if (oldWidget.document.source != widget.document.source ||
        (oldWidget.onEdit == null) != (widget.onEdit == null)) {
      _editing = null;
      _navigation++;
      _load();
    } else if (assetsChanged || zoomChanged) {
      _makeDelegate();
    }
  }

  void _load() {
    final source = widget.document.source;
    final generation = ++_generation;
    final editable = widget.onEdit != null;
    _pendingSource = source;
    _error = null;
    debugParses++;
    if (source.length < 16384) {
      _install(_parsePreview(source, editable));
      _ready = Future.value();
    } else {
      _ready = _parseOffThread(source, editable)
          .then((blocks) {
            if (mounted && generation == _generation) {
              setState(() => _install(blocks));
            }
          })
          .catchError((Object error) {
            if (mounted && generation == _generation) {
              setState(() {
                _pendingSource = null;
                _error = 'Could not load the preview: $error';
              });
            }
          });
    }
  }

  void _install(List<_PreviewBlock> blocks) {
    final used = {for (final block in blocks) ...block.headings};
    for (final slug in used) {
      _anchors.putIfAbsent(slug, GlobalKey.new);
    }
    _anchors.removeWhere((slug, _) => !used.contains(slug));
    _blocks = blocks;
    _pendingSource = null;
    _makeDelegate();
  }

  void _makeDelegate() {
    final blocks = _blocks;
    if (blocks == null) return;
    final indices = {for (var i = 0; i < blocks.length; i++) blocks[i].key: i};
    _delegate = SliverChildBuilderDelegate(
      (context, index) {
        if (index == blocks.length) {
          return KeyedSubtree(key: _appendKey, child: _appendControls());
        }
        final block = blocks[index];
        final compactTaskSpacing =
            block.offsets.isNotEmpty &&
            index + 1 < blocks.length &&
            blocks[index + 1].offsets.isNotEmpty;
        final cacheKey =
            '${block.key}:${block.offsets}:${block.headings}:$compactTaskSpacing:${[for (final slug in block.headings) identityHashCode(_anchors[slug])]}';
        final cached = _widgets.remove(cacheKey);
        final child =
            cached ??
            _MarkdownBlock(
              key: ValueKey(block.key),
              node: block.node,
              zoom: widget.zoom,
              offsets: block.offsets,
              compactTaskSpacing: compactTaskSpacing,
              headingKeys: [for (final slug in block.headings) _anchors[slug]!],
              assets: widget.document.assets,
              onToggle: (offset, checked) {
                if (_pendingSource == null && _editing == null) {
                  widget.onToggle(offset, checked);
                }
              },
              onFollow: (href) => widget.onFollow(href),
            );
        if (cached == null) debugBlockBuilds++;
        _widgets[cacheKey] = child;
        while (_widgets.length > 256) {
          _widgets.remove(_widgets.keys.first);
        }
        final edit = block.edit;
        if (edit == null || widget.onEdit == null || _pendingSource != null) {
          return child;
        }
        return KeyedSubtree(
          key: ValueKey(block.key),
          child: block.key == _editing?.key
              ? _blockEditor(edit)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: child),
                    IconButton(
                      tooltip: 'Edit ${edit.label.toLowerCase()} in preview',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: _editing != null
                          ? null
                          : () => _startEdit(block.key, edit),
                    ),
                  ],
                ),
        );
      },
      childCount: blocks.length + (widget.onEdit == null ? 0 : 1),
      addAutomaticKeepAlives: false,
      findChildIndexCallback: (key) => key == _appendKey
          ? blocks.length
          : key is ValueKey<String>
          ? indices[key.value]
          : null,
    );
  }

  void _startEdit(String? key, _BlockEdit edit) {
    final range = edit.range;
    final text = widget.document.source.substring(range.start, range.end);
    _draft.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _editing = (key: key, edit: edit);
      _makeDelegate();
    });
  }

  Widget _appendControls() {
    if (_editing case (key: null, :final edit)) return _blockEditor(edit);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _editing == null && _pendingSource == null
              ? () => _append(task: false)
              : null,
          icon: const Icon(Icons.add),
          label: const Text('Continue writing'),
        ),
        OutlinedButton.icon(
          onPressed: _editing == null && _pendingSource == null
              ? () => _append(task: true)
              : null,
          icon: const Icon(Icons.checklist),
          label: const Text('Add checklist item'),
        ),
      ],
    );
  }

  void _append({required bool task}) {
    final source = widget.document.source;
    final newline = source.contains('\r\n') ? '\r\n' : '\n';
    final joinsList =
        task && _blocks!.lastOrNull?.edit?.label == 'Checklist item';
    final separator =
        source.trim().isEmpty || source.endsWith('$newline$newline')
        ? ''
        : source.endsWith(newline)
        ? (joinsList ? '' : newline)
        : (joinsList ? newline : '$newline$newline');
    _startEdit(null, (
      range: (start: source.length, end: source.length, singleLine: task),
      label: task ? 'Checklist item' : 'Paragraph',
      prefix: '$separator${task ? '- [ ] ' : ''}',
      previewPrefix: task ? '- [ ] ' : '',
    ));
  }

  Future<void> startWriting() async {
    await ready;
    if (!mounted || widget.onEdit == null || _blocks == null) return;
    if (_editing?.key != null) {
      finishEditing();
      await WidgetsBinding.instance.endOfFrame;
      await ready;
    }
    final scroll = widget.scrollController;
    if (!mounted || widget.onEdit == null || !scroll.hasClients) return;
    if (_editing == null) _append(task: false);
    await WidgetsBinding.instance.endOfFrame;
    while (mounted && _editing != null && scroll.hasClients) {
      final target = _appendKey.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(target);
        return;
      }
      final position = scroll.position;
      if (position.pixels >= position.maxScrollExtent) return;
      scroll.jumpTo(position.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void finishEditing({bool apply = true}) {
    final edit = _editing?.edit;
    if (edit == null) return;
    setState(() {
      _editing = null;
      _makeDelegate();
    });
    final range = edit.range;
    final text = _draft.text;
    if (apply &&
        text != widget.document.source.substring(range.start, range.end)) {
      widget.onEdit?.call(
        range.start,
        range.end,
        text.isEmpty ? '' : '${edit.prefix}$text',
      );
    }
  }

  Widget _blockEditor(_BlockEdit edit) => CallbackShortcuts(
    bindings: {
      if (widget.shortcuts == null) ...{
        AppShortcut.markdownApplyDraft.defaultBinding: finishEditing,
        const SingleActivator(
          LogicalKeyboardKey.enter,
          shift: true,
          meta: true,
        ): finishEditing,
      },
    },
    child: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('markdown-preview-edit'),
            autofocus: true,
            controller: _draft,
            minLines: edit.range.singleLine ? 1 : 2,
            maxLines: edit.range.singleLine ? 1 : 8,
            decoration: InputDecoration(
              labelText: edit.label,
              hintText: edit.range.singleLine
                  ? null
                  : '# Heading, **bold**, - list',
            ),
            onSubmitted: edit.range.singleLine ? (_) => finishEditing() : null,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => finishEditing(apply: false),
                  child: const Text('Cancel'),
                ),
                Tooltip(
                  message:
                      widget.shortcuts?.tooltip(
                        'Apply',
                        AppShortcut.markdownApplyDraft,
                      ) ??
                      'Apply (${AppShortcut.markdownApplyDraft.defaultBinding.label})',
                  child: FilledButton(
                    onPressed: finishEditing,
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _draft,
            builder: (context, draft, _) {
              if (draft.text.trim().isEmpty) return const SizedBox.shrink();
              final source = '${edit.previewPrefix}${draft.text}';
              final nodes = parseMarkdownForPreview(source);
              return IgnorePointer(
                child: Column(
                  key: const ValueKey('markdown-draft-preview'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Divider(),
                    for (final node in nodes)
                      _MarkdownBlock(
                        node: node,
                        zoom: widget.zoom,
                        offsets: const [],
                        compactTaskSpacing: false,
                        headingKeys: [
                          for (final _ in markdownHeadingsFromNodes([node]))
                            GlobalKey(),
                        ],
                        assets: widget.document.assets,
                        onToggle: (_, _) {},
                        onFollow: (_) {},
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    ),
  );

  Future<bool> scrollToHeading(String slug) async {
    await ready;
    if (!mounted) return false;
    final key = _anchors[slug];
    if (key == null) return false;
    final navigation = ++_navigation;
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return false;
    if (key.currentContext == null) {
      scroll.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
    }
    while (mounted && navigation == _navigation && scroll.hasClients) {
      final target = key.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 200),
        );
        return true;
      }
      final position = scroll.position;
      final next = (position.pixels + position.viewportDimension * .8).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if (next <= position.pixels) return false;
      scroll.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => _error != null
      ? SliverToBoxAdapter(child: Text(_error!))
      : _delegate == null
      ? const SliverToBoxAdapter(child: LinearProgressIndicator())
      : SliverList(delegate: _delegate!);

  @override
  void dispose() {
    _generation++;
    _navigation++;
    _draft.dispose();
    _widgets.clear();
    super.dispose();
  }
}

class _MarkdownBlock extends StatefulWidget {
  const _MarkdownBlock({
    super.key,
    required this.node,
    required this.zoom,
    required this.offsets,
    required this.compactTaskSpacing,
    required this.headingKeys,
    required this.assets,
    required this.onToggle,
    required this.onFollow,
  });
  final md.Node node;
  final double zoom;
  final List<int> offsets;
  final bool compactTaskSpacing;
  final List<GlobalKey> headingKeys;
  final Map<String, Uint8List> assets;
  final void Function(int, bool) onToggle;
  final void Function(String) onFollow;
  @override
  State<_MarkdownBlock> createState() => _MarkdownBlockState();
}

class _MarkdownBlockState extends State<_MarkdownBlock>
    implements MarkdownBuilderDelegate {
  final _recognizers = <GestureRecognizer>[];
  List<Widget> _children = [];
  void _release() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _build();
  }

  @override
  void didUpdateWidget(_MarkdownBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _build();
  }

  void _build() {
    _release();
    var checkbox = 0, heading = 0;
    final style = noterMarkdownStyle(context, zoom: widget.zoom);
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: true,
      styleSheet: style,
      imageDirectory: null,
      imageBuilder: (uri, title, alt) {
        final bytes = widget.assets[markdownAssetPath(uri)];
        if (bytes == null) {
          return Text(
            'Image unavailable: ${alt ?? uri}. External images are not loaded automatically.',
          );
        }
        return Image.memory(
          bytes,
          cacheWidth: 1400,
          errorBuilder: (_, _, _) => const Text('Could not display the image.'),
        );
      },
      checkboxBuilder: (checked) {
        final index = checkbox++;
        // A Checkbox has no text baseline: the Row otherwise uses the bottom
        // of its touch target. Align its centre with the first text line.
        final metrics = TextPainter(
          text: TextSpan(
            text: 'x',
            style: DefaultTextStyle.of(context).style.merge(style.p),
          ),
          textDirection: Directionality.of(context),
          textScaler: style.textScaler ?? MediaQuery.textScalerOf(context),
          strutStyle: StrutStyle(
            fontFamily: style.p?.fontFamily,
            fontSize: style.p?.fontSize,
            height: style.p?.height,
            leading: 0,
            forceStrutHeight: true,
          ),
        )..layout();
        final baseline =
            22 +
            metrics.computeDistanceToActualBaseline(TextBaseline.alphabetic) -
            metrics.height / 2;
        metrics.dispose();
        return _CheckboxBaseline(
          baseline: baseline,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Checkbox(
              value: checked,
              onChanged: index >= widget.offsets.length
                  ? null
                  : (value) => widget.onToggle(widget.offsets[index], value!),
            ),
          ),
        );
      },
      bulletBuilder: null,
      builders: {
        for (var level = 1; level <= 6; level++)
          'h$level': _HeadingBuilder(() => widget.headingKeys[heading++]),
      },
      paddingBuilders: const {},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    );
    _children = builder.build([widget.node]);
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        if (href != null) widget.onFollow(href);
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
    style: styleSheet.code,
    text: code.replaceAll(RegExp(r'\n$'), ''),
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      bottom: widget.compactTaskSpacing
          ? 2
          : noterMarkdownStyle(context).blockSpacing!,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _children,
    ),
  );
  @override
  void dispose() {
    _release();
    super.dispose();
  }
}

class _HeadingBuilder extends MarkdownElementBuilder {
  _HeadingBuilder(this.keyFor);
  final GlobalKey Function() keyFor;
  @override
  bool isBlockElement() => true;
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Padding(
    key: keyFor(),
    padding: const EdgeInsets.only(top: 12, bottom: 8),
    child: Text(element.textContent, style: preferredStyle),
  );
}

// Advertise a text baseline without moving or shrinking the 44px hit target.
class _CheckboxBaseline extends SingleChildRenderObjectWidget {
  const _CheckboxBaseline({required this.baseline, required super.child});
  final double baseline;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCheckboxBaseline(baseline);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCheckboxBaseline renderObject,
  ) {
    renderObject.baseline = baseline;
  }
}

class _RenderCheckboxBaseline extends RenderProxyBox {
  _RenderCheckboxBaseline(this._baseline);
  double _baseline;
  set baseline(double value) {
    if (_baseline == value) return;
    _baseline = value;
    markNeedsLayout();
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => _baseline;
}

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show compute, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'dart:typed_data';

import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../data/markdown_document.dart';
import 'markdown_style.dart';
import 'noter_theme.dart';

class _PreviewBlock {
  _PreviewBlock(this.node, this.key, this.offsets, this.headings);
  final md.Node node;
  final String key;
  final List<int> offsets;
  final List<String> headings;
}

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

List<_PreviewBlock> _parsePreview(String source) {
  final nodes = <md.Node>[];
  for (final node in parseMarkdownForPreview(source)) {
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
  final counts = nodes.map(_taskCount).toList();
  // A parser mismatch must never make a checkbox edit a different task.
  final mapped =
      counts.fold(0, (sum, count) => sum + count) == offsets.length &&
      offsets.toSet().length == offsets.length;
  var checkbox = 0, heading = 0;
  final headings = markdownHeadingsFromNodes(nodes);
  final occurrences = <String, int>{};
  return [
    for (var index = 0; index < nodes.length; index++)
      (() {
        final node = nodes[index];
        final count = counts[index];
        final tasks = mapped
            ? offsets.sublist(checkbox, checkbox + count)
            : <int>[];
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
        return _PreviewBlock(node, '$fingerprint:$occurrence', tasks, slugs);
      })(),
  ];
}

Future<List<_PreviewBlock>> _parseOffThread(String source) =>
    compute(_parsePreview, source, debugLabel: 'noter:markdown-preview');

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
    this.onCopyTask,
  });
  final MarkdownDocument document;
  final double zoom;
  final ScrollController scrollController;
  final void Function(int offset, bool checked) onToggle;
  final void Function(String href) onFollow;
  final void Function(int offset)? onCopyTask;
  @override
  State<MarkdownPreview> createState() => MarkdownPreviewState();
}

class MarkdownPreviewState extends State<MarkdownPreview> {
  final _anchors = <String, GlobalKey>{};
  final _sourceLineKey = GlobalKey();
  String? _sourceLineBlock;
  final _widgets = <String, Widget>{};
  List<_PreviewBlock>? _blocks;
  SliverChildBuilderDelegate? _delegate;
  Future<void> _ready = Future.value();
  Future<void> get ready => _ready;
  int _generation = 0, _navigation = 0;
  String? _pendingSource, _error;
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
    final copyChanged =
        (oldWidget.onCopyTask == null) != (widget.onCopyTask == null);
    if (assetsChanged || zoomChanged || copyChanged) _widgets.clear();
    if (oldWidget.document.source != widget.document.source) {
      _navigation++;
      _load();
    } else if (assetsChanged || zoomChanged || copyChanged) {
      _makeDelegate();
    }
  }

  void _load() {
    final source = widget.document.source;
    final generation = ++_generation;
    _pendingSource = source;
    _error = null;
    debugParses++;
    if (source.length < 16384) {
      _install(_parsePreview(source));
      _ready = Future.value();
    } else {
      _ready = _parseOffThread(source)
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
                if (_pendingSource == null) {
                  widget.onToggle(offset, checked);
                }
              },
              onFollow: (href) => widget.onFollow(href),
              onCopyTask: widget.onCopyTask == null
                  ? null
                  : (offset) {
                      if (_pendingSource == null) {
                        widget.onCopyTask!(offset);
                      }
                    },
            );
        if (cached == null) debugBlockBuilds++;
        _widgets[cacheKey] = child;
        while (_widgets.length > 256) {
          _widgets.remove(_widgets.keys.first);
        }
        return block.key == _sourceLineBlock
            ? KeyedSubtree(
                key: ValueKey(block.key),
                child: KeyedSubtree(key: _sourceLineKey, child: child),
              )
            : child;
      },
      childCount: blocks.length,
      addAutomaticKeepAlives: false,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> ? indices[key.value] : null,
    );
  }

  Future<bool> scrollToHeading(String slug) async {
    await ready;
    if (!mounted) return false;
    final key = _anchors[slug];
    if (key == null) return false;
    return _scrollToTarget(key);
  }

  Future<bool> scrollToSourceLine(int line) async {
    await ready;
    final blocks = _blocks;
    if (!mounted || blocks == null) return false;
    final source = widget.document.source;
    var start = 0;
    for (var i = 1; i < line; i++) {
      final next = source.indexOf('\n', start);
      if (next < 0) return false;
      start = next + 1;
    }
    final end = source.indexOf('\n', start);
    final stop = end == -1 ? source.length : end;
    var target = blocks
        .where(
          (block) =>
              block.offsets.any((offset) => offset >= start && offset < stop),
        )
        .firstOrNull;
    if (target == null) {
      String normalize(String value) =>
          value.replaceAll(RegExp(r'\s+'), ' ').trim();
      final sourceLine = source.substring(start, stop);
      final plain = normalize(
        parseMarkdownForPreview(
          sourceLine,
        ).map((node) => node.textContent).join(' '),
      );
      if (plain.isEmpty) return false;
      final prefix = const LineSplitter().convert(source.substring(0, start));
      final occurrence = prefix
          .where((line) => line.trim() == sourceLine.trim())
          .length;
      target = blocks
          .where((block) => normalize(block.node.textContent).contains(plain))
          .skip(occurrence)
          .firstOrNull;
    }
    if (target == null) return false;
    setState(() {
      _sourceLineBlock = target!.key;
      _makeDelegate();
    });
    await WidgetsBinding.instance.endOfFrame;
    return _scrollToTarget(_sourceLineKey);
  }

  Future<bool> _scrollToTarget(GlobalKey key) async {
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
      : widget.document.source.trim().isEmpty
      ? const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('This note is empty.'),
          ),
        )
      : SliverList(delegate: _delegate!);

  @override
  void dispose() {
    _generation++;
    _navigation++;
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
    this.onCopyTask,
  });
  final md.Node node;
  final double zoom;
  final List<int> offsets;
  final bool compactTaskSpacing;
  final List<GlobalKey> headingKeys;
  final Map<String, Uint8List> assets;
  final void Function(int, bool) onToggle;
  final void Function(String) onFollow;
  final void Function(int)? onCopyTask;
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
        final checkboxWidget = SizedBox(
          width: 44,
          height: 44,
          child: Checkbox(
            value: checked,
            onChanged: index >= widget.offsets.length
                ? null
                : (value) => widget.onToggle(widget.offsets[index], value!),
          ),
        );
        return _CheckboxBaseline(
          baseline: baseline,
          child:
              widget.onCopyTask != null &&
                  widget.offsets.length > 1 &&
                  index < widget.offsets.length
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    checkboxWidget,
                    IconButton(
                      tooltip: 'Copy linked to-do',
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 44,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 15,
                      color: NoterTheme.muted,
                      onPressed: () =>
                          widget.onCopyTask!(widget.offsets[index]),
                      icon: const Icon(Icons.content_copy_outlined),
                    ),
                  ],
                )
              : checkboxWidget,
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
  Widget build(BuildContext context) {
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _children,
    );
    return Padding(
      padding: EdgeInsets.only(
        bottom: widget.compactTaskSpacing
            ? 2
            : noterMarkdownStyle(context).blockSpacing!,
      ),
      child: widget.onCopyTask != null && widget.offsets.length == 1
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: column),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: IconButton(
                    tooltip: 'Copy linked to-do',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    color: NoterTheme.muted,
                    onPressed: () => widget.onCopyTask!(widget.offsets.single),
                    icon: const Icon(Icons.content_copy_outlined),
                  ),
                ),
              ],
            )
          : column,
    );
  }

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

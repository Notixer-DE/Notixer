import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../data/markdown_document.dart';
import 'markdown_style.dart';

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
        return _PreviewBlock(node, '$fingerprint:$occurrence', tasks, slugs);
      })(),
  ];
}

Future<List<_PreviewBlock>> _parseOffThread(String source) => Isolate.run(
  () => _parsePreview(source),
  debugName: 'noter:markdown-preview',
);

/// Parse large documents off the UI isolate; build and retain only nearby
/// Markdown blocks. Scrolling and save-status updates never parse the source.
class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    super.key,
    required this.document,
    required this.scrollController,
    required this.onToggle,
    required this.onFollow,
  });
  final MarkdownDocument document;
  final ScrollController scrollController;
  final void Function(int offset, bool checked) onToggle;
  final void Function(String href) onFollow;
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
    if (assetsChanged) _widgets.clear();
    if (oldWidget.document.source != widget.document.source) {
      _navigation++;
      _load();
    } else if (assetsChanged) {
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
        final cacheKey =
            '${block.key}:${block.offsets}:${block.headings}:${[for (final slug in block.headings) identityHashCode(_anchors[slug])]}';
        final cached = _widgets.remove(cacheKey);
        final child =
            cached ??
            _MarkdownBlock(
              key: ValueKey(block.key),
              node: block.node,
              offsets: block.offsets,
              headingKeys: [for (final slug in block.headings) _anchors[slug]!],
              assets: widget.document.assets,
              onToggle: (offset, checked) {
                if (_pendingSource == null) widget.onToggle(offset, checked);
              },
              onFollow: (href) => widget.onFollow(href),
            );
        if (cached == null) debugBlockBuilds++;
        _widgets[cacheKey] = child;
        while (_widgets.length > 256) {
          _widgets.remove(_widgets.keys.first);
        }
        return child;
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
    _widgets.clear();
    super.dispose();
  }
}

class _MarkdownBlock extends StatefulWidget {
  const _MarkdownBlock({
    super.key,
    required this.node,
    required this.offsets,
    required this.headingKeys,
    required this.assets,
    required this.onToggle,
    required this.onFollow,
  });
  final md.Node node;
  final List<int> offsets;
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
    final style = noterMarkdownStyle(context);
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
    padding: EdgeInsets.only(bottom: noterMarkdownStyle(context).blockSpacing!),
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

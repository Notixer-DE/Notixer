import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../data/library_graph.dart';
import '../data/notebook.dart';
import 'noter_theme.dart';

class LibraryGraphPage extends StatefulWidget {
  const LibraryGraphPage({
    super.key,
    required this.repository,
    this.sourceOverrides = const {},
    this.focusNoteId,
  });
  final NotebookRepository repository;
  final String? focusNoteId;
  final Map<String, String> sourceOverrides;
  @override
  State<LibraryGraphPage> createState() => _LibraryGraphPageState();
}

class _LibraryGraphPageState extends State<LibraryGraphPage> {
  static const _minScale = .01;

  late Future<LibraryGraph> _graph = LibraryGraph.load(
    widget.repository,
    sourceOverrides: widget.sourceOverrides,
  );
  final _transform = TransformationController();
  final _search = TextEditingController();
  bool _showTags = true, _showSearch = false, _fitPending = true;
  late bool _local = widget.focusNoteId != null;
  late String? _focusId = widget.focusNoteId == null
      ? null
      : 'note:${widget.focusNoteId}';
  String _query = '', _layoutKey = '';
  String? _tag;
  Size? _viewport;
  Map<String, Offset> _positions = {};
  @override
  void dispose() {
    _transform.dispose();
    _search.dispose();
    super.dispose();
  }

  void _fit(Size viewport, double extent) {
    if (viewport.isEmpty || extent <= 0) return;
    final scale = (math.min(viewport.width, viewport.height) / extent * .92)
        .clamp(_minScale, 1.25);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (viewport.width - extent * scale) / 2,
        (viewport.height - extent * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
  }

  Future<void> _chooseFocus() async {
    final graph = await _graph;
    if (!mounted) return;
    final notes = graph.nodes.where((node) => !node.isTag).toList();
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose graph focus'),
        content: SizedBox(
          width: 400,
          height: MediaQuery.sizeOf(context).height * .5,
          child: ListView.builder(
            itemCount: notes.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(notes[index].label),
              selected: notes[index].id == _focusId,
              onTap: () => Navigator.pop(context, notes[index].id),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        _focusId = chosen;
        _local = true;
        _tag = null;
        _fitPending = true;
      });
    }
  }

  Future<void> _options(String value) async {
    try {
      if (value == 'focus' ||
          (value == 'local' && !_local && _focusId == null)) {
        await _chooseFocus();
        return;
      }
      if (value == 'warnings') {
        final graph = await _graph;
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Graph indexing'),
            content: SizedBox(
              width: 400,
              height: 260,
              child: graph.warnings.isEmpty
                  ? const Center(child: Text('All files indexed.'))
                  : ListView(
                      children: [
                        for (final warning in graph.warnings)
                          ListTile(title: Text(warning)),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        if (value == 'tags') {
          _showTags = !_showTags;
          _tag = null;
        }
        if (value == 'local') {
          _local = !_local;
          _tag = null;
        }
        if (value == 'reload') {
          _graph = LibraryGraph.load(
            widget.repository,
            sourceOverrides: widget.sourceOverrides,
          );
        }
        _fitPending = true;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update graph: $error')),
        );
      }
    }
  }

  void _toggleSearch() {
    FocusScope.of(context).unfocus();
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _search.clear();
        _query = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Graph view',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: _showSearch ? 'Close graph search' : 'Search graph',
          onPressed: _toggleSearch,
          icon: Icon(_showSearch ? Icons.search_off : Icons.search),
        ),
        PopupMenuButton<String>(
          tooltip: 'Graph options',
          onSelected: _options,
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'tags',
              checked: _showTags,
              child: const Text('Show tags'),
            ),
            CheckedPopupMenuItem(
              value: 'local',
              checked: _local,
              child: const Text('Local graph'),
            ),
            const PopupMenuItem(
              value: 'focus',
              child: Text('Choose focus file'),
            ),
            const PopupMenuItem(value: 'reload', child: Text('Reload graph')),
            const PopupMenuItem(
              value: 'warnings',
              child: Text('Indexing status'),
            ),
          ],
        ),
      ],
    ),
    body: SafeArea(
      child: FutureBuilder<LibraryGraph>(
        future: _graph,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Could not load graph: ${snapshot.error}',
                maxLines: 4,
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final graph = snapshot.data!;
          if (graph.nodes.isEmpty) {
            return const Center(
              child: Text('Create notes and link them to see their graph.'),
            );
          }
          final localIds = <String>{
            ?_focusId,
            for (final edge in graph.edges)
              if (edge.from == _focusId) edge.to,
            for (final edge in graph.edges)
              if (edge.to == _focusId) edge.from,
          };
          final tagged = <String>{
            ?_tag,
            for (final edge in graph.edges)
              if (edge.to == _tag) edge.from,
          };
          final nodes = graph.nodes
              .where(
                (node) =>
                    (!_local || localIds.contains(node.id)) &&
                    (_showTags || !node.isTag) &&
                    (_tag == null || tagged.contains(node.id)),
              )
              .toList();
          final labelSize = MediaQuery.textScalerOf(context).scale(12);
          final nodeWidth = math.max(130.0, labelSize * 6 + 40),
              nodeHeight = math.max(64.0, labelSize * 3 + 16);
          final nodeScale = math.max(nodeWidth / 130, nodeHeight / 64);
          final extent =
              math.max(400.0, math.sqrt(nodes.length) * 150) * nodeScale;
          final key =
              '${identityHashCode(graph)}:$nodeScale:${nodes.map((node) => node.id).join('|')}';
          if (_layoutKey != key) {
            _positions = _layout(nodes, graph.edges, extent, nodeScale);
            _layoutKey = key;
            _fitPending = true;
          }
          final ids = nodes.map((node) => node.id).toSet();
          final edges = graph.edges
              .where((edge) => ids.contains(edge.from) && ids.contains(edge.to))
              .toList();
          final focus = graph.nodes
              .where((node) => node.id == _focusId)
              .firstOrNull;
          return Semantics(
            key: const ValueKey('graph-counts'),
            label:
                '${nodes.where((node) => !node.isTag).length} files · ${edges.length} connections',
            explicitChildNodes: true,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewport = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final previousViewport = _viewport;
                _viewport = viewport;
                if (_fitPending) {
                  _fitPending = false;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _fit(viewport, extent);
                  });
                } else if (previousViewport != null &&
                    previousViewport != viewport) {
                  final shift =
                      viewport.center(Offset.zero) -
                      previousViewport.center(Offset.zero);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    // Preserve the scene point at the center when resizing.
                    _transform.value = Matrix4.translationValues(
                      shift.dx,
                      shift.dy,
                      0,
                    )..multiply(_transform.value);
                  });
                }
                return Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: NoterTheme.workspace,
                        child: InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          minScale: _minScale,
                          maxScale: 5,
                          boundaryMargin: const EdgeInsets.all(double.infinity),
                          child: SizedBox(
                            width: extent,
                            height: extent,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _EdgesPainter(_positions, edges),
                                  ),
                                ),
                                for (final node in nodes)
                                  Positioned(
                                    left:
                                        _positions[node.id]!.dx - nodeWidth / 2,
                                    top:
                                        _positions[node.id]!.dy -
                                        nodeHeight / 2,
                                    width: nodeWidth,
                                    height: nodeHeight,
                                    child: Opacity(
                                      opacity:
                                          _query.isEmpty ||
                                              node.label.toLowerCase().contains(
                                                _query,
                                              )
                                          ? 1
                                          : .25,
                                      child: Tooltip(
                                        message: node.label,
                                        child: Material(
                                          color: node.isTag
                                              ? const Color(0xFFFFE8C2)
                                              : Colors.white,
                                          elevation: 1,
                                          borderRadius: BorderRadius.circular(
                                            node.isTag ? 28 : 8,
                                          ),
                                          child: InkWell(
                                            key: ValueKey(
                                              'graph-node-${node.id}',
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              node.isTag ? 28 : 8,
                                            ),
                                            onTap: () {
                                              if (node.isTag) {
                                                setState(() {
                                                  _tag = node.id;
                                                  _fitPending = true;
                                                });
                                              } else {
                                                Navigator.pop(
                                                  context,
                                                  node.note,
                                                );
                                              }
                                            },
                                            child: Padding(
                                              padding: const EdgeInsets.all(8),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    node.isTag
                                                        ? Icons.tag
                                                        : node.note!.isMedia
                                                        ? Icons
                                                              .perm_media_outlined
                                                        : node.note!.isMarkdown
                                                        ? Icons
                                                              .description_outlined
                                                        : Icons
                                                              .picture_as_pdf_outlined,
                                                    size: 18,
                                                    color:
                                                        NoterTheme.accentStrong,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      node.label,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_showSearch ||
                        (MediaQuery.viewInsetsOf(context).bottom == 0 &&
                            (_tag != null || _local)))
                      Positioned(
                        top: 8,
                        left: 8,
                        right: 8,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_showSearch)
                              Material(
                                elevation: 2,
                                borderRadius: BorderRadius.circular(8),
                                child: TextField(
                                  controller: _search,
                                  autofocus: true,
                                  textInputAction: TextInputAction.search,
                                  onSubmitted: (_) =>
                                      FocusScope.of(context).unfocus(),
                                  onChanged: (value) => setState(
                                    () => _query = value.trim().toLowerCase(),
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: 'Find a file or tag',
                                    prefixIcon: Icon(Icons.search),
                                  ),
                                ),
                              ),
                            if (MediaQuery.viewInsetsOf(context).bottom == 0)
                              Wrap(
                                spacing: 8,
                                children: [
                                  if (_tag != null)
                                    InputChip(
                                      label: Text(
                                        '#${_tag!.substring(4)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      onDeleted: () => setState(() {
                                        _tag = null;
                                        _fitPending = true;
                                      }),
                                    ),
                                  if (_local && focus != null)
                                    InputChip(
                                      label: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 200,
                                        ),
                                        child: Text(
                                          focus.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      onPressed: _chooseFocus,
                                      onDeleted: () => setState(() {
                                        _local = false;
                                        _fitPending = true;
                                      }),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: IconButton.filledTonal(
                        tooltip: 'Fit graph',
                        onPressed: () => _fit(viewport, extent),
                        icon: const Icon(Icons.fit_screen),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    ),
  );
}

/// A deterministic force layout for small libraries; bounded grid placement for
/// large libraries avoids quadratic work when opening a sizeable collection.
Map<String, Offset> _layout(
  List<LibraryGraphNode> nodes,
  Set<LibraryGraphEdge> edges,
  double extent,
  double nodeScale,
) {
  final positions = <String, Offset>{};
  final count = nodes.length;
  if (count == 0) return positions;
  if (count > 180) {
    final columns = math.sqrt(count).ceil();
    for (var i = 0; i < count; i++) {
      positions[nodes[i].id] = Offset(
        90 * nodeScale +
            (i % columns) *
                (extent - 180 * nodeScale) /
                math.max(1, columns - 1),
        90 * nodeScale +
            (i ~/ columns) *
                (extent - 180 * nodeScale) /
                math.max(1, columns - 1),
      );
    }
    return positions;
  }
  for (var i = 0; i < count; i++) {
    final angle = i * math.pi * 2 / count;
    positions[nodes[i].id] = Offset(
      extent / 2 + math.cos(angle) * extent * .32,
      extent / 2 + math.sin(angle) * extent * .32,
    );
  }
  for (var step = 0; step < 70; step++) {
    final forces = {for (final node in nodes) node.id: Offset.zero};
    for (var i = 0; i < count; i++) {
      for (var j = i + 1; j < count; j++) {
        final a = nodes[i].id, b = nodes[j].id;
        final delta = positions[a]! - positions[b]!;
        final distance = math.max(1.0, delta.distance);
        final push =
            delta /
            distance *
            math.min(
              20 * nodeScale,
              9000 * nodeScale * nodeScale / (distance * distance),
            );
        forces[a] = forces[a]! + push;
        forces[b] = forces[b]! - push;
      }
    }
    for (final edge in edges) {
      if (!positions.containsKey(edge.from) ||
          !positions.containsKey(edge.to)) {
        continue;
      }
      final delta = positions[edge.to]! - positions[edge.from]!;
      final distance = math.max(1.0, delta.distance);
      final pull = delta / distance * (distance - 170 * nodeScale) * .025;
      forces[edge.from] = forces[edge.from]! + pull;
      forces[edge.to] = forces[edge.to]! - pull;
    }
    for (final node in nodes) {
      final next = positions[node.id]! + forces[node.id]!;
      positions[node.id] = Offset(
        next.dx.clamp(80 * nodeScale, extent - 80 * nodeScale),
        next.dy.clamp(48 * nodeScale, extent - 48 * nodeScale),
      );
    }
  }
  return positions;
}

class _EdgesPainter extends CustomPainter {
  _EdgesPainter(this.positions, this.edges);
  final Map<String, Offset> positions;
  final List<LibraryGraphEdge> edges;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = NoterTheme.secondary.withValues(alpha: .6)
      ..strokeWidth = 1.5;
    for (final edge in edges) {
      final from = positions[edge.from]!, to = positions[edge.to]!;
      canvas.drawLine(from, to, paint);
    }
  }

  @override
  bool shouldRepaint(_EdgesPainter oldDelegate) =>
      oldDelegate.positions != positions || oldDelegate.edges != edges;
}

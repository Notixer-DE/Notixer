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
  });
  final NotebookRepository repository;
  final Map<String, String> sourceOverrides;
  @override
  State<LibraryGraphPage> createState() => _LibraryGraphPageState();
}

class _LibraryGraphPageState extends State<LibraryGraphPage> {
  late Future<LibraryGraph> _graph = LibraryGraph.load(
    widget.repository,
    sourceOverrides: widget.sourceOverrides,
  );
  final _transform = TransformationController();
  bool _showTags = true;
  String _query = '';
  String? _tag;
  bool _fitPending = true;
  String _layoutKey = '';
  Map<String, Offset> _positions = {};
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _fit(Size viewport, double extent) {
    final scale = math.min(
      1.25,
      math.min(viewport.width / extent, viewport.height / extent) * .92,
    );
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (viewport.width - extent * scale) / 2,
        (viewport.height - extent * scale) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Graph view'),
      actions: [
        IconButton(
          tooltip: 'Reload graph',
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() {
            _graph = LibraryGraph.load(
              widget.repository,
              sourceOverrides: widget.sourceOverrides,
            );
            _fitPending = true;
          }),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Find a file or tag',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() {
                _query = value.trim().toLowerCase();
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilterChip(
                  label: const Text('Tags'),
                  selected: _showTags,
                  onSelected: (value) => setState(() {
                    _showTags = value;
                    _tag = null;
                    _fitPending = true;
                  }),
                ),
                if (_tag != null)
                  InputChip(
                    label: Text('#${_tag!.substring(4)}'),
                    onDeleted: () => setState(() {
                      _tag = null;
                      _fitPending = true;
                    }),
                  ),
                const Text(
                  'Tap a file to open it · Tap a tag to focus · Pinch to zoom',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<LibraryGraph>(
              future: _graph,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Could not load graph: ${snapshot.error}'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final graph = snapshot.data!;
                if (graph.nodes.isEmpty) {
                  return const Center(
                    child: Text(
                      'Your library is empty. Create notes and link them to see connections.',
                    ),
                  );
                }
                final neighbors = <String>{
                  ?_tag,
                  for (final edge in graph.edges)
                    if (edge.to == _tag) edge.from,
                };
                final nodes = graph.nodes
                    .where(
                      (node) =>
                          (_showTags || !node.isTag) &&
                          (_tag == null || neighbors.contains(node.id)),
                    )
                    .toList();
                final extent = math.max(400.0, math.sqrt(nodes.length) * 150);
                final layoutKey =
                    '${identityHashCode(graph)}:${nodes.map((node) => node.id).join('|')}';
                if (_layoutKey != layoutKey) {
                  _positions = _layout(nodes, graph.edges, extent);
                  _layoutKey = layoutKey;
                }
                final positions = _positions;
                final visibleIds = nodes.map((node) => node.id).toSet();
                final edges = graph.edges
                    .where(
                      (edge) =>
                          visibleIds.contains(edge.from) &&
                          visibleIds.contains(edge.to),
                    )
                    .toList();
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '${nodes.where((n) => !n.isTag).length} files · ${edges.length} connections',
                        key: const ValueKey('graph-counts'),
                      ),
                    ),
                    if (graph.warnings.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.warning_amber_outlined),
                        label: Text(
                          '${graph.warnings.length} files could not be indexed',
                        ),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Graph indexing warnings'),
                            content: SizedBox(
                              width: 400,
                              height: 280,
                              child: ListView(
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
                        ),
                      ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final viewport = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          if (_fitPending) {
                            _fitPending = false;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _fit(viewport, extent);
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
                                    minScale: .01,
                                    maxScale: 5,
                                    boundaryMargin: EdgeInsets.all(extent),
                                    child: SizedBox(
                                      width: extent,
                                      height: extent,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: CustomPaint(
                                              painter: _EdgesPainter(
                                                positions,
                                                edges,
                                              ),
                                            ),
                                          ),
                                          for (final node in nodes)
                                            Positioned(
                                              left: positions[node.id]!.dx - 65,
                                              top: positions[node.id]!.dy - 32,
                                              width: 130,
                                              height: 64,
                                              child: Opacity(
                                                opacity:
                                                    _query.isEmpty ||
                                                        node.label
                                                            .toLowerCase()
                                                            .contains(_query)
                                                    ? 1
                                                    : .25,
                                                child: Tooltip(
                                                  message: node.label,
                                                  child: Material(
                                                    color: node.isTag
                                                        ? const Color(
                                                            0xFFFFE8C2,
                                                          )
                                                        : Colors.white,
                                                    elevation: 1,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          node.isTag ? 28 : 8,
                                                        ),
                                                    child: InkWell(
                                                      key: ValueKey(
                                                        'graph-node-${node.id}',
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
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
                                                        padding:
                                                            const EdgeInsets.all(
                                                              8,
                                                            ),
                                                        child: Row(
                                                          children: [
                                                            Icon(
                                                              node.isTag
                                                                  ? Icons.tag
                                                                  : node
                                                                        .note!
                                                                        .isMarkdown
                                                                  ? Icons
                                                                        .description_outlined
                                                                  : Icons
                                                                        .picture_as_pdf_outlined,
                                                              size: 18,
                                                              color: NoterTheme
                                                                  .accentStrong,
                                                            ),
                                                            const SizedBox(
                                                              width: 6,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                node.label,
                                                                maxLines: 2,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style:
                                                                    const TextStyle(
                                                                      fontSize:
                                                                          12,
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
                    ),
                  ],
                );
              },
            ),
          ),
        ],
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
) {
  final positions = <String, Offset>{};
  final count = nodes.length;
  if (count == 0) return positions;
  if (count > 180) {
    final columns = math.sqrt(count).ceil();
    for (var i = 0; i < count; i++) {
      positions[nodes[i].id] = Offset(
        90 + (i % columns) * (extent - 180) / math.max(1, columns - 1),
        90 + (i ~/ columns) * (extent - 180) / math.max(1, columns - 1),
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
            delta / distance * math.min(20, 9000 / (distance * distance));
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
      final pull = delta / distance * (distance - 170) * .025;
      forces[edge.from] = forces[edge.from]! + pull;
      forces[edge.to] = forces[edge.to]! - pull;
    }
    for (final node in nodes) {
      final next = positions[node.id]! + forces[node.id]!;
      positions[node.id] = Offset(
        next.dx.clamp(80, extent - 80),
        next.dy.clamp(48, extent - 48),
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

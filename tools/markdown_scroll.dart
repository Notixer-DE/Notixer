// Run on the device being evaluated, not under flutter test:
// flutter run --profile -d linux -t tools/markdown_scroll.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:noter/data/markdown_document.dart';
import 'package:noter/ui/markdown_preview.dart';
import 'package:noter/ui/noter_theme.dart';

import '../test/fixtures/long_markdown.dart';

void main() => runApp(const _ScrollBenchmark());

class _ScrollBenchmark extends StatefulWidget {
  const _ScrollBenchmark();

  @override
  State<_ScrollBenchmark> createState() => _ScrollBenchmarkState();
}

class _ScrollBenchmarkState extends State<_ScrollBenchmark> {
  final _scroll = ScrollController();
  final _preview = GlobalKey<MarkdownPreviewState>();
  final _document = MarkdownDocument(longMarkdown());
  final _frames = <FrameTiming>[];
  String _status = 'Warming up …';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _record(List<FrameTiming> timings) => _frames.addAll(timings);

  Future<void> _measure() async {
    await _preview.currentState?.ready;
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _scroll.animateTo(
      3000,
      duration: const Duration(seconds: 2),
      curve: Curves.linear,
    );
    if (!mounted) return;
    setState(() => _status = 'Measuring: 10 seconds down, 10 seconds up …');
    // Flush the warm-up timing batch before collecting scroll frames.
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    SchedulerBinding.instance.addTimingsCallback(_record);
    await _scroll.animateTo(
      33000,
      duration: const Duration(seconds: 10),
      curve: Curves.linear,
    );
    if (!mounted) return;
    await _scroll.animateTo(
      3000,
      duration: const Duration(seconds: 10),
      curve: Curves.linear,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    SchedulerBinding.instance.removeTimingsCallback(_record);
    if (!mounted) return;
    final budget = double.parse(
      const String.fromEnvironment('FRAME_BUDGET_MS', defaultValue: '16.67'),
    );
    Map<String, Object> summarize(List<double> values) {
      values.sort();
      if (values.isEmpty) return {'samples': 0};
      return {
        'samples': values.length,
        'p50_ms': values[(values.length * .50).floor()],
        'p95_ms': values[(values.length * .95).floor()],
        'max_ms': values.last,
        'over_budget': values.where((value) => value > budget).length,
      };
    }

    final report = {
      'scenario': '1000 Markdown sections, 3000 px/s, down and up',
      'mode': Platform.environment['NOTER_BENCHMARK_EXIT'] == '1'
          ? 'headless Flutter JIT, real clock, no hardware FPS claim'
          : 'device run',
      'parses': _preview.currentState?.debugParses ?? 0,
      'built_blocks': _preview.currentState?.debugBlockBuilds ?? 0,
      'cached_blocks': _preview.currentState?.debugCachedBlocks ?? 0,
      'frame_budget_ms': budget,
      'ui': summarize([
        for (final frame in _frames) frame.buildDuration.inMicroseconds / 1000,
      ]),
      'raster': summarize([
        for (final frame in _frames) frame.rasterDuration.inMicroseconds / 1000,
      ]),
      'slower_stage': summarize([
        for (final frame in _frames)
          math.max(
                frame.buildDuration.inMicroseconds,
                frame.rasterDuration.inMicroseconds,
              ) /
              1000,
      ]),
    };
    // ignore: avoid_print
    print('NOTER_MARKDOWN_SCROLL=${jsonEncode(report)}');
    if (Platform.environment['NOTER_BENCHMARK_EXIT'] == '1') exit(0);
    setState(
      () => _status = const JsonEncoder.withIndent('  ').convert(report),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: NoterTheme.light,
    home: Scaffold(
      appBar: AppBar(title: const Text('Markdown-Scrollmessung')),
      body: Column(
        children: [
          Text(_status),
          Expanded(
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(24),
                  sliver: MarkdownPreview(
                    key: _preview,
                    document: _document,
                    scrollController: _scroll,
                    onToggle: (_, _) {},
                    onFollow: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    _scroll.dispose();
    super.dispose();
  }
}

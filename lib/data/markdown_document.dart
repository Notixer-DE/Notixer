import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'media.dart';

/// Markdown is the source of truth. Assets travel with it, never as host paths.
class MarkdownDocument {
  MarkdownDocument(this.source, [Map<String, Uint8List> assets = const {}])
    : assets = Map.unmodifiable(assets);

  final String source;
  final Map<String, Uint8List> assets;
  static const maxTextBytes = 4 * 1024 * 1024;
  static const maxAssetBytes = 32 * 1024 * 1024;
  static const maxTotalBytes = 64 * 1024 * 1024;

  MarkdownDocument copy({String? source, Map<String, Uint8List>? assets}) =>
      MarkdownDocument(source ?? this.source, assets ?? this.assets);

  static bool safePath(String name) =>
      name.isNotEmpty &&
      name.length <= 1024 &&
      name.split('/').every((part) => part.length <= 255) &&
      !name.contains(r'\') &&
      !name.contains('\u0000') &&
      !p.posix.isAbsolute(name) &&
      !name.contains(':') &&
      p.posix.normalize(name) == name &&
      name != '..' &&
      !name.startsWith('../');

  Uint8List encode() {
    final text = utf8.encode(source);
    if (text.length > maxTextBytes) {
      throw const FormatException('Markdown is too large (maximum 4 MB).');
    }
    var total = text.length;
    final archive = Archive()
      ..addFile(
        ArchiveFile('document.md', text.length, text)..lastModTime = 315532800,
      );
    for (final entry in assets.entries) {
      if (!safePath(entry.key) ||
          !entry.key.startsWith('assets/') ||
          entry.value.length > maxAssetBytes) {
        throw const FormatException('Invalid Markdown attachment.');
      }
      total += entry.value.length;
      archive.addFile(
        ArchiveFile(entry.key, entry.value.length, entry.value)
          ..lastModTime = 315532800,
      );
    }
    if (total > maxTotalBytes) {
      throw const FormatException(
        'Markdown with attachments is too large (64 MB).',
      );
    }
    final bytes = ZipEncoder().encodeBytes(archive);
    if (bytes.length > maxTotalBytes) {
      throw const FormatException('The Markdown bundle is too large (64 MB).');
    }
    return bytes;
  }

  factory MarkdownDocument.decode(Uint8List bytes) {
    if (bytes.length > maxTotalBytes) {
      throw const FormatException('The Markdown bundle is too large.');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    var total = 0;
    final names = <String>{};
    final assets = <String, Uint8List>{};
    String? source;
    for (final file in archive.files) {
      if (!file.isFile ||
          !safePath(file.name) ||
          !names.add(file.name) ||
          (file.name != 'document.md' && !file.name.startsWith('assets/'))) {
        throw const FormatException('Invalid Markdown bundle.');
      }
      total += file.size;
      if (total > maxTotalBytes ||
          file.size >
              (file.name == 'document.md' ? maxTextBytes : maxAssetBytes)) {
        throw const FormatException('Markdown content is too large.');
      }
      if (file.name == 'document.md') {
        source = utf8.decode(file.content);
      } else {
        assets[file.name] = file.content;
      }
    }
    if (source == null) throw const FormatException('Markdown is missing.');
    return MarkdownDocument(source, assets);
  }

  (MarkdownDocument, String) withAttachment(Uint8List bytes, String extension) {
    final format = MediaFormat.of(extension);
    if (format == null) {
      throw const FormatException('Unsupported media attachment.');
    }
    format.validate(bytes);
    final name = 'assets/${sha256.convert(bytes)}.${format.extension}';
    final result = copy(assets: {...assets, name: bytes});
    if (bytes.length > maxAssetBytes ||
        utf8.encode(source).length +
                result.assets.values.fold<int>(0, (sum, b) => sum + b.length) >
            maxTotalBytes) {
      throw const FormatException(
        'The attachment or Markdown bundle is too large (32 MB per attachment, 64 MB total).',
      );
    }
    return (result, name);
  }

  /// Content-addressed names avoid image collisions when exporting notes together.
  (MarkdownDocument, String) withImage(Uint8List bytes, String extension) {
    if (!['png', 'jpg', 'jpeg'].contains(extension.toLowerCase())) {
      throw const FormatException('Only PNG and JPEG images are supported.');
    }
    final name = 'assets/${sha256.convert(bytes)}.${extension.toLowerCase()}';
    final result = copy(assets: {...assets, name: bytes});
    if (bytes.length > maxAssetBytes ||
        utf8.encode(source).length +
                result.assets.values.fold<int>(0, (sum, b) => sum + b.length) >
            maxTotalBytes) {
      throw const FormatException('The image or Markdown bundle is too large.');
    }
    return (result, name);
  }
}

Future<Uint8List> encodeMarkdownAsync(MarkdownDocument document) =>
    Isolate.run(() => document.encode(), debugName: 'noter:encode-markdown');

Future<MarkdownDocument> decodeMarkdownAsync(Uint8List bytes) => Isolate.run(
  () => MarkdownDocument.decode(bytes),
  debugName: 'noter:decode-markdown',
);

Future<(MarkdownDocument, String)> addMarkdownImageAsync(
  MarkdownDocument document,
  Uint8List bytes,
  String extension,
) => Isolate.run(
  () => document.withImage(bytes, extension),
  debugName: 'noter:add-markdown-image',
);

Future<(MarkdownDocument, String)> addMarkdownAttachmentAsync(
  MarkdownDocument document,
  Uint8List bytes,
  String extension,
) => Isolate.run(
  () => document.withAttachment(bytes, extension),
  debugName: 'noter:add-markdown-attachment',
);

List<md.Node> parseMarkdown(String source) => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  inlineSyntaxes: [WikiLinkSyntax()],
  encodeHtml: false,
).parseLines(const LineSplitter().convert(source));

/// Wiki links are parsed as inline syntax, so code spans/fences stay literal.
class WikiLinkSyntax extends md.InlineSyntax {
  WikiLinkSyntax() : super(r'\[\[([^\]\n]+)\]\]');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final parts = match[1]!.split('|');
    final target = parts.first.trim();
    final hash = target.indexOf('#');
    final title = hash < 0 ? target : target.substring(0, hash);
    final heading = hash < 0 ? null : target.substring(hash + 1);
    final slug = heading == null
        ? null
        : heading.startsWith('page=')
        ? heading
        : markdownHeadings('# $heading').firstOrNull ?? '';
    final href = Uri(
      scheme: 'noter-wiki',
      path: title,
      fragment: slug,
    ).toString();
    final node = md.Element.text(
      'a',
      parts.length > 1 ? parts.skip(1).join('|').trim() : target,
    );
    node.attributes['href'] = href;
    parser.addNode(node);
    return true;
  }
}

class MarkdownLink {
  const MarkdownLink(this.href, {required this.image});
  final String href;
  final bool image;
}

/// Use the parser, not a regular expression: code fences are not backlinks.
List<MarkdownLink> markdownLinks(String source) {
  final visitor = _Links();
  for (final node in parseMarkdown(source)) {
    node.accept(visitor);
  }
  return visitor.links;
}

class _Links implements md.NodeVisitor {
  final links = <MarkdownLink>[];
  @override
  bool visitElementBefore(md.Element element) {
    final target = element.attributes[element.tag == 'img' ? 'src' : 'href'];
    if ((element.tag == 'a' || element.tag == 'img') && target != null) {
      links.add(MarkdownLink(target, image: element.tag == 'img'));
    }
    return true;
  }

  @override
  void visitElementAfter(md.Element element) {}
  @override
  void visitText(md.Text text) {}
}

String? resolveMarkdownPath(String from, String href) {
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority || uri.hasQuery) {
    return null;
  }
  try {
    final decoded = Uri.decodeComponent(uri.path);
    final path = decoded.isEmpty
        ? from
        : p.posix.normalize(p.posix.join(p.posix.dirname(from), decoded));
    return MarkdownDocument.safePath(path) ? path : null;
  } on FormatException {
    return null;
  }
}

String? markdownAssetPath(Uri uri) {
  if (uri.hasScheme || uri.hasAuthority || uri.hasQuery) return null;
  try {
    final path = Uri.decodeComponent(uri.path);
    return MarkdownDocument.safePath(path) ? path : null;
  } on FormatException {
    return null;
  }
}

String markdownLabel(String title) =>
    title.replaceAll(r'\', r'\\').replaceAll('[', r'\[').replaceAll(']', r'\]');

List<String> markdownHeadings(String source) {
  return markdownHeadingsFromNodes(parseMarkdown(source));
}

List<String> markdownHeadingsFromNodes(List<md.Node> nodes) {
  final visitor = _Headings();
  for (final node in nodes) {
    node.accept(visitor);
  }
  return visitor.slugs;
}

typedef MarkdownHeading = ({String title, String slug, int level});

List<MarkdownHeading> markdownHeadingTargets(String source) {
  final visitor = _Headings();
  for (final node in parseMarkdown(source)) {
    node.accept(visitor);
  }
  return visitor.targets;
}

class _Headings implements md.NodeVisitor {
  final targets = <MarkdownHeading>[];
  final slugs = <String>[];
  final _used = <String>{};
  @override
  bool visitElementBefore(md.Element element) {
    if (RegExp(r'^h[1-6]$').hasMatch(element.tag)) {
      final base = element.textContent
          .toLowerCase()
          .replaceAll(RegExp(r'[^\p{L}\p{N}_\s-]', unicode: true), '')
          .replaceAll(RegExp(r'\s'), '-');
      var slug = base;
      var suffix = 1;
      while (!_used.add(slug)) {
        slug = '$base-${suffix++}';
      }
      slugs.add(slug);
      targets.add((
        title: element.textContent,
        slug: slug,
        level: int.parse(element.tag.substring(1)),
      ));
    }
    return true;
  }

  @override
  void visitElementAfter(md.Element element) {}
  @override
  void visitText(md.Text text) {}
}

/// Mark candidate lines, then let the Markdown parser decide which are actual
/// task list items. This handles nesting, quotes and fenced/indented code without
/// reimplementing the parser or rewriting a code example when a box is tapped.
List<int> markdownTaskOffsets(String source, {bool renderingOrder = false}) {
  var marker = '\uE000noter';
  while (source.contains(marker)) {
    marker += 'x';
  }
  final marked = <String>[];
  var offset = 0;
  for (final line in source.split('\n')) {
    final task = RegExp(
      r'^([ \t>]*(?:[-+*]|\d+[.)])[ \t]+)\[([ xX])\](?:[ \t]|(?=\r?$))',
    ).firstMatch(line);
    if (task == null) {
      marked.add(line);
    } else {
      final checkbox = task.group(1)!.length + 1;
      final token = '$marker${offset + checkbox}\uE001';
      // Keep the label's block syntax intact: prefixing a label changes a
      // heading/quote/fence into a paragraph and can turn code into tasks.
      final fence = RegExp(
        r'^[ \t]*(`{3,}|~{3,})',
      ).firstMatch(line.substring(task.end));
      if (fence != null) {
        final at = task.end + fence.end;
        marked.add('${line.substring(0, at)}$token${line.substring(at)}');
      } else {
        final at = line.endsWith('\r') ? line.length - 1 : line.length;
        final separator = task.end == task.group(1)!.length + 3 ? ' ' : '';
        marked.add(
          '${line.substring(0, at)}$separator$token${line.substring(at)}',
        );
      }
    }
    offset += line.length + 1;
  }
  final visitor = _Tasks(RegExp('${RegExp.escape(marker)}(\\d+)\uE001'));
  for (final node in parseMarkdown(marked.join('\n'))) {
    node.accept(visitor);
  }
  return renderingOrder ? visitor.offsets : (visitor.offsets..sort());
}

class _Tasks implements md.NodeVisitor {
  _Tasks(this.marker);
  final RegExp marker;
  final offsets = <int>[];
  final _minimum = <int?>[];
  void _merge(int? value) {
    if (value != null &&
        _minimum.isNotEmpty &&
        (_minimum.last == null || value < _minimum.last!)) {
      _minimum[_minimum.length - 1] = value;
    }
  }

  int? _offset(String text) {
    int? value;
    for (final match in marker.allMatches(text)) {
      final candidate = int.parse(match.group(1)!);
      if (value == null || candidate < value) value = candidate;
    }
    return value;
  }

  @override
  bool visitElementBefore(md.Element element) {
    _minimum.add(_offset(element.attributes.values.join(' ')));
    return true;
  }

  @override
  void visitElementAfter(md.Element element) {
    final value = _minimum.removeLast();
    // MarkdownBuilder creates a list item's bullet after its children.
    if (element.tag == 'li' &&
        element.attributes['class'] == 'task-list-item' &&
        value != null) {
      offsets.add(value);
    }
    _merge(value);
  }

  @override
  void visitText(md.Text text) => _merge(_offset(text.text));
}

/// Adapt the GFM AST to the renderer without rewriting the saved source.
/// Loose-list checkboxes live inside the first paragraph, whereas the widget
/// builder only recognizes an input directly beneath li.
List<md.Node> parseMarkdownForPreview(String source) {
  var emptyMarker = '\uE000noter-empty\uE001';
  while (source.contains(emptyMarker)) {
    emptyMarker += 'x';
  }
  final emptyTask = RegExp(
    r'^([ \t>]*(?:[-+*]|\d+[.)])[ \t]+\[[ xX]\])[ \t]*(\r?)$',
  );
  final marked = source
      .split('\n')
      .map(
        (line) => line.replaceFirstMapped(
          emptyTask,
          (m) => '${m[1]} $emptyMarker${m[2]}',
        ),
      )
      .join('\n');
  md.Node clean(md.Node node) {
    if (node is md.Text) {
      return md.Text(
        node.text.replaceAll(' $emptyMarker', '').replaceAll(emptyMarker, ''),
      );
    }
    if (node is! md.Element) return node;
    final children = node.children?.map(clean).toList();
    if (node.tag == 'li' &&
        children != null &&
        children.isNotEmpty &&
        children.first is md.Element) {
      final first = children.first as md.Element;
      if (first.tag == 'p' && first.children?.isNotEmpty == true) {
        final input = first.children!.first;
        if (input is md.Element &&
            input.tag == 'input' &&
            input.attributes['type'] == 'checkbox') {
          first.children!.removeAt(0);
          children.insert(0, input);
        }
      }
    }
    return md.Element(node.tag, children)..attributes.addAll(node.attributes);
  }

  return parseMarkdown(marked).map(clean).toList();
}

/// PDF destinations use one-based page numbers in portable Markdown links.
int? markdownPdfPage(String fragment) {
  final match = RegExp(
    r'^page=([1-9][0-9]*)(?:&quote=[^&]*)?$',
  ).firstMatch(fragment);
  return match == null ? null : int.tryParse(match[1]!);
}

String markdownPdfQuote(String fragment) {
  if (markdownPdfPage(fragment) == null) return '';
  try {
    return Uri.splitQueryString(fragment)['quote'] ?? '';
  } on FormatException {
    return '';
  }
}

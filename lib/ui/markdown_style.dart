import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'noter_theme.dart';

/// Reading typography is deliberately separate from compact application chrome.
/// Rendering, links and editable tasks still use the existing Markdown engine.
MarkdownStyleSheet noterMarkdownStyle(BuildContext context, {double zoom = 1}) {
  final body = TextStyle(
    fontSize: 14 * zoom,
    height: 1.55,
    color: NoterTheme.ink,
  );
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: body,
    a: const TextStyle(
      color: NoterTheme.accentStrong,
      decoration: TextDecoration.underline,
      decorationColor: NoterTheme.border,
    ),
    h1: TextStyle(
      fontSize: 24 * zoom,
      height: 1.3,
      fontWeight: FontWeight.w500,
      color: NoterTheme.ink,
    ),
    h2: TextStyle(
      fontSize: 20 * zoom,
      height: 1.35,
      fontWeight: FontWeight.w500,
      color: NoterTheme.ink,
    ),
    h3: TextStyle(
      fontSize: 17 * zoom,
      height: 1.4,
      fontWeight: FontWeight.w500,
      color: NoterTheme.ink,
    ),
    h4: TextStyle(
      fontSize: 15 * zoom,
      height: 1.4,
      fontWeight: FontWeight.w500,
      color: NoterTheme.ink,
    ),
    h5: body.copyWith(fontWeight: FontWeight.w500),
    h6: body.copyWith(color: NoterTheme.muted),
    blockSpacing: 12 * zoom,
    listBullet: body,
    blockquote: body.copyWith(color: NoterTheme.muted),
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    blockquoteDecoration: const BoxDecoration(
      color: NoterTheme.workspace,
      border: Border(left: BorderSide(color: NoterTheme.accent, width: 2)),
    ),
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: 12 * zoom,
      height: 1.6,
      color: NoterTheme.ink,
      backgroundColor: NoterTheme.workspace,
    ),
    codeblockPadding: const EdgeInsets.all(16),
    codeblockDecoration: BoxDecoration(
      color: NoterTheme.workspace,
      border: Border.all(color: NoterTheme.border),
      borderRadius: BorderRadius.circular(5),
    ),
    tableHead: TextStyle(
      fontSize: 13 * zoom,
      height: 1.5,
      fontWeight: FontWeight.w500,
      color: NoterTheme.ink,
    ),
    tableBody: TextStyle(
      fontSize: 13 * zoom,
      height: 1.5,
      color: NoterTheme.ink,
    ),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    tableBorder: TableBorder.all(color: NoterTheme.border),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: NoterTheme.border)),
    ),
  );
}

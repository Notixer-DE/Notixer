import 'package:flutter/material.dart';
import 'noter_theme.dart';

/// The PDF and Markdown tool strips share sizing, borders and interaction
/// states. Desktop density never shrinks touch targets on a phone or tablet.
class WorkspaceToolbar extends StatelessWidget {
  const WorkspaceToolbar({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final compact = NoterTheme.desktopControls(context);
    final extent = NoterTheme.controlExtent(context);
    return Theme(
      data: Theme.of(context).copyWith(
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
        materialTapTargetSize: compact
            ? MaterialTapTargetSize.shrinkWrap
            : MaterialTapTargetSize.padded,
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: Size.square(extent),
            maximumSize: Size.square(extent),
            padding: EdgeInsets.zero,
            iconSize: 18,
            foregroundColor: NoterTheme.muted,
            hoverColor: NoterTheme.workspace,
            highlightColor: NoterTheme.active,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: NoterTheme.border)),
        ),
        child: SizedBox(height: compact ? 44 : 52, child: child),
      ),
    );
  }
}

class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: NoterTheme.border)),
    ),
    child: child,
  );
}

class ToolbarSeparator extends StatelessWidget {
  const ToolbarSeparator({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 6),
    child: Center(
      child: SizedBox(
        height: 18,
        child: VerticalDivider(width: 1, thickness: 1),
      ),
    ),
  );
}

class DocumentTypeBadge extends StatelessWidget {
  const DocumentTypeBadge(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: NoterTheme.workspace,
      border: Border.all(color: NoterTheme.border),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: NoterTheme.muted,
        ),
      ),
    ),
  );
}

/// Shares the tab restore action without remounting document editors.
class DocumentTabsChrome extends InheritedWidget {
  const DocumentTabsChrome({
    super.key,
    required this.onShowTabs,
    required super.child,
  });
  final VoidCallback? onShowTabs;
  static VoidCallback? action(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DocumentTabsChrome>()
      ?.onShowTabs;
  static double? leadingWidth(BuildContext context) =>
      action(context) == null ? null : 96;
  @override
  bool updateShouldNotify(DocumentTabsChrome oldWidget) =>
      onShowTabs != oldWidget.onShowTabs;
}

class DocumentNavigation extends StatelessWidget {
  const DocumentNavigation({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final restore = DocumentTabsChrome.action(context);
    if (restore == null) return child;
    return Row(
      children: [
        IconButton(
          tooltip: 'Show document tabs',
          onPressed: restore,
          icon: const Icon(Icons.tab),
        ),
        Expanded(child: child),
      ],
    );
  }
}

/// Workspace navigation depends on available logical size, not the OS.
bool workspaceUsesRail(BuildContext context, double width, double height) =>
    width >= 600 &&
    height >= 480 &&
    (width >= 840 || width >= height) &&
    MediaQuery.textScalerOf(context).scale(14) <= 21;

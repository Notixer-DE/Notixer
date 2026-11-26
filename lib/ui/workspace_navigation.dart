import 'package:flutter/material.dart';

import 'workspace_chrome.dart';

enum WorkspaceArea {
  today('Today', Icons.today_outlined),
  files('Files', Icons.folder_outlined),
  tasks('Tasks', Icons.checklist),
  journal('Journal', Icons.calendar_month_outlined),
  more('More', Icons.more_horiz),
  search('Search', Icons.search),
  inbox('Inbox', Icons.inbox_outlined),
  tags('Tags', Icons.sell_outlined),
  views('Views', Icons.bookmarks_outlined),
  templates('Templates', Icons.dashboard_customize_outlined),
  backups('Backups', Icons.backup_outlined),
  settings('Settings', Icons.settings_outlined);

  const WorkspaceArea(this.label, this.icon);
  final String label;
  final IconData icon;

  WorkspaceArea get group => switch (this) {
    inbox || tags => files,
    views => search,
    templates || backups || settings => more,
    _ => this,
  };
}

class WorkspaceNavigation extends StatefulWidget {
  const WorkspaceNavigation({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelect,
    required this.child,
    this.back,
    this.actions = const [],
  });

  final List<WorkspaceArea> destinations;
  final WorkspaceArea selected;
  final ValueChanged<WorkspaceArea> onSelect;
  final VoidCallback? back;
  final List<Widget> actions;
  final Widget child;

  @override
  State<WorkspaceNavigation> createState() => _WorkspaceNavigationState();
}

class _WorkspaceNavigationState extends State<WorkspaceNavigation> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final rail = workspaceUsesRail(
        context,
        constraints.maxWidth,
        constraints.maxHeight,
      );
      final canExtend = rail && constraints.maxWidth >= 1200;
      final extended = canExtend && !_collapsed;
      final destinations = widget.destinations;
      final selected = widget.selected;
      final back = widget.back;
      final index = destinations.indexOf(selected.group);
      final bottomBar = !rail && MediaQuery.viewInsetsOf(context).bottom == 0;
      return Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 52,
                child: Row(
                  children: [
                    if (back != null) BackButton(onPressed: back),
                    if (canExtend)
                      IconButton(
                        tooltip: extended
                            ? 'Collapse navigation'
                            : 'Expand navigation',
                        icon: Icon(extended ? Icons.menu_open : Icons.menu),
                        onPressed: () =>
                            setState(() => _collapsed = !_collapsed),
                      )
                    else if (back == null)
                      const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        selected == WorkspaceArea.today
                            ? 'Notixer'
                            : selected.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    ...widget.actions,
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rail)
                  NavigationRail(
                    key: const ValueKey('workspace-rail'),
                    scrollable: true,
                    extended: extended,
                    labelType: extended
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    selectedIndex: index < 0 ? null : index,
                    onDestinationSelected: (index) =>
                        widget.onSelect(destinations[index]),
                    minExtendedWidth: 176,
                    destinations: [
                      for (final destination in destinations)
                        NavigationRailDestination(
                          icon: Icon(
                            destination.icon,
                            key: ValueKey('workspace-${destination.name}'),
                          ),
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                Expanded(
                  key: const ValueKey('workspace-content'),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    removeBottom: bottomBar,
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
          if (bottomBar)
            SafeArea(
              top: false,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: Row(
                  children: [
                    for (final destination in destinations)
                      Expanded(
                        child: Semantics(
                          selected: destination == selected.group,
                          button: true,
                          child: InkWell(
                            key: ValueKey('workspace-${destination.name}'),
                            onTap: () => widget.onSelect(destination),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 2,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    destination.icon,
                                    color: destination == selected.group
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                                  Text(
                                    destination.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

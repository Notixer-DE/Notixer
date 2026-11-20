import 'package:flutter/material.dart';

class TaskRowActions extends StatelessWidget {
  const TaskRowActions({
    required super.key,
    required this.onDelete,
    required this.child,
  });

  final Future<void> Function()? onDelete;
  final Widget child;

  Future<void> _menu(BuildContext context, Offset position) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    final remove = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromSize(local & Size.zero, overlay.size),
      items: const [
        PopupMenuItem(
          value: true,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('Delete to-do'),
          ),
        ),
      ],
    );
    if (remove == true && context.mounted) await onDelete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onDelete != null;
    return Dismissible(
      key: key!,
      direction: enabled ? DismissDirection.startToEnd : DismissDirection.none,
      background: ColoredBox(
        color: colors.errorContainer,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 20),
            child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
          ),
        ),
      ),
      confirmDismiss: (_) async {
        await onDelete?.call();
        // The task list removes the row only after the write succeeds.
        return false;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: enabled
            ? (details) => _menu(context, details.globalPosition)
            : null,
        onSecondaryTapUp: enabled
            ? (details) => _menu(context, details.globalPosition)
            : null,
        child: child,
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../sync/sync_controller.dart';

/// A direct sync action sharing the controller's lock and status with SyncPage.
class SyncButton extends StatelessWidget {
  const SyncButton({
    super.key,
    required this.controller,
    required this.onSynchronized,
    required this.onOpenDetails,
    this.disabled = false,
  });

  final SyncController controller;
  final Future<void> Function() onSynchronized;
  final VoidCallback onOpenDetails;
  final bool disabled;

  Future<void> _synchronize(BuildContext context) async {
    if (disabled || controller.busy || !controller.enabled) return;
    await controller.synchronize();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(controller.error ?? 'Sync completed successfully.'),
        action: controller.error == null
            ? null
            : SnackBarAction(label: 'Sync details', onPressed: onOpenDetails),
      ),
    );
    await onSynchronized();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.enabled) return const SizedBox.shrink();
      final failed = controller.error != null;
      final completed = controller.lastSyncedAt != null;
      final label = controller.busy
          ? 'Sync in progress'
          : failed
          ? 'Sync failed. Retry'
          : completed
          ? 'Synced. Sync again'
          : 'Sync now';
      return IconButton(
        tooltip: label,
        onPressed: disabled || controller.busy
            ? null
            : () => _synchronize(context),
        icon: controller.busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: 'Sync in progress',
                ),
              )
            : Icon(
                failed
                    ? Icons.sync_problem
                    : completed
                    ? Icons.cloud_done_outlined
                    : Icons.sync,
                color: failed ? Theme.of(context).colorScheme.error : null,
              ),
      );
    },
  );
}

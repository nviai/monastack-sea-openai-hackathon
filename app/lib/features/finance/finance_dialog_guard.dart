import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps a dialog invalidated after access changes, even if access later returns.
Widget guardFinanceDialog(
  ValueListenable<int> access,
  int epoch,
  Widget child,
) => ValueListenableBuilder<int>(
  valueListenable: access,
  builder: (context, current, _) => current == epoch
      ? child
      : AlertDialog(
          title: const Text('Finance access changed'),
          content: const Text(
            'Close this dialog and refresh before continuing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
);

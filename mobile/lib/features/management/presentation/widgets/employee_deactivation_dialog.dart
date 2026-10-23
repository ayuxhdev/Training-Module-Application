import 'package:flutter/material.dart';

class EmployeeDeactivationDialog extends StatefulWidget {
  const EmployeeDeactivationDialog({super.key});

  @override
  State<EmployeeDeactivationDialog> createState() =>
      _EmployeeDeactivationDialogState();
}

class _EmployeeDeactivationDialogState
    extends State<EmployeeDeactivationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_reasonController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Deactivate employee?'),
    content: Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Deactivation disables this employee’s login access. '
              'Historical training records are preserved.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _reasonController,
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason for deactivation',
                alignLabelWithHint: true,
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a reason.'
                  : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _confirm,
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
          foregroundColor: Theme.of(context).colorScheme.onError,
        ),
        child: const Text('Deactivate'),
      ),
    ],
  );
}

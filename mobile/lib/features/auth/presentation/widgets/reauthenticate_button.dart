import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

/// Reauthenticates the same account without replacing the route or its draft.
class ReauthenticateButton extends ConsumerWidget {
  final VoidCallback onRestored;
  const ReauthenticateButton({super.key, required this.onRestored});

  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    icon: const Icon(Icons.login),
    label: const Text('Sign in again'),
    onPressed: () async {
      final restored = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ReauthenticationDialog(),
      );
      if (restored == true && context.mounted) onRestored();
    },
  );
}

class _ReauthenticationDialog extends ConsumerStatefulWidget {
  const _ReauthenticationDialog();
  @override
  ConsumerState<_ReauthenticationDialog> createState() =>
      _ReauthenticationDialogState();
}

class _ReauthenticationDialogState
    extends ConsumerState<_ReauthenticationDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .reauthenticate(_password.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is ApiError
              ? error.message
              : 'Unable to sign in. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final username = auth is AuthAuthenticated
        ? auth.identity.username
        : auth is AuthUnauthenticated
        ? auth.expiredIdentity?.username ?? ''
        : '';
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Sign in to continue'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Account: $username'),
              const SizedBox(height: 12),
              const Text(
                'Your unsaved lesson changes will stay in this form. Saving remains a separate action.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                autofocus: true,
                obscureText: true,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Password',
                  errorText: _error,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signIn(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: _busy ? null : _signIn,
            child: Text(_busy ? 'Signing in...' : 'Sign in'),
          ),
        ],
      ),
    );
  }
}

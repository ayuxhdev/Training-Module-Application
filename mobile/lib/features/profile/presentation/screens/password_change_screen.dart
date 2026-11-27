import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/profile/data/password_change_repository.dart';

String? _account(AuthState state) => state is AuthAuthenticated
    ? '${state.identity.userId}:${state.identity.username}'
    : null;

class PasswordChangeScreen extends ConsumerStatefulWidget {
  const PasswordChangeScreen({super.key});

  @override
  ConsumerState<PasswordChangeScreen> createState() =>
      _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends ConsumerState<PasswordChangeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _visible = <String, bool>{};
  late final String? _owner;
  CancelToken? _request;
  bool _saving = false;
  bool _accountChanged = false;
  bool _needsSignIn = false;
  String? _error;
  Map<String, String> _fieldErrors = {};

  @override
  void initState() {
    super.initState();
    _owner = _account(ref.read(authControllerProvider));
  }

  bool get _ownsForm =>
      !_accountChanged &&
      _owner != null &&
      _account(ref.read(authControllerProvider)) == _owner;

  void _clearPasswords() {
    _current.clear();
    _password.clear();
    _confirmation.clear();
  }

  @override
  void dispose() {
    _request?.cancel('Password form disposed');
    _current.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !_ownsForm || !_formKey.currentState!.validate()) return;
    final request = CancelToken();
    _request = request;
    setState(() {
      _saving = true;
      _error = null;
      _fieldErrors = {};
    });
    try {
      await ref
          .read(passwordChangeRepositoryProvider)
          .changePassword(
            currentPassword: _current.text,
            newPassword: _password.text,
            confirmation: _confirmation.text,
            cancelToken: request,
          );
      if (!mounted || !_ownsForm || request.isCancelled) return;
      _clearPasswords();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Password changed. Sign in again with your new password.',
          ),
        ),
      );
      await ref.read(authControllerProvider.notifier).logout();
    } catch (error) {
      if (!mounted || !_ownsForm || request.isCancelled) return;
      final apiError = error is ApiError ? error : ApiError.unexpected();
      setState(() {
        _needsSignIn = apiError.statusCode == 401 || apiError.statusCode == 403;
        if (_needsSignIn) {
          _clearPasswords();
          _error = 'Your session has ended. Sign in again to continue.';
        } else {
          _error = apiError.statusCode == 400 || apiError.statusCode == 429
              ? apiError.message
              : 'Unable to confirm the password change. Check your connection. If it was submitted, try signing in with your new password before retrying.';
          if (apiError.details case final Map details) {
            for (final key in [
              'current_password',
              'new_password',
              'confirm_password',
            ]) {
              final value = details[key];
              if (value is List && value.isNotEmpty) {
                _fieldErrors[key] = value.first.toString();
              }
            }
          }
        }
      });
    } finally {
      if (mounted && _ownsForm) setState(() => _saving = false);
    }
  }

  Widget _field(
    String name,
    String label,
    TextEditingController controller, {
    required bool current,
  }) {
    final visible = _visible[name] ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: TextFormField(
        key: ValueKey(name),
        controller: controller,
        enabled: !_saving && !_needsSignIn,
        obscureText: !visible,
        autocorrect: false,
        enableSuggestions: false,
        maxLength: 4096,
        autofillHints: [
          current ? AutofillHints.password : AutofillHints.newPassword,
        ],
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          errorText: _fieldErrors[name],
          suffixIcon: IconButton(
            tooltip: '${visible ? 'Hide' : 'Show'} $label',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: _saving
                ? null
                : () => setState(() => _visible[name] = !visible),
            icon: Icon(
              visible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
        ),
        onChanged: (_) => setState(() {
          _fieldErrors.remove(name);
          _error = null;
        }),
        validator: (value) {
          if (value == null || value.isEmpty) return '$label is required.';
          if (name == 'confirm_password' && value != _password.text) {
            return 'Passwords do not match.';
          }
          if (name == 'new_password' && value == _current.text) {
            return 'Choose a different password.';
          }
          return null;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    ref.listen(authControllerProvider, (_, next) {
      if (_account(next) != _owner) {
        _accountChanged = true;
        _request?.cancel('Password form account changed');
        _clearPasswords();
      }
    });
    if (!_ownsForm) {
      return Scaffold(
        appBar: AppBar(title: const Text('Change password')),
        body: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(
            state is AuthAuthenticated
                ? 'Your account changed. Reopen this screen from Profile.'
                : 'Your session has ended. Sign in again to continue.',
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Changing your password ends other sessions. You will need to sign in again on Android.',
              ),
              const SizedBox(height: AppSpacing.lg),
              _field(
                'current_password',
                'Current password',
                _current,
                current: true,
              ),
              _field('new_password', 'New password', _password, current: false),
              _field(
                'confirm_password',
                'Confirm new password',
                _confirmation,
                current: false,
              ),
              if (_error != null) ...[
                Semantics(liveRegion: true, child: Text(_error!)),
                const SizedBox(height: AppSpacing.md),
              ],
              if (_needsSignIn)
                FilledButton(
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).logout(),
                  child: const Text('Sign in again'),
                )
              else
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Change password'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

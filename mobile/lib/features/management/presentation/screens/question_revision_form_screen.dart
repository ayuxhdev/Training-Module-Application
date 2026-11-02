import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class QuestionRevisionFormScreen extends ConsumerStatefulWidget {
  final int questionId;

  const QuestionRevisionFormScreen({super.key, required this.questionId});

  @override
  ConsumerState<QuestionRevisionFormScreen> createState() =>
      _QuestionRevisionFormScreenState();
}

class _QuestionRevisionFormScreenState
    extends ConsumerState<QuestionRevisionFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _questionType;
  late TextEditingController _promptController;
  late TextEditingController _explanationController;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  late String _account;

  bool get _isDirty {
    return _questionType != 'SINGLE_CHOICE' ||
        _promptController.text.trim().isNotEmpty ||
        _explanationController.text.trim().isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    _questionType = 'SINGLE_CHOICE';
    _promptController = TextEditingController();
    _explanationController = TextEditingController();
  }

  @override
  void dispose() {
    _activeRequest?.cancel('QuestionRevisionFormScreen disposed');
    _promptController.dispose();
    _explanationController.dispose();
    super.dispose();
  }

  Map<String, String> _fieldErrorsFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return const {};
    final result = <String, String>{};
    for (final entry in details.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is String && value.isNotEmpty) {
        result[key] = value;
      } else if (value is List && value.isNotEmpty) {
        result[key] = value.map((item) => item.toString()).join(' ');
      }
    }
    return result;
  }

  String? _nonFieldErrorFrom(ApiError error) {
    final details = error.details;
    if (details is! Map) return null;
    final value = details['non_field_errors'] ?? details['detail'];
    if (value is String && value.isNotEmpty) return value;
    if (value is List && value.isNotEmpty) {
      return value.map((item) => item.toString()).join(' ');
    }
    return null;
  }

  Future<bool> _onWillPop() async {
    if (!_isDirty || _isSubmitting) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard revision?'),
        content: const Text(
          'You have unsaved changes. Are you sure you want to discard this new revision?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final auth = ref.read(authControllerProvider);
    final currentAccount = managementAccount(auth) ?? '';
    if (currentAccount != _account) {
      setState(() {
        _serverError =
            'Account context changed. Please reload the form to submit.';
      });
      return;
    }

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _serverError = null;
      _fieldErrors = const {};
    });

    final cancelToken = CancelToken();
    _activeRequest = cancelToken;

    final prompt = _promptController.text.trim();
    final explanation = _explanationController.text.trim();

    try {
      final revision = await ref
          .read(questionRevisionMutationProvider)
          .create(
            questionId: widget.questionId,
            questionType: _questionType,
            prompt: prompt,
            explanation: explanation,
            cancelToken: cancelToken,
          );

      ref.invalidate(managedQuestionRevisionsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Revision ${revision.revisionNumber} created. You can now configure options.',
            ),
          ),
        );
        context.pushReplacement(
          '/workspace/training/questions/${widget.questionId}/revisions/${revision.id}',
        );
      }
    } on ApiError catch (error) {
      if (cancelToken.isCancelled) return;
      if (mounted) {
        setState(() {
          _fieldErrors = _fieldErrorsFrom(error);
          _serverError = _nonFieldErrorFrom(error) ?? error.message;
        });
      }
    } catch (e) {
      if (cancelToken.isCancelled) return;
      if (mounted) {
        setState(() {
          _serverError = 'An unexpected error occurred. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final identity = auth is AuthAuthenticated ? auth.identity : null;

    if (identity == null || !canCreateQuestionRevisions(identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('New revision')),
        body: const Center(
          child: Text(
            'You do not have permission to create question revisions.',
          ),
        ),
      );
    }

    return PopScope(
      canPop: !_isDirty || _isSubmitting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('New revision')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_serverError != null) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _serverError!,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                CustomCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Revision settings',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Question Type
                      DropdownButtonFormField<String>(
                        initialValue: _questionType,
                        decoration: InputDecoration(
                          labelText: 'Question type *',
                          errorText: _fieldErrors['question_type'],
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'SINGLE_CHOICE',
                            child: Text('Single choice (Multiple choice)'),
                          ),
                          DropdownMenuItem(
                            value: 'TRUE_FALSE',
                            child: Text('True / False'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val == null) return;
                          setState(() {
                            _questionType = val;
                          });
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Prompt
                      TextFormField(
                        controller: _promptController,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: 'Question prompt *',
                          hintText: 'Enter the question text...',
                          errorText: _fieldErrors['prompt'],
                        ),
                        validator: (value) {
                          final v = value?.trim() ?? '';
                          if (v.isEmpty) {
                            return 'Question prompt is required.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Explanation
                      TextFormField(
                        controller: _explanationController,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: 'Explanation (optional)',
                          hintText: 'Explanation shown after assessment completion...',
                          errorText: _fieldErrors['explanation'],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.arrow_forward),
                  label: const Text('Create revision and configure options'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class QuestionFormScreen extends ConsumerStatefulWidget {
  final int? questionId;
  final ManagedQuestion? initialQuestion;

  const QuestionFormScreen({super.key, this.questionId, this.initialQuestion});

  @override
  ConsumerState<QuestionFormScreen> createState() => _QuestionFormScreenState();
}

class _QuestionFormScreenState extends ConsumerState<QuestionFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _codeController;
  late TextEditingController _topicController;
  late bool _isActive;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  bool _initialLoaded = false;
  String? _initialCode;
  String? _initialTopic;
  bool? _initialIsActive;

  late String _account;

  bool get _isEditing => widget.questionId != null;

  bool get _isDirty {
    if (!_initialLoaded) return false;
    final code = _codeController.text.trim();
    final topic = _topicController.text.trim();

    if (!_isEditing) {
      return code.isNotEmpty || topic.isNotEmpty || !_isActive;
    }

    return code != (_initialCode ?? '') ||
        topic != (_initialTopic ?? '') ||
        _isActive != _initialIsActive;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    _codeController = TextEditingController();
    _topicController = TextEditingController();
    _isActive = true;

    final initial = widget.initialQuestion;
    if (initial != null) {
      _populateFromQuestion(initial);
    } else if (!_isEditing) {
      _initialLoaded = true;
    }
  }

  void _populateFromQuestion(ManagedQuestion question) {
    _initialCode = question.code;
    _initialTopic = question.topic;
    _initialIsActive = question.isActive;

    _codeController.text = question.code;
    _topicController.text = question.topic;
    _isActive = question.isActive;
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('QuestionFormScreen disposed');
    _codeController.dispose();
    _topicController.dispose();
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
        title: const Text('Discard changes?'),
        content: const Text(
          'You have unsaved changes. Are you sure you want to discard them?',
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

    final code = _codeController.text.trim();
    final topic = _topicController.text.trim();

    try {
      ManagedQuestion savedQuestion;
      if (_isEditing) {
        savedQuestion = await ref
            .read(questionMutationProvider)
            .update(
              questionId: widget.questionId!,
              code: code,
              topic: topic,
              isActive: _isActive,
              cancelToken: cancelToken,
            );
        ref.invalidate(managedQuestionDetailProvider(widget.questionId!));
      } else {
        savedQuestion = await ref
            .read(questionMutationProvider)
            .create(
              code: code,
              topic: topic,
              isActive: _isActive,
              cancelToken: cancelToken,
            );
      }

      // Invalidate question bank lists
      ref.invalidate(managedQuestionsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditing ? 'Question updated successfully.' : 'Question created successfully with initial Draft Revision 1.',
            ),
          ),
        );
        if (_isEditing) {
          context.pop();
        } else {
          // Replace with the question detail screen so user can view/edit Revision 1
          context.pushReplacement(
            '/workspace/training/questions/${savedQuestion.id}',
            extra: savedQuestion,
          );
        }
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

    final permitted = _isEditing
        ? (identity != null && canAccessQuestionEditForm(identity))
        : (identity != null && canCreateQuestions(identity));

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit question' : 'Create question'),
        ),
        body: Center(
          child: Text(
            _isEditing
                ? 'You do not have permission to edit questions.'
                : 'You do not have permission to create questions.',
          ),
        ),
      );
    }

    if (_isEditing && !_initialLoaded) {
      final questionAsync = ref.watch(
        managedQuestionDetailProvider(widget.questionId!),
      );

      return questionAsync.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit question')),
          body: const Center(
            child: CardListSkeleton(message: 'Loading question...'),
          ),
        ),
        error: (error, _) => Scaffold(
          appBar: AppBar(title: const Text('Edit question')),
          body: ApiErrorView(
            error: error,
            onRetry: () => ref.refresh(
              managedQuestionDetailProvider(widget.questionId!).future,
            ),
          ),
        ),
        data: (question) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_initialLoaded) {
              setState(() {
                _populateFromQuestion(question);
              });
            }
          });
          return Scaffold(
            appBar: AppBar(title: const Text('Edit question')),
            body: const Center(
              child: CardListSkeleton(message: 'Initializing form...'),
            ),
          );
        },
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
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit question' : 'Create question'),
        ),
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
                        'Question metadata',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Code
                      TextFormField(
                        controller: _codeController,
                        maxLength: 40,
                        decoration: InputDecoration(
                          labelText: 'Question code *',
                          hintText: 'e.g. SEC-001',
                          errorText: _fieldErrors['code'],
                        ),
                        validator: (value) {
                          final v = value?.trim() ?? '';
                          if (v.isEmpty) return 'Question code is required.';
                          if (v.length > 40) {
                            return 'Code cannot exceed 40 characters.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Topic
                      TextFormField(
                        controller: _topicController,
                        maxLength: 120,
                        decoration: InputDecoration(
                          labelText: 'Topic (optional)',
                          hintText: 'e.g. Chemical Handling & Safety',
                          errorText: _fieldErrors['topic'],
                        ),
                        validator: (value) {
                          final v = value?.trim() ?? '';
                          if (v.length > 120) {
                            return 'Topic cannot exceed 120 characters.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Is Active
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Active status'),
                        subtitle: const Text(
                          'Only active questions can have frozen revisions attached to assessments.',
                        ),
                        value: _isActive,
                        onChanged: (val) {
                          setState(() {
                            _isActive = val;
                          });
                        },
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
                      : const Icon(Icons.save),
                  label: Text(_isEditing ? 'Save changes' : 'Create question'),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final shouldPop = await _onWillPop();
                          if (shouldPop && context.mounted) {
                            context.pop();
                          }
                        },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

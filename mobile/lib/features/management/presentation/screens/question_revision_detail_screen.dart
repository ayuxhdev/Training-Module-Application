import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/core/presentation/components/api_error_view.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/content_skeleton.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/empty_view.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';

class _DraftOptionItem {
  int? id;
  String text;
  int position;
  bool isCorrect;
  bool delete;

  _DraftOptionItem({
    this.id,
    required this.text,
    required this.position,
    required this.isCorrect,
    this.delete = false,
  });

  _DraftOptionItem clone() => _DraftOptionItem(
    id: id,
    text: text,
    position: position,
    isCorrect: isCorrect,
    delete: delete,
  );

  Map<String, dynamic>? toPayload() {
    if (id == null && delete) return null;
    return <String, dynamic>{
      if (id != null) 'id': id,
      if (delete)
        'delete': true
      else ...{
        'text': text,
        'position': position,
        'is_correct': isCorrect,
      },
    };
  }
}

class QuestionRevisionDetailScreen extends ConsumerStatefulWidget {
  final int questionId;
  final int revisionId;
  final ManagedQuestionRevisionSummary? initialSummary;

  const QuestionRevisionDetailScreen({
    super.key,
    required this.questionId,
    required this.revisionId,
    this.initialSummary,
  });

  @override
  ConsumerState<QuestionRevisionDetailScreen> createState() =>
      _QuestionRevisionDetailScreenState();
}

class _QuestionRevisionDetailScreenState
    extends ConsumerState<QuestionRevisionDetailScreen> {
  final _formKey = GlobalKey<FormState>();
  static const _initialDraftPrompt = 'Draft question';

  static String _normalizePrompt(String? prompt) {
    if (prompt == null) return '';
    return prompt
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .join(' ');
  }

  static bool _isPlaceholderPrompt(String? prompt) {
    if (prompt == null) return false;
    final normalized = _normalizePrompt(prompt);
    return normalized.toLowerCase() == _initialDraftPrompt.toLowerCase();
  }

  late TextEditingController _promptController;
  late TextEditingController _explanationController;
  late String _questionType;

  List<_DraftOptionItem> _options = [];
  bool _initialized = false;
  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  late String _account;

  String? _storedPrompt;
  bool _isDraftWithPlaceholder = false;
  String? _initialPrompt;
  String? _initialExplanation;
  String? _initialType;
  List<_DraftOptionItem> _initialOptions = [];

  bool get _isDirty {
    if (!_initialized) return false;
    if (_promptController.text.trim() != (_initialPrompt ?? '')) return true;
    if (_explanationController.text.trim() != (_initialExplanation ?? '')) {
      return true;
    }
    if (_questionType != _initialType) return true;
    if (_options.length != _initialOptions.length) return true;
    for (int i = 0; i < _options.length; i++) {
      final cur = _options[i];
      final init = _initialOptions[i];
      if (cur.id != init.id ||
          cur.text != init.text ||
          cur.position != init.position ||
          cur.isCorrect != init.isCorrect ||
          cur.delete != init.delete) {
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    _promptController = TextEditingController();
    _explanationController = TextEditingController();
    _questionType = 'SINGLE_CHOICE';
  }

  void _populateFromDetail(ManagedQuestionRevisionDetail detail) {
    if (_initialized) return;
    _storedPrompt = detail.prompt;
    final isPlaceholder = detail.isDraft && _isPlaceholderPrompt(detail.prompt);
    _isDraftWithPlaceholder = isPlaceholder;
    final displayPrompt = isPlaceholder ? '' : detail.prompt;
    _initialPrompt = displayPrompt;
    _initialExplanation = detail.explanation;
    _initialType = detail.questionType;

    _promptController.text = displayPrompt;
    _explanationController.text = detail.explanation;
    _questionType = detail.questionType;

    _options = detail.options
        .map(
          (opt) => _DraftOptionItem(
            id: opt.id,
            text: opt.text,
            position: opt.position,
            isCorrect: opt.isCorrect,
          ),
        )
        .toList();
    _initialOptions = _options.map((o) => o.clone()).toList();
    _initialized = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('QuestionRevisionDetailScreen disposed');
    _promptController.dispose();
    _explanationController.dispose();
    super.dispose();
  }

  String _formatOptionsError(dynamic raw) {
    if (raw is String) return raw.trim();
    if (raw is List) {
      final messages = <String>[];
      for (int i = 0; i < raw.length; i++) {
        final item = raw[i];
        if (item is String && item.trim().isNotEmpty) {
          messages.add(item.trim());
        } else if (item is Map) {
          for (final entry in item.entries) {
            final fName = entry.key.toString();
            final fVal = entry.value;
            final capitalized = fName.isEmpty
                ? fName
                : '${fName[0].toUpperCase()}${fName.substring(1)}';
            String msg = '';
            if (fVal is String) {
              msg = fVal.trim();
            } else if (fVal is List) {
              msg = fVal.map((e) => e.toString()).join(' ').trim();
            } else if (fVal != null) {
              msg = fVal.toString().trim();
            }
            if (msg.isNotEmpty) {
              messages.add('Option ${i + 1}: $capitalized: $msg');
            }
          }
        } else if (item != null && item.toString().trim().isNotEmpty) {
          messages.add(item.toString().trim());
        }
      }
      return messages.join('\n');
    }
    if (raw is Map) {
      final messages = <String>[];
      final nonField = raw['non_field_errors'] ?? raw['detail'];
      if (nonField is List) {
        messages.addAll(nonField.map((e) => e.toString().trim()));
      } else if (nonField is String && nonField.trim().isNotEmpty) {
        messages.add(nonField.trim());
      }
      for (final entry in raw.entries) {
        final k = entry.key.toString();
        if (k == 'non_field_errors' || k == 'detail') continue;
        final v = entry.value;
        String msg = '';
        if (v is String) {
          msg = v.trim();
        } else if (v is List) {
          msg = v.map((e) => e.toString()).join(' ').trim();
        } else if (v != null) {
          msg = v.toString().trim();
        }
        if (msg.isNotEmpty) {
          messages.add('$k: $msg');
        }
      }
      return messages.join('\n');
    }
    return '';
  }

  String _extractErrorMessage(ApiError error) {
    final details = error.details;
    if (details is Map) {
      final rawOptions =
          details['options'] ??
          (details['fields'] is Map
              ? (details['fields'] as Map)['options']
              : null);
      if (rawOptions != null) {
        final optionsError = _formatOptionsError(rawOptions);
        if (optionsError.isNotEmpty) {
          return optionsError;
        }
      }

      final nonField = details['non_field_errors'] ?? details['detail'];
      if (nonField is String && nonField.trim().isNotEmpty) {
        return nonField.trim();
      }
      if (nonField is List && nonField.isNotEmpty) {
        final joined = nonField.map((e) => e.toString()).join(' ').trim();
        if (joined.isNotEmpty) return joined;
      }

      final fieldMessages = <String>[];
      for (final entry in details.entries) {
        final key = entry.key.toString();
        if (key == 'non_field_errors' ||
            key == 'detail' ||
            key == 'options' ||
            key == 'fields') {
          continue;
        }
        final val = entry.value;
        if (val is String && val.trim().isNotEmpty) {
          fieldMessages.add('$key: ${val.trim()}');
        } else if (val is List && val.isNotEmpty) {
          final joined = val.map((e) => e.toString()).join(' ').trim();
          if (joined.isNotEmpty) fieldMessages.add('$key: $joined');
        }
      }
      if (fieldMessages.isNotEmpty) {
        return fieldMessages.join('\n');
      }
    }

    return error.message;
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

  void _showValidationError(String message) {
    if (!mounted) return;
    setState(() {
      _serverError = message;
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool _validateVisiblePromptBeforeFreeze() {
    if (!mounted) return false;
    final normalized = _normalizePrompt(_promptController.text);
    final promptValid =
        normalized.isNotEmpty && !_isPlaceholderPrompt(normalized);
    if (promptValid) {
      final hadPromptFieldError = _fieldErrors.containsKey('prompt');
      final hadPromptBanner = _serverError == 'Prompt is required.';
      if (hadPromptFieldError || hadPromptBanner) {
        setState(() {
          if (hadPromptFieldError) {
            _fieldErrors = Map<String, String>.from(_fieldErrors)
              ..remove('prompt');
          }
          if (hadPromptBanner) {
            _serverError = null;
          }
        });
        ScaffoldMessenger.of(context).clearSnackBars();
      }
      return true;
    }

    if (mounted) {
      setState(() {
        _fieldErrors = {..._fieldErrors, 'prompt': 'Prompt is required.'};
        _serverError = 'Prompt is required.';
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Prompt is required.')));
    }
    return false;
  }

  Future<bool> _saveChanges() async {
    if (_isSubmitting) return false;

    final auth = ref.read(authControllerProvider);
    final currentAccount = managementAccount(auth) ?? '';
    if (currentAccount != _account) {
      _showValidationError(
        'Account context changed. Please reload the revision to submit.',
      );
      return false;
    }

    if (!(_formKey.currentState?.validate() ?? false)) return false;

    final activeOptions = _options.where((o) => !o.delete).toList();
    for (int i = 0; i < activeOptions.length; i++) {
      final opt = activeOptions[i];
      if (opt.text.trim().isEmpty) {
        _showValidationError('Option ${i + 1} text cannot be empty.');
        return false;
      }
      if (opt.position < 1) {
        _showValidationError('Option ${i + 1} position must be at least 1.');
        return false;
      }
    }

    setState(() {
      _isSubmitting = true;
      _serverError = null;
      _fieldErrors = const {};
    });

    final cancelToken = CancelToken();
    _activeRequest = cancelToken;

    final optionsPayload = _options
        .map((o) => o.toPayload())
        .whereType<Map<String, dynamic>>()
        .toList();

    final String promptToSend;
    final visiblePrompt = _promptController.text.trim();
    if (_isDraftWithPlaceholder && visiblePrompt.isEmpty) {
      promptToSend = _storedPrompt ?? _initialDraftPrompt;
    } else {
      promptToSend = visiblePrompt;
    }

    try {
      await ref
          .read(questionRevisionMutationProvider)
          .update(
            questionId: widget.questionId,
            revisionId: widget.revisionId,
            questionType: _questionType,
            prompt: promptToSend,
            explanation: _explanationController.text.trim(),
            options: optionsPayload,
            cancelToken: cancelToken,
          );

      if (!mounted || cancelToken.isCancelled) return false;

      ref.invalidate(
        managedQuestionRevisionDetailProvider((
          questionId: widget.questionId,
          revisionId: widget.revisionId,
        )),
      );

      // Re-read to reset initial values
      final updated = await ref.read(
        managedQuestionRevisionDetailProvider((
          questionId: widget.questionId,
          revisionId: widget.revisionId,
        )).future,
      );

      if (!mounted || cancelToken.isCancelled) return false;

      setState(() {
        _initialized = false;
        _populateFromDetail(updated);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Revision saved successfully.')),
      );
      return true;
    } on ApiError catch (error) {
      if (cancelToken.isCancelled || !mounted) return false;
      final errorMsg = _extractErrorMessage(error);
      setState(() {
        _fieldErrors = _fieldErrorsFrom(error);
        _serverError = errorMsg;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorMsg)));
      return false;
    } catch (e) {
      if (cancelToken.isCancelled || !mounted) return false;
      const errorMsg = 'An unexpected error occurred. Please try again.';
      setState(() {
        _serverError = errorMsg;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text(errorMsg)));
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _confirmFreeze() async {
    if (_isSubmitting) return;

    final auth = ref.read(authControllerProvider);
    final currentAccount = managementAccount(auth) ?? '';
    if (currentAccount != _account) {
      _showValidationError(
        'Account context changed. Please reload the revision.',
      );
      return;
    }
    if (!_validateVisiblePromptBeforeFreeze()) return;

    const optionError =
        'A frozen question needs at least two options and exactly one correct option.';
    final activeOptions = _options.where((o) => !o.delete).toList();
    if (activeOptions.length < 2) {
      _showValidationError(optionError);
      return;
    }
    final correctCount = activeOptions.where((o) => o.isCorrect).length;
    if (correctCount != 1) {
      _showValidationError(optionError);
      return;
    }
    const trueFalseError =
        'True/false questions require exactly the True and False options.';
    if (_questionType == 'TRUE_FALSE') {
      final labels = activeOptions
          .map((o) => o.text.trim().toLowerCase())
          .toSet();
      if (labels.length != 2 ||
          !labels.contains('true') ||
          !labels.contains('false')) {
        _showValidationError(trueFalseError);
        return;
      }
    }

    if (_serverError == optionError || _serverError == trueFalseError) {
      setState(() {
        _serverError = null;
      });
      ScaffoldMessenger.of(context).clearSnackBars();
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Freeze revision?'),
        content: const Text(
          'Freezing permanently locks this revision so it can never be edited or deleted. It will be available to attach to assessments. This operation cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Freeze permanently'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    if (_isSubmitting) return;
    if (!_validateVisiblePromptBeforeFreeze()) return;

    // If dirty, save changes first
    if (_isDirty) {
      final saveSucceeded = await _saveChanges();
      if (!saveSucceeded || !mounted) return;
    }

    setState(() {
      _isSubmitting = true;
      _serverError = null;
      _fieldErrors = const {};
    });

    final cancelToken = CancelToken();
    _activeRequest = cancelToken;

    try {
      await ref
          .read(questionRevisionMutationProvider)
          .freeze(
            questionId: widget.questionId,
            revisionId: widget.revisionId,
            cancelToken: cancelToken,
          );

      if (!mounted || cancelToken.isCancelled) return;

      ref.invalidate(
        managedQuestionRevisionDetailProvider((
          questionId: widget.questionId,
          revisionId: widget.revisionId,
        )),
      );
      ref.invalidate(managedQuestionRevisionsProvider);

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Revision frozen successfully and locked permanently.'),
        ),
      );
    } on ApiError catch (error) {
      if (cancelToken.isCancelled || !mounted) return;
      final errorMsg = _extractErrorMessage(error);
      setState(() {
        _fieldErrors = _fieldErrorsFrom(error);
        _serverError = errorMsg;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(errorMsg)));
    } catch (e) {
      if (cancelToken.isCancelled || !mounted) return;
      const errorMsg =
          'An unexpected error occurred while freezing. Please try again.';
      setState(() {
        _serverError = errorMsg;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text(errorMsg)));
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _addOptionDialog([_DraftOptionItem? existing, int? index]) {
    final textCtrl = TextEditingController(text: existing?.text ?? '');
    final posCtrl = TextEditingController(
      text: existing != null
          ? existing.position.toString()
          : (_options.where((o) => !o.delete).length + 1).toString(),
    );
    bool isCorrect = existing?.isCorrect ?? false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(existing != null ? 'Edit option' : 'Add option'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: textCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Option text *',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: posCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Position *'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Is correct answer'),
                    value: isCorrect,
                    onChanged: (val) {
                      setDialogState(() {
                        isCorrect = val ?? false;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final text = textCtrl.text.trim();
                    final pos = int.tryParse(posCtrl.text.trim()) ?? 1;
                    if (text.isEmpty) return;

                    setState(() {
                      if (isCorrect) {
                        // For single choice / true-false, mark others false
                        for (final o in _options) {
                          o.isCorrect = false;
                        }
                      }
                      if (existing != null && index != null) {
                        existing.text = text;
                        existing.position = pos;
                        existing.isCorrect = isCorrect;
                      } else {
                        _options.add(
                          _DraftOptionItem(
                            text: text,
                            position: pos,
                            isCorrect: isCorrect,
                          ),
                        );
                      }
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Save option'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _setupTrueFalseOptions() {
    setState(() {
      _questionType = 'TRUE_FALSE';
      // Mark any existing options as delete
      for (final o in _options) {
        if (o.id != null) {
          o.delete = true;
        }
      }
      _options = [
        ..._options.where((o) => o.delete),
        _DraftOptionItem(text: 'True', position: 1, isCorrect: true),
        _DraftOptionItem(text: 'False', position: 2, isCorrect: false),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth is! AuthAuthenticated ||
        !canViewQuestionRevisions(auth.identity)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Revision details')),
        body: const Center(
          child: Text('You do not have permission to view question revisions.'),
        ),
      );
    }

    final identity = auth.identity;
    final revisionAsync = ref.watch(
      managedQuestionRevisionDetailProvider((
        questionId: widget.questionId,
        revisionId: widget.revisionId,
      )),
    );

    final loadedRevNumber =
        revisionAsync.asData?.value.revisionNumber ??
        widget.initialSummary?.revisionNumber;
    final titleText = loadedRevNumber != null
        ? 'Revision $loadedRevNumber'
        : 'Revision details';

    return Scaffold(
      appBar: AppBar(
        title: Text(titleText),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(
                managedQuestionRevisionDetailProvider((
                  questionId: widget.questionId,
                  revisionId: widget.revisionId,
                )),
              );
            },
          ),
        ],
      ),
      body: revisionAsync.when(
        loading: () => const Center(
          child: CardListSkeleton(
            message: 'Loading revision...',
            compact: true,
          ),
        ),
        error: (error, _) => ApiErrorView(
          error: error,
          onRetry: () {
            ref.invalidate(
              managedQuestionRevisionDetailProvider((
                questionId: widget.questionId,
                revisionId: widget.revisionId,
              )),
            );
          },
        ),
        data: (detail) {
          if (!_initialized) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _populateFromDetail(detail);
                });
              }
            });
          }

          final isFrozen = detail.isFrozen;
          final canEdit = !isFrozen && canEditQuestionRevisions(identity);
          final visibleOptions = _options.where((o) => !o.delete).toList();

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(
                managedQuestionRevisionDetailProvider((
                  questionId: widget.questionId,
                  revisionId: widget.revisionId,
                )),
              );
              await ref.read(
                managedQuestionRevisionDetailProvider((
                  questionId: widget.questionId,
                  revisionId: widget.revisionId,
                )).future,
              );
            },
            child: Form(
              key: _formKey,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  CinematicHero(
                    eyebrow: 'QUESTION REVISION',
                    title: 'Revision ${detail.revisionNumber}',
                    subtitle: isFrozen
                        ? 'Frozen revision · Immutable and ready for assessments'
                        : 'Draft revision · Edit prompt, explanation, and answer options',
                    icon: isFrozen
                        ? Icons.lock_outline
                        : Icons.edit_note_outlined,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusBadge(
                          text: detail.status,
                          status: isFrozen
                              ? BadgeStatus.info
                              : BadgeStatus.warning,
                        ),
                        StatusBadge(
                          text: detail.questionType,
                          status: BadgeStatus.neutral,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  if (_serverError != null) ...[
                    Container(
                      key: const ValueKey('revision-error-banner'),
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
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

                  if (isFrozen)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: CustomCard(
                        child: Row(
                          children: [
                            Icon(
                              Icons.verified_outlined,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            const Expanded(
                              child: Text(
                                'This revision is FROZEN. Answers and options are permanently locked and cannot be edited.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Prompt & Explanation Card
                  CustomCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Question content',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (canEdit) ...[
                          DropdownButtonFormField<String>(
                            isExpanded: true,
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
                          TextFormField(
                            controller: _promptController,
                            maxLines: 4,
                            decoration: InputDecoration(
                              labelText: 'Prompt *',
                              hintText: _initialDraftPrompt,
                              errorText: _fieldErrors['prompt'],
                            ),
                            validator: (v) {
                              final trimmed = v?.trim() ?? '';
                              if (trimmed.isEmpty) {
                                if (_isDraftWithPlaceholder) {
                                  return null;
                                }
                                return 'Prompt is required.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _explanationController,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: 'Explanation (optional)',
                              errorText: _fieldErrors['explanation'],
                            ),
                          ),
                        ] else ...[
                          Text(
                            'Prompt',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            detail.prompt,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          if (detail.explanation.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              'Explanation',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              detail.explanation,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),

                  // Options Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: SectionHeading(
                          'Answer options',
                          subtitle: 'Configure options and designate the authoritative correct answer.',
                        ),
                      ),
                      if (canEdit)
                        Wrap(
                          spacing: 4,
                          children: [
                            if (_questionType == 'TRUE_FALSE')
                              OutlinedButton(
                                onPressed: _setupTrueFalseOptions,
                                child: const Text('Preset T/F'),
                              ),
                            FilledButton.icon(
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Add option'),
                              onPressed: () => _addOptionDialog(),
                            ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  if (visibleOptions.isEmpty)
                    const EmptyView(
                      message: 'No options configured for this revision.',
                      icon: Icons.list_alt_outlined,
                    )
                  else
                    ...visibleOptions.map((opt) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: CustomCard(
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 14,
                                backgroundColor: opt.isCorrect
                                    ? Colors.green.withAlpha(50)
                                    : Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                child: opt.isCorrect
                                    ? const Icon(
                                        Icons.check,
                                        size: 16,
                                        color: Colors.green,
                                      )
                                    : Text(
                                        '${opt.position}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                              ),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      opt.text,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: opt.isCorrect
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                    ),
                                    Text(
                                      'Position ${opt.position} · ${opt.isCorrect ? "Correct answer" : "Incorrect"}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: opt.isCorrect
                                                ? Colors.green
                                                : Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              if (canEdit) ...[
                                IconButton(
                                  tooltip: 'Edit option',
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                  ),
                                  onPressed: () => _addOptionDialog(
                                    opt,
                                    _options.indexOf(opt),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove option',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: Colors.red,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      if (opt.id != null) {
                                        opt.delete = true;
                                      } else {
                                        _options.remove(opt);
                                      }
                                    });
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                  const SizedBox(height: AppSpacing.lg),

                  if (canEdit) ...[
                    FilledButton.icon(
                      onPressed: _isSubmitting ? null : () => _saveChanges(),
                      icon: const Icon(Icons.save),
                      label: const Text('Save draft changes'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blue.shade700,
                      ),
                      onPressed: _isSubmitting ? null : _confirmFreeze,
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Freeze revision permanently'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

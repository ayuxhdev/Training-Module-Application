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

class AssessmentQuestionFormScreen extends ConsumerStatefulWidget {
  final int versionId;
  final int assessmentId;
  final int? itemId;
  final ManagedAssessmentQuestion? initialItem;
  final int? suggestedPosition;

  const AssessmentQuestionFormScreen({
    super.key,
    required this.versionId,
    required this.assessmentId,
    this.itemId,
    this.initialItem,
    this.suggestedPosition,
  });

  @override
  ConsumerState<AssessmentQuestionFormScreen> createState() =>
      _AssessmentQuestionFormScreenState();
}

class _AssessmentQuestionFormScreenState
    extends ConsumerState<AssessmentQuestionFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _revisionIdController;
  late TextEditingController _positionController;
  late TextEditingController _pointsController;

  bool _isSubmitting = false;
  CancelToken? _activeRequest;
  String? _serverError;
  Map<String, String> _fieldErrors = const {};

  bool _initialLoaded = false;
  int? _initialRevisionId;
  int? _initialPosition;
  String? _initialPoints;

  late String _account;

  bool get _isEditing => widget.itemId != null;

  bool get _isDirty {
    if (!_initialLoaded) return false;
    final revId = int.tryParse(_revisionIdController.text.trim());
    final pos = int.tryParse(_positionController.text.trim());
    final pts = _pointsController.text.trim();

    if (!_isEditing) {
      return revId != null ||
          (pos != null && pos != (widget.suggestedPosition ?? 1)) ||
          pts != '1.00';
    }

    return revId != _initialRevisionId ||
        pos != _initialPosition ||
        pts != (_initialPoints ?? '1.00');
  }

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authControllerProvider);
    _account = managementAccount(auth) ?? '';

    _revisionIdController = TextEditingController();
    _positionController = TextEditingController(
      text: (widget.suggestedPosition ?? 1).toString(),
    );
    _pointsController = TextEditingController(text: '1.00');

    final initial = widget.initialItem;
    if (initial != null) {
      _populateFromItem(initial);
    } else if (!_isEditing) {
      _initialLoaded = true;
    }
  }

  void _populateFromItem(ManagedAssessmentQuestion item) {
    _initialRevisionId = item.questionRevisionId;
    _initialPosition = item.position;
    _initialPoints = item.points;

    _revisionIdController.text = item.questionRevisionId.toString();
    _positionController.text = item.position.toString();
    _pointsController.text = item.points;
    _initialLoaded = true;
  }

  @override
  void dispose() {
    _activeRequest?.cancel('AssessmentQuestionFormScreen disposed');
    _revisionIdController.dispose();
    _positionController.dispose();
    _pointsController.dispose();
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

    final revId = int.parse(_revisionIdController.text.trim());
    final position = int.parse(_positionController.text.trim());
    final points = double.tryParse(_pointsController.text.trim()) ?? 1.00;

    try {
      if (_isEditing) {
        await ref
            .read(assessmentQuestionMutationProvider)
            .update(
              versionId: widget.versionId,
              assessmentId: widget.assessmentId,
              itemId: widget.itemId!,
              questionRevisionId: revId,
              position: position,
              points: points,
              cancelToken: cancelToken,
            );
        ref.invalidate(
          managedAssessmentQuestionDetailProvider((
            versionId: widget.versionId,
            assessmentId: widget.assessmentId,
            itemId: widget.itemId!,
          )),
        );
      } else {
        await ref
            .read(assessmentQuestionMutationProvider)
            .create(
              versionId: widget.versionId,
              assessmentId: widget.assessmentId,
              questionRevisionId: revId,
              position: position,
              points: points,
              cancelToken: cancelToken,
            );
      }

      ref.invalidate(managedAssessmentQuestionsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditing
                  ? 'Question attachment updated successfully.'
                  : 'Question attached to assessment successfully.',
            ),
          ),
        );
        context.pop();
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

  void _showRevisionPicker() {
    final auth = ref.read(authControllerProvider);
    final identity = auth is AuthAuthenticated ? auth.identity : null;
    if (identity == null ||
        !canViewQuestions(identity) ||
        !canViewQuestionRevisions(identity)) {
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return _RevisionPickerSheet(
              scrollController: scrollController,
              onRevisionSelected: (revId) {
                setState(() {
                  _revisionIdController.text = revId.toString();
                });
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final identity = auth is AuthAuthenticated ? auth.identity : null;

    final permitted = _isEditing
        ? (identity != null && canAccessAssessmentQuestionEditForm(identity))
        : (identity != null && canCreateAssessmentQuestions(identity));
    final canBrowseQuestions =
        identity != null &&
        canViewQuestions(identity) &&
        canViewQuestionRevisions(identity);

    if (!permitted) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? 'Edit question' : 'Attach question'),
        ),
        body: Center(
          child: Text(
            _isEditing
                ? 'You do not have permission to edit assessment questions.'
                : 'You do not have permission to attach questions to assessments.',
          ),
        ),
      );
    }

    if (_isEditing && !_initialLoaded) {
      final itemAsync = ref.watch(
        managedAssessmentQuestionDetailProvider((
          versionId: widget.versionId,
          assessmentId: widget.assessmentId,
          itemId: widget.itemId!,
        )),
      );

      return itemAsync.when(
        loading: () => Scaffold(
          appBar: AppBar(title: const Text('Edit question attachment')),
          body: const Center(
            child: CardListSkeleton(message: 'Loading question attachment...'),
          ),
        ),
        error: (error, _) => Scaffold(
          appBar: AppBar(title: const Text('Edit question attachment')),
          body: ApiErrorView(
            error: error,
            onRetry: () => ref.refresh(
              managedAssessmentQuestionDetailProvider((
                versionId: widget.versionId,
                assessmentId: widget.assessmentId,
                itemId: widget.itemId!,
              )).future,
            ),
          ),
        ),
        data: (item) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_initialLoaded) {
              setState(() {
                _populateFromItem(item);
              });
            }
          });
          return Scaffold(
            appBar: AppBar(title: const Text('Edit question attachment')),
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
          title: Text(
            _isEditing ? 'Edit question attachment' : 'Attach question',
          ),
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
                        'Question attachment settings',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Only frozen revisions of active questions can be attached.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Revision ID
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _revisionIdController,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: 'Question revision ID *',
                                hintText: 'e.g. 42',
                                errorText:
                                    _fieldErrors['question_revision_id'] ??
                                    _fieldErrors['question_revision'],
                              ),
                              validator: (value) {
                                final v = int.tryParse(value?.trim() ?? '');
                                if (v == null || v < 1) {
                                  return 'Enter a valid question revision ID >= 1.';
                                }
                                return null;
                              },
                            ),
                          ),
                          if (canBrowseQuestions) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: IconButton.outlined(
                                tooltip: 'Browse question bank',
                                onPressed: _showRevisionPicker,
                                icon: const Icon(Icons.search),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Position
                      TextFormField(
                        controller: _positionController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Position in assessment *',
                          hintText: 'e.g. 1',
                          errorText: _fieldErrors['position'],
                        ),
                        validator: (value) {
                          final v = int.tryParse(value?.trim() ?? '');
                          if (v == null || v < 1) {
                            return 'Position must be an integer >= 1.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      // Points
                      TextFormField(
                        controller: _pointsController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Points *',
                          hintText: '1.00',
                          errorText: _fieldErrors['points'],
                        ),
                        validator: (value) {
                          final v = double.tryParse(value?.trim() ?? '');
                          if (v == null || v < 0.01) {
                            return 'Points must be a positive decimal >= 0.01.';
                          }
                          return null;
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
                  label: Text(_isEditing ? 'Save changes' : 'Attach question'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RevisionPickerSheet extends ConsumerStatefulWidget {
  final ScrollController scrollController;
  final ValueChanged<int> onRevisionSelected;

  const _RevisionPickerSheet({
    required this.scrollController,
    required this.onRevisionSelected,
  });

  @override
  ConsumerState<_RevisionPickerSheet> createState() =>
      _RevisionPickerSheetState();
}

class _RevisionPickerSheetState extends ConsumerState<_RevisionPickerSheet> {
  int _questionPage = 1;
  String? _searchQuery;
  final _searchController = TextEditingController();
  final Map<int, int> _revisionPages = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final identity = auth is AuthAuthenticated ? auth.identity : null;
    final canBrowse =
        identity != null &&
        canViewQuestions(identity) &&
        canViewQuestionRevisions(identity);

    if (!canBrowse) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Select active question revision'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: const Center(
          child: Text(
            'You do not have permission to browse the question bank.',
          ),
        ),
      );
    }

    final questionsAsync = ref.watch(
      managedQuestionsProvider((
        page: _questionPage,
        search: _searchQuery,
        isActive: true,
      )),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select active question revision'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search active questions...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          setState(() {
                            _searchController.clear();
                            _searchQuery = null;
                            _questionPage = 1;
                          });
                        },
                      )
                    : null,
                isDense: true,
              ),
              onSubmitted: (val) {
                final trimmed = val.trim();
                setState(() {
                  _searchQuery = trimmed.isEmpty ? null : trimmed;
                  _questionPage = 1;
                });
              },
            ),
          ),
          Expanded(
            child: questionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error loading questions: $e'),
                      const SizedBox(height: AppSpacing.sm),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                        onPressed: () => ref.refresh(
                          managedQuestionsProvider((
                            page: _questionPage,
                            search: _searchQuery,
                            isActive: true,
                          )).future,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              data: (page) {
                if (page.items.isEmpty) {
                  return const Center(
                    child: Text('No active questions found in bank.'),
                  );
                }
                return ListView.builder(
                  controller: widget.scrollController,
                  itemCount: page.items.length,
                  itemBuilder: (context, index) {
                    final question = page.items[index];
                    final revPageNum = _revisionPages[question.id] ?? 1;

                    return ExpansionTile(
                      title: Text(question.code),
                      subtitle: Text(
                        question.topic.isNotEmpty ? question.topic : 'No topic',
                      ),
                      children: [
                        Consumer(
                          builder: (context, ref, _) {
                            final revisionsAsync = ref.watch(
                              managedQuestionRevisionsProvider((
                                questionId: question.id,
                                page: revPageNum,
                              )),
                            );

                            return revisionsAsync.when(
                              loading: () => const Padding(
                                padding: EdgeInsets.all(AppSpacing.sm),
                                child: CircularProgressIndicator(),
                              ),
                              error: (err, _) => Padding(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                child: Column(
                                  children: [
                                    Text('Error: $err'),
                                    TextButton(
                                      onPressed: () => ref.refresh(
                                        managedQuestionRevisionsProvider((
                                          questionId: question.id,
                                          page: revPageNum,
                                        )).future,
                                      ),
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                ),
                              ),
                              data: (revPage) {
                                final frozen = revPage.items
                                    .where((r) => r.isFrozen)
                                    .toList();
                                return Column(
                                  children: [
                                    if (frozen.isEmpty)
                                      const ListTile(
                                        dense: true,
                                        title: Text(
                                          'No frozen revisions available (drafts cannot be attached)',
                                          style: TextStyle(
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      )
                                    else
                                      ...frozen.map((rev) {
                                        return ListTile(
                                          dense: true,
                                          leading: const Icon(
                                            Icons.lock_outline,
                                          ),
                                          title: Text(
                                            'Revision ${rev.revisionNumber} (${rev.questionType})',
                                          ),
                                          trailing: const Icon(Icons.check),
                                          onTap: () {
                                            widget.onRevisionSelected(rev.id);
                                            Navigator.of(context).pop();
                                          },
                                        );
                                      }),
                                    if (revPage.hasMore || revPageNum > 1)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.sm,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            TextButton.icon(
                                              icon: const Icon(
                                                Icons.chevron_left,
                                                size: 16,
                                              ),
                                              label: const Text(
                                                'Prev revs',
                                                style: TextStyle(fontSize: 12),
                                              ),
                                              onPressed: revPageNum > 1
                                                  ? () => setState(() {
                                                      _revisionPages[question
                                                              .id] =
                                                          revPageNum - 1;
                                                    })
                                                  : null,
                                            ),
                                            Text(
                                              'Revs p. $revPageNum',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall,
                                            ),
                                            TextButton.icon(
                                              icon: const Icon(
                                                Icons.chevron_right,
                                                size: 16,
                                              ),
                                              label: const Text(
                                                'Next revs',
                                                style: TextStyle(fontSize: 12),
                                              ),
                                              onPressed: revPage.hasMore
                                                  ? () => setState(() {
                                                      _revisionPages[question
                                                              .id] =
                                                          revPageNum + 1;
                                                    })
                                                  : null,
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          questionsAsync.maybeWhen(
            data: (page) {
              if (page.items.isEmpty) return const SizedBox.shrink();
              return SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Previous'),
                        onPressed: _questionPage > 1
                            ? () => setState(() => _questionPage--)
                            : null,
                      ),
                      Text(
                        'Page $_questionPage · ${page.count} total',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      TextButton.icon(
                        label: const Text('Next'),
                        icon: const Icon(Icons.chevron_right),
                        onPressed: page.hasMore
                            ? () => setState(() => _questionPage++)
                            : null,
                      ),
                    ],
                  ),
                ),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

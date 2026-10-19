import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/cinematic_components.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/features/assessments/presentation/widgets/assessment_choice.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/core/presentation/components/loading_view.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';
import 'package:training_app/features/assessments/presentation/controllers/assessment_controller.dart';

import 'assessment_overview_screen.dart';

class AssessmentAttemptScreen extends ConsumerStatefulWidget {
  final AssessmentTarget target;
  final int? attemptId;
  const AssessmentAttemptScreen({
    super.key,
    required this.target,
    this.attemptId,
  });

  @override
  ConsumerState<AssessmentAttemptScreen> createState() =>
      _AssessmentAttemptScreenState();
}

class _AssessmentAttemptScreenState
    extends ConsumerState<AssessmentAttemptScreen> {
  int _questionIndex = 0;
  bool _confirming = false;
  final _scroll = ScrollController(keepScrollOffset: false);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final controller = ref.read(
        assessmentAttemptProvider(widget.target).notifier,
      );
      if (widget.attemptId case final id?) {
        controller.loadAttempt(id);
      } else {
        controller.startOrResume();
      }
    });
  }

  Future<void> _submit(AssessmentState snapshot) async {
    if (_confirming || !snapshot.canSubmit) return;
    setState(() => _confirming = true);
    final provider = assessmentAttemptProvider(widget.target);
    final unanswered = snapshot.attempt!.questions
        .where((q) => snapshot.selectedAnswers[q.id] == null)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        icon: Icon(
          Icons.fact_check_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Submit assessment?'),
        content: Text(
          unanswered == 0
              ? 'Your answers will be scored by the server. Submitted answers cannot be changed.'
              : '$unanswered unanswered question${unanswered == 1 ? '' : 's'}. Unanswered questions receive no credit. Submit anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep working'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm submission'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    // A dialog must not submit a different account's or refreshed attempt.
    if (confirmed == true && identical(ref.read(provider), snapshot)) {
      await ref.read(provider.notifier).submit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = assessmentAttemptProvider(widget.target);
    final state = ref.watch(provider);
    ref.listen(provider, (previous, next) {
      if ((next.error != null && !identical(previous?.error, next.error)) ||
          (next.attempt?.summary.isClosed == true &&
              previous?.attempt?.summary.isClosed != true)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _scroll.hasClients &&
              identical(ref.read(provider), next)) {
            _scroll.jumpTo(0);
          }
        });
      }
    });
    final controller = ref.read(provider.notifier);
    final attempt = state.attempt;
    final busy = const {
      AssessmentPhase.loading,
      AssessmentPhase.starting,
      AssessmentPhase.submitting,
      AssessmentPhase.reconciling,
    }.contains(state.phase);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          attempt?.summary.isClosed == true
              ? 'Assessment result'
              : 'Assessment',
        ),
      ),
      body: busy
          ? LoadingView(
              message: state.phase == AssessmentPhase.reconciling
                  ? 'Checking submission with the server…'
                  : 'Loading assessment…',
            )
          : attempt == null
          ? SingleChildScrollView(
              child: ErrorView(
                title: 'Assessment unavailable',
                message: state.error?.message ?? 'Assessment unavailable. Return to training to check eligibility.',
                onRetry: state.phase == AssessmentPhase.unavailable
                    ? null
                    : controller.retry,
              ),
            )
          : ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              children: [
                if (state.error != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: CinematicNotice(
                      message: state.error!.message,
                      isError: true,
                      icon: Icons.error_outline_rounded,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (state.phase == AssessmentPhase.uncertain)
                            const Text(
                              'Submission is not confirmed. Check its status before trying again.',
                            ),
                          OutlinedButton(
                            onPressed: controller.retry,
                            child: const Text('Check attempt status'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (attempt.summary.isClosed)
                  _result(context, attempt)
                else if (attempt.questions.isEmpty)
                  const CinematicNotice(
                    message: 'No questions are available. Return to training and reload the assessment.',
                  )
                else
                  _questions(context, state),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => context.go(
                    '/learning/assignments/${widget.target.assignmentId}',
                  ),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back to training'),
                ),
              ],
            ),
    );
  }

  Widget _questions(BuildContext context, AssessmentState state) {
    final attempt = state.attempt!;
    final questions = [...attempt.questions]
      ..sort((a, b) => a.position.compareTo(b.position));
    final index = _questionIndex.clamp(0, questions.length - 1);
    final question = questions[index];
    final options = [...question.options]
      ..sort((a, b) => a.position.compareTo(b.position));
    final answered = questions
        .where((q) => state.selectedAnswers[q.id] != null)
        .length;
    final controller = ref.read(
      assessmentAttemptProvider(widget.target).notifier,
    );
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Attempt ${attempt.summary.attemptNumber}',
          style: theme.textTheme.titleLarge,
        ),
        if (attempt.summary.deadlineAt != null)
          _Deadline(summary: attempt.summary),
        const SizedBox(height: 16),
        Text(
          '$answered of ${questions.length} answered',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: answered / questions.length,
          semanticsLabel: 'Questions answered',
        ),
        const SizedBox(height: 16),
        CustomCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Question ${index + 1} of ${questions.length}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: .5,
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                header: true,
                child: Text(question.prompt, style: theme.textTheme.titleLarge),
              ),
              const SizedBox(height: 16),
              for (final option in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AssessmentChoice(
                    text: option.text,
                    selected: state.selectedAnswers[question.id] == option.id,
                    onPressed: state.canSubmit && !_confirming
                        ? () => controller.selectAnswer(question.id, option.id)
                        : null,
                  ),
                ),
              TextButton(
                onPressed:
                    state.canSubmit &&
                        state.selectedAnswers[question.id] != null &&
                        !_confirming
                    ? () => controller.selectAnswer(question.id, null)
                    : null,
                child: const Text('Clear answer'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: index > 0
                  ? () => setState(() => _questionIndex = index - 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Previous'),
            ),
            OutlinedButton.icon(
              onPressed: index < questions.length - 1
                  ? () => setState(() => _questionIndex = index + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: const Text('Next'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const CinematicNotice(
          message: 'Answers are held on this screen only until submitted. Leaving may discard unsubmitted choices.',
          icon: Icons.edit_note_rounded,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: state.canSubmit && !_confirming
              ? () => _submit(state)
              : null,
          icon: const Icon(Icons.check),
          label: const Text('Submit assessment'),
        ),
      ],
    );
  }

  Widget _result(BuildContext context, AssessmentAttempt attempt) {
    final summary = attempt.summary;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CinematicHero(
          eyebrow: 'Assessment result',
          title: attemptLabel(summary),
          subtitle: summary.passed == true
              ? 'Your result is confirmed. Take a moment to celebrate your progress.'
              : summary.status == AttemptStatus.submitted
              ? 'Review your recorded answers and check whether another attempt is available.'
              : 'Check eligibility and attempt history before continuing.',
          icon: summary.passed == true
              ? Icons.verified_outlined
              : Icons.assignment_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: StatusBadge(
                      text: attemptLabel(summary),
                      status: summary.passed == true
                          ? BadgeStatus.success
                          : summary.status == AttemptStatus.submitted
                          ? BadgeStatus.error
                          : BadgeStatus.warning,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Attempt ${summary.attemptNumber}',
                style: theme.textTheme.titleMedium,
              ),
              if (summary.scorePoints != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Score: ${summary.scorePoints} / ${summary.maximumPoints}',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              Text('Passing score: ${summary.passPercentageSnapshot}%'),
              if (summary.submittedAt != null)
                Text(
                  'Submitted: ${summary.submittedAt!.toLocal()}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => context.go(
                  '/learning/assignments/${widget.target.assignmentId}/assessments',
                ),
                child: const Text('Review eligibility and attempts'),
              ),
              if (attempt.certificateId != null)
                FilledButton.icon(
                  onPressed: () => context.push(
                    '/profile/certificates/${attempt.certificateId}',
                  ),
                  icon: const Icon(Icons.workspace_premium_outlined),
                  label: const Text('View certificate'),
                ),
            ],
          ),
        ),
        if (attempt.answers.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionHeading(
            'Submitted answers',
            subtitle: 'The responses recorded with this attempt.',
          ),
          for (final answer in [
            ...attempt.answers,
          ]..sort((a, b) => a.presentedPosition.compareTo(b.presentedPosition)))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CustomCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(answer.prompt, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Your answer: ${answer.selectedOptionText ?? 'Unanswered'}',
                    ),
                    if (answer.pointsAwarded != null)
                      Text(
                        'Points: ${answer.pointsAwarded} / ${answer.pointsPossible}',
                      ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _Deadline extends StatefulWidget {
  final AssessmentAttemptSummary summary;
  const _Deadline({required this.summary});
  @override
  State<_Deadline> createState() => _DeadlineState();
}

class _DeadlineState extends State<_Deadline> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = widget.summary.remainingAt(DateTime.now())!.inSeconds;
    return CinematicNotice(
      icon: Icons.schedule_rounded,
      message: seconds == 0
          ? 'Deadline reached. Submit to confirm the result with the server.'
          : 'Time remaining: ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
    );
  }
}

import 'package:flutter/material.dart';

import '../../../../core/presentation/formatters/date_labels.dart';
import '../../../../core/theme/cadence_theme.dart';
import '../../../../core/theme/cadence_tokens.dart';
import '../../domain/models/dashboard_data.dart';

/// An API-ordered assignment; never estimates lesson or watched progress.
class ContinueTrainingCard extends StatelessWidget {
  final DashboardAssignment assignment;
  final VoidCallback? onContinue;
  final bool isLoading;
  const ContinueTrainingCard({
    super.key,
    required this.assignment,
    required this.onContinue,
    this.isLoading = false,
  });
  @override
  Widget build(BuildContext context) {
    final stateLabel = switch (assignment.status) {
      'IN_PROGRESS' => 'In progress',
      'ASSIGNED' => 'Assigned',
      _ => assignment.status.replaceAll('_', ' '),
    };
    final largeText = MediaQuery.textScalerOf(context).scale(12) > 18;
    final compact = largeText || MediaQuery.sizeOf(context).width < 360;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CadenceTokens.deep,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'NEXT UP',
                  style: TextStyle(
                    color: CadenceTokens.mutedOnDark,
                    fontSize: 12,
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: CadenceTokens.primary,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    child: Text(
                      stateLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Semantics(
              header: true,
              child: Text(
                assignment.trainingTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text('Version ${assignment.versionNumber}', style: _metadata),
                Text(
                  assignment.dueAt == null
                      ? 'No deadline'
                      : 'Due ${assignmentDeadlineLabel(assignment.dueAt!)}',
                  style: _metadata,
                ),
                if (assignment.isOverdue)
                  const Text(
                    'Overdue',
                    style: TextStyle(
                      color: Color(0xFFF1C89D),
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: isLoading
                  ? CadenceTheme.inverseButtonStyle.copyWith(
                      backgroundColor: const WidgetStatePropertyAll(
                        Colors.white,
                      ),
                      foregroundColor: const WidgetStatePropertyAll(
                        CadenceTokens.deeper,
                      ),
                    )
                  : CadenceTheme.inverseButtonStyle,
              onPressed: isLoading ? null : onContinue,
              child: isLoading
                  ? Semantics(
                      label: 'Continue training',
                      value: 'Loading',
                      liveRegion: true,
                      child: ExcludeSemantics(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: MediaQuery.disableAnimationsOf(context)
                              ? const Icon(Icons.hourglass_empty, size: 20)
                              : const CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: CadenceTokens.deeper,
                                ),
                        ),
                      ),
                    )
                  : Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 10,
                      children: [
                        const Text(
                          'Continue training',
                          textAlign: TextAlign.center,
                        ),
                        if (!largeText)
                          const ExcludeSemantics(
                            child: Icon(Icons.arrow_forward, size: 20),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static const _metadata = TextStyle(
    color: CadenceTokens.onDark,
    fontSize: 14,
    height: 1.5,
  );
}

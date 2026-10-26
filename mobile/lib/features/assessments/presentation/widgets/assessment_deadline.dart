import 'dart:async';

import 'package:flutter/material.dart';
import 'package:training_app/core/presentation/components/cinematic_notice.dart';
import 'package:training_app/features/assessments/domain/models/assessment.dart';

/// Display-only countdown. Only the server may close or grade the attempt.
class AssessmentDeadline extends StatefulWidget {
  final AssessmentAttemptSummary summary;
  final DateTime Function()? now;
  const AssessmentDeadline({super.key, required this.summary, this.now});

  @override
  State<AssessmentDeadline> createState() => _AssessmentDeadlineState();
}

class _AssessmentDeadlineState extends State<AssessmentDeadline>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _seconds = 0, _announcedLevel = 0;
  bool _foreground = true;
  String? _announcement;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configure();
  }

  void _configure() {
    _timer?.cancel();
    _update();
    if (widget.summary.deadlineAt != null &&
        !widget.summary.isClosed &&
        _seconds > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(_update);
      });
    }
  }

  void _update() {
    final remaining = widget.summary.remainingAt(
      (widget.now ?? DateTime.now)(),
    );
    _seconds = remaining == null
        ? 0
        : (remaining.inMicroseconds / Duration.microsecondsPerSecond).ceil();
    if (_seconds == 0) _timer?.cancel();
    if (!_foreground ||
        widget.summary.deadlineAt == null ||
        widget.summary.isClosed) {
      return;
    }
    final level = _seconds == 0
        ? 3
        : _seconds <= 60
        ? 2
        : _seconds <= 120
        ? 1
        : 0;
    if (level <= _announcedLevel) return;
    _announcedLevel = level;
    _announcement = switch (level) {
      1 => '2 minutes or less remaining.',
      2 => '1 minute or less remaining.',
      _ => 'Deadline reached. Submit to confirm the result with the server.',
    };
  }

  @override
  void didUpdateWidget(AssessmentDeadline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary.id != widget.summary.id) {
      _announcedLevel = 0;
      _announcement = null;
    }
    _configure();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) setState(_update);
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.summary.deadlineAt == null || widget.summary.isClosed) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CinematicNotice(
            announce:
                false, // Exact visual time is readable, never live per tick.
            icon: _seconds <= 60 ? Icons.alarm_rounded : Icons.schedule_rounded,
            isError: _seconds <= 60,
            message: _seconds == 0
                ? 'Deadline reached. Submit to confirm the result with the server.'
                : 'Time remaining: ${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}',
          ),
          Semantics(
            container: true,
            liveRegion: true,
            label: _announcement,
            // A nonzero bound keeps this status in the platform semantics tree.
            child: const SizedBox(height: 1),
          ),
        ],
      ),
    );
  }
}

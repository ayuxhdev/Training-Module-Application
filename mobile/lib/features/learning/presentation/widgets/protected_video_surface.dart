import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Presentation only. Media position is never used as completion evidence.
class ProtectedVideoSurface extends StatefulWidget {
  final VideoPlayerController? controller;
  final bool busy, controlsVisible, canPlay, canSeek, fullscreen;
  final VoidCallback onToggleControls, onTogglePlayback;
  final VoidCallback? onFullscreen, onBack;
  final ValueChanged<double> onSeek;
  final ValueChanged<bool> onScrubbingChanged;
  final ValueChanged<bool>? onControlsFocusChanged;
  final VoidCallback? onRevealControls;
  final String loadingLabel;
  final String? statusLabel, title, message;
  final double coveragePercent, resumePosition;
  final int? videoDurationSeconds;
  final bool completed;
  final List<List<double>> watchedRanges;

  const ProtectedVideoSurface({
    super.key,
    this.controller,
    required this.busy,
    required this.controlsVisible,
    required this.canPlay,
    required this.canSeek,
    required this.fullscreen,
    required this.onToggleControls,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onScrubbingChanged,
    this.onControlsFocusChanged,
    this.onRevealControls,
    this.loadingLabel = 'Preparing video',
    this.statusLabel,
    this.onFullscreen,
    this.onBack,
    this.title,
    this.message,
    this.coveragePercent = 0,
    this.resumePosition = 0,
    this.videoDurationSeconds,
    this.completed = false,
    this.watchedRanges = const [],
  });

  @override
  State<ProtectedVideoSurface> createState() => _ProtectedVideoSurfaceState();
}

class _ProtectedVideoSurfaceState extends State<ProtectedVideoSurface> {
  static const _emerald = Color(0xff2dd4bf);
  final _playbackFocus = FocusNode(debugLabel: 'Video playback action');
  double? _scrub;
  bool _keyboardFocus = false;

  @override
  void dispose() {
    _playbackFocus.dispose();
    super.dispose();
  }

  String _time(double seconds) {
    final total = seconds.floor();
    final minutes = (total ~/ 60 % 60).toString().padLeft(2, '0');
    final remaining = (total % 60).toString().padLeft(2, '0');
    return total >= 3600
        ? '${total ~/ 3600}:$minutes:$remaining'
        : '${total ~/ 60}:$remaining';
  }

  String _status(VideoPlayerValue value) {
    if (widget.statusLabel != null) return widget.statusLabel!;
    if (widget.busy) return widget.loadingLabel;
    if (!widget.canPlay) return 'Video unavailable';
    if (value.isBuffering) return 'Buffering';
    if (value.isPlaying) return 'Playing';
    if (value.isCompleted) return 'Playback finished';
    return value.isInitialized ? 'Paused' : 'Ready to play';
  }

  Widget _chip(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xe00d1520),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: _emerald.withValues(alpha: .25)),
    ),
    child: child,
  );

  Widget _hud(VideoPlayerValue value) => Row(
    children: [
      if (widget.fullscreen && widget.onBack != null)
        IconButton(
          tooltip: 'Exit fullscreen',
          onPressed: widget.onBack,
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            backgroundColor: const Color(0xb30d1520),
          ),
          icon: const Icon(Icons.arrow_back),
        ),
      if (widget.fullscreen && widget.title != null) ...[
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
      ],
      Flexible(
        child: _chip(
          Text(
            widget.completed
                ? 'Completed'
                : '${widget.coveragePercent.toStringAsFixed(0)}% watched',
            style: const TextStyle(
              color: _emerald,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      if (!widget.fullscreen) const Spacer(),
      const SizedBox(width: 8),
      Flexible(
        child: Semantics(
          liveRegion: !value.isPlaying,
          child: Text(
            _status(value),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xffcbd5e1), fontSize: 11),
          ),
        ),
      ),
    ],
  );

  Widget _deck(
    double duration,
    double position,
    double rowHeight,
    bool central,
  ) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Container(
        key: const ValueKey('floating-control-deck'),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xe0131e2c), Color(0xf0080d14)],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: .15)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(1),
              child: Semantics(
                container: true,
                label: 'Playback position',
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: 8,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 20,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: .12),
                    thumbColor: _emerald,
                  ),
                  child: Slider(
                    value: (_scrub ?? position).clamp(
                      0.0,
                      math.max(duration, 1),
                    ),
                    max: math.max(duration, 1),
                    semanticFormatterCallback: (seconds) =>
                        '${_time(seconds)} of ${_time(duration)}',
                    onChanged: widget.canSeek && !widget.busy
                        ? (v) => setState(() => _scrub = v)
                        : null,
                    onChangeStart: (_) => widget.onScrubbingChanged(true),
                    onChangeEnd: (v) {
                      setState(() => _scrub = null);
                      widget.onScrubbingChanged(false);
                      widget.onSeek(v);
                    },
                  ),
                ),
              ),
            ),
            ExcludeSemantics(
              child: IgnorePointer(
                child: CustomPaint(
                  key: const ValueKey('watched-ranges'),
                  size: const Size(double.infinity, 3),
                  painter: _WatchedRangesPainter(
                    widget.watchedRanges,
                    duration,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: rowHeight,
              child: Row(
                children: [
                  if (!central) const SizedBox(width: 60),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: _time(_scrub ?? position),
                            style: TextStyle(
                              color: _scrub == null ? Colors.white : _emerald,
                            ),
                          ),
                          const TextSpan(
                            text: ' / ',
                            style: TextStyle(color: Color(0xff64748b)),
                          ),
                          TextSpan(
                            text: _time(duration),
                            style: const TextStyle(color: Color(0xff94a3b8)),
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (widget.onFullscreen != null)
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(3),
                      child: IconButton(
                        tooltip: widget.fullscreen
                            ? 'Exit fullscreen'
                            : 'Fullscreen',
                        onPressed: widget.onFullscreen,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          backgroundColor: Colors.white.withValues(alpha: .06),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: .12),
                          ),
                        ),
                        icon: Icon(
                          widget.fullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _surface(BuildContext context, VideoPlayerValue value) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final duration = value.isInitialized
        ? value.duration.inMilliseconds / 1000
        : (widget.videoDurationSeconds ?? 0).toDouble();
    final position = value.isInitialized
        ? value.position.inMilliseconds / 1000
        : widget.resumePosition;
    final action = value.isPlaying
        ? 'Pause'
        : position > 0
        ? 'Resume video'
        : 'Play';

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = widget.fullscreen
            ? constraints.maxWidth
            : math.min(constraints.maxWidth, 1100.0);
        final aspect = value.isInitialized ? value.aspectRatio : 16 / 9;
        final height = widget.fullscreen
            ? constraints.maxHeight
            : math.min(constraints.maxHeight, math.max(260.0, width / aspect));
        final inset = height < 280
            ? 8.0
            : widget.fullscreen
            ? 20.0
            : 12.0;
        final rowHeight = math.max(
          48.0,
          MediaQuery.textScalerOf(context).scale(12) * 2.8,
        );
        final deckHeight = 56 + 3 + 4 + rowHeight + 14;
        final hudHeight = math.max(
          48.0,
          MediaQuery.textScalerOf(context).scale(11) * 2 + 12,
        );
        final centerTop = inset + hudHeight + 8;
        final centerSpace = height - inset - deckHeight - 8 - centerTop;
        final central =
            !value.isPlaying &&
            !widget.busy &&
            !value.isBuffering &&
            widget.message == null &&
            centerSpace >= 48;
        final size = central
            ? math.min(widget.fullscreen ? 76.0 : 64.0, centerSpace)
            : 48.0;
        final actionTop = central
            ? centerTop + (centerSpace - size) / 2
            : height - inset - 9 - rowHeight / 2 - size / 2;

        final overlays = ExcludeFocus(
          excluding: !widget.controlsVisible,
          child: ExcludeSemantics(
            excluding: !widget.controlsVisible,
            child: IgnorePointer(
              ignoring: !widget.controlsVisible,
              child: AnimatedOpacity(
                opacity: widget.controlsVisible ? 1 : 0,
                duration: motion,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0xb304070a),
                                Color(0x0004070a),
                                Color(0xe604070a),
                              ],
                              stops: [0, .45, 1],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.message == null &&
                        height >= deckHeight + inset * 2 + hudHeight + 8)
                      Positioned(
                        top: inset,
                        left: inset,
                        right: inset,
                        child: _hud(value),
                      ),
                    Positioned(
                      left: inset,
                      right: inset,
                      bottom: inset,
                      child: _deck(duration, position, rowHeight, central),
                    ),
                    AnimatedPositioned(
                      duration: motion,
                      curve: Curves.easeOutCubic,
                      left: central ? (width - size) / 2 : inset + 13,
                      top: actionTop,
                      width: size,
                      height: size,
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: _emerald.withValues(alpha: .15),
                                blurRadius: 24,
                              ),
                            ],
                          ),
                          child: IconButton(
                            key: const ValueKey('video-playback-action'),
                            focusNode: _playbackFocus,
                            tooltip: action,
                            onPressed: !widget.busy && widget.canPlay
                                ? widget.onTogglePlayback
                                : null,
                            style: ButtonStyle(
                              animationDuration: motion,
                              minimumSize: const WidgetStatePropertyAll(
                                Size(48, 48),
                              ),
                              shape: const WidgetStatePropertyAll(
                                CircleBorder(),
                              ),
                              backgroundColor: WidgetStatePropertyAll(
                                central
                                    ? const Color(0xe00d1520)
                                    : const Color(0xd906382d),
                              ),
                              foregroundColor: WidgetStatePropertyAll(
                                central ? Colors.white : _emerald,
                              ),
                              side: WidgetStateProperty.resolveWith(
                                (states) => BorderSide(
                                  color: states.contains(WidgetState.focused)
                                      ? _emerald
                                      : Colors.white24,
                                  width: states.contains(WidgetState.focused)
                                      ? 2
                                      : 1,
                                ),
                              ),
                            ),
                            icon: AnimatedSwitcher(
                              duration: motion,
                              child: Icon(
                                value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow_rounded,
                                key: ValueKey(value.isPlaying),
                                size: central ? 32 : 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        return Align(
          alignment: widget.fullscreen ? Alignment.center : Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onToggleControls,
              child: MouseRegion(
                onHover: (_) => widget.onRevealControls?.call(),
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onFocusChange: widget.onControlsFocusChanged,
                    child: FocusTraversalOrder(
                      order: const NumericFocusOrder(0),
                      child: FocusableActionDetector(
                        onShowFocusHighlight: (focused) {
                          setState(() => _keyboardFocus = focused);
                          if (focused) widget.onRevealControls?.call();
                        },
                        actions: {
                          ActivateIntent: CallbackAction<ActivateIntent>(
                            onInvoke: (_) {
                              widget.onRevealControls?.call();
                              return null;
                            },
                          ),
                        },
                        child: Container(
                          key: const ValueKey('cinematic-video-stage'),
                          decoration: BoxDecoration(
                            color: const Color(0xff04070a),
                            borderRadius: BorderRadius.circular(
                              widget.fullscreen ? 0 : 16,
                            ),
                            border: Border.all(
                              color: _keyboardFocus
                                  ? _emerald
                                  : Colors.white.withValues(alpha: .1),
                              width: _keyboardFocus ? 2 : 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xff10b981)
                                    .withValues(alpha: .12),
                                blurRadius: 48,
                                spreadRadius: 6,
                              ),
                              const BoxShadow(
                                color: Colors.black54,
                                blurRadius: 24,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (widget.controller != null &&
                                  value.isInitialized)
                                Center(
                                  child: AspectRatio(
                                    aspectRatio: value.aspectRatio,
                                    child: VideoPlayer(widget.controller!),
                                  ),
                                ),
                              if (widget.busy || value.isBuffering)
                                Positioned.fill(
                                  bottom: deckHeight + inset,
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      semanticsLabel: value.isBuffering
                                          ? 'Buffering video'
                                          : widget.loadingLabel,
                                    ),
                                  ),
                                ),
                              overlays,
                              if (widget.message != null)
                                Positioned(
                                  top: inset,
                                  left: inset,
                                  right: inset,
                                  bottom: math.min(
                                    height - inset - 1,
                                    deckHeight + inset + 8,
                                  ),
                                  child: Center(
                                    child: SingleChildScrollView(
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: const Color(0xf0302026),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: const Color(0xff895460),
                                          ),
                                        ),
                                        child: Semantics(
                                          liveRegion: true,
                                          child: Text(
                                            widget.message!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Color(0xffffdce1),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return _surface(context, const VideoPlayerValue(duration: Duration.zero));
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => _surface(context, value),
    );
  }
}

/// Draw each confirmed interval independently; gaps must remain visibly unwatched.
class _WatchedRangesPainter extends CustomPainter {
  final List<List<double>> ranges;
  final double duration;
  const _WatchedRangesPainter(this.ranges, this.duration);

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final paint = Paint()..color = const Color(0xff2dd4bf);
    for (final range in ranges) {
      final start = range[0].clamp(0, duration) / duration * size.width;
      final end = range[1].clamp(0, duration) / duration * size.width;
      if (end > start) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(start, 0, end, size.height),
            const Radius.circular(2),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_WatchedRangesPainter old) =>
      old.ranges != ranges || old.duration != duration;
}

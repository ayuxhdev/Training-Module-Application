import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Presentation only. Media position is never used as completion evidence.
class ProtectedVideoSurface extends StatefulWidget {
  final VideoPlayerController? controller;
  final bool busy, controlsVisible, canPlay, canSeek, fullscreen;
  final VoidCallback onToggleControls, onTogglePlayback;
  final VoidCallback? onFullscreen;
  final ValueChanged<double> onSeek;
  final ValueChanged<bool> onScrubbingChanged;
  final ValueChanged<bool>? onControlsFocusChanged;
  final VoidCallback? onRevealControls;
  final String loadingLabel;
  final String? statusLabel;
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
  });

  @override
  State<ProtectedVideoSurface> createState() => _ProtectedVideoSurfaceState();
}

class _ProtectedVideoSurfaceState extends State<ProtectedVideoSurface> {
  double? _scrub;
  bool _keyboardFocus = false;
  String _time(double seconds) {
    final total = seconds.floor();
    if (total >= 3600) {
      return '${total ~/ 3600}:${(total ~/ 60 % 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
    }
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  Widget _controls(VideoPlayerValue value, Duration motion) {
    final duration = value.duration.inMilliseconds / 1000;
    final position = value.position.inMilliseconds / 1000;
    final colors = Theme.of(context).colorScheme;
    final status =
        widget.statusLabel ??
        (widget.busy
            ? widget.loadingLabel
            : !widget.canPlay
            ? 'Video unavailable'
            : value.isBuffering
            ? 'Buffering'
            : value.isPlaying
            ? 'Playing'
            : value.isCompleted
            ? 'Playback finished'
            : value.isInitialized
            ? 'Paused'
            : 'Ready to play');
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: .97),
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _time(_scrub ?? position),
                style: TextStyle(
                  color: _scrub == null ? colors.onSurface : colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                _time(duration),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          Semantics(
            container: true,
            label: 'Playback position',
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                padding: const EdgeInsets.symmetric(vertical: 8),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
                activeTrackColor: colors.primary,
                inactiveTrackColor: colors.outlineVariant,
                thumbColor: colors.primary,
              ),
              child: Slider(
                semanticFormatterCallback: (seconds) =>
                    '${_time(seconds)} of ${_time(duration)}',
                value: (_scrub ?? position).clamp(0.0, math.max(duration, 1)),
                max: math.max(duration, 1),
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
          Row(
            children: [
              FilledButton.icon(
                style: ButtonStyle(
                  animationDuration: motion,
                  minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                  shadowColor: const WidgetStatePropertyAll(Colors.black),
                  side: WidgetStateProperty.resolveWith(
                    (states) => BorderSide(
                      color: states.contains(WidgetState.focused)
                          ? colors.onSurface
                          : colors.primary.withValues(alpha: .4),
                      width: states.contains(WidgetState.focused) ? 2 : 1,
                    ),
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  elevation: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.pressed) ? 1 : 5,
                  ),
                ),
                onPressed: !widget.busy && widget.canPlay
                    ? widget.onTogglePlayback
                    : null,
                icon: AnimatedSwitcher(
                  duration: motion,
                  child: Icon(
                    value.isPlaying ? Icons.pause : Icons.play_arrow,
                    key: ValueKey(value.isPlaying),
                  ),
                ),
                label: Text(value.isPlaying ? 'Pause' : 'Play'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: !value.isPlaying,
                  child: Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
              if (widget.onFullscreen != null)
                IconButton.filledTonal(
                  tooltip: widget.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: widget.onFullscreen,
                  icon: Icon(
                    widget.fullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _surface(BuildContext context, VideoPlayerValue value) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final colors = Theme.of(context).colorScheme;
    final controls = ExcludeFocus(
      excluding: !widget.controlsVisible,
      child: ExcludeSemantics(
        excluding: !widget.controlsVisible,
        child: IgnorePointer(
          ignoring: !widget.controlsVisible,
          child: AnimatedOpacity(
            opacity: widget.controlsVisible ? 1 : 0,
            duration: motion,
            child: _controls(value, motion),
          ),
        ),
      ),
    );
    final stage = ColoredBox(
      color: const Color(0xff06090f),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.controller != null && value.isInitialized)
            Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: VideoPlayer(widget.controller!),
              ),
            )
          else if (!widget.busy)
            Icon(Icons.play_circle_outline, size: 64, color: colors.outline),
          if (widget.busy || value.isBuffering)
            Center(
              child: CircularProgressIndicator(
                semanticsLabel: value.isBuffering
                    ? 'Buffering video'
                    : widget.loadingLabel,
              ),
            ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = widget.fullscreen
            ? constraints.maxWidth
            : math.min(constraints.maxWidth, 1100.0);
        final aspect = value.isInitialized ? value.aspectRatio : 16 / 9;
        final height = widget.fullscreen
            ? constraints.maxHeight
            : math.min(constraints.maxHeight, width / aspect + 144);
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: widget.onToggleControls,
              child: MouseRegion(
                onHover: (_) => widget.onRevealControls?.call(),
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onFocusChange: widget.onControlsFocusChanged,
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
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(
                          widget.fullscreen ? 0 : 16,
                        ),
                        border: Border.all(
                          color: _keyboardFocus
                              ? colors.primary
                              : colors.outlineVariant,
                          width: _keyboardFocus ? 2 : 1,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black45,
                            blurRadius: 28,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: widget.fullscreen
                          ? Stack(
                              children: [
                                Positioned.fill(child: stage),
                                Align(
                                  alignment: Alignment.bottomCenter,
                                  child: controls,
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                Expanded(child: stage),
                                controls,
                              ],
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

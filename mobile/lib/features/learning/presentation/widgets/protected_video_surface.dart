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
    this.onFullscreen,
  });

  @override
  State<ProtectedVideoSurface> createState() => _ProtectedVideoSurfaceState();
}

class _ProtectedVideoSurfaceState extends State<ProtectedVideoSurface> {
  double? _scrub;
  String _time(double seconds) {
    final total = seconds.floor();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  Widget _controls(VideoPlayerValue value, Duration motion) {
    final duration = value.duration.inMilliseconds / 1000;
    final position = value.position.inMilliseconds / 1000;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00141e2c), Color(0xee141e2c)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            semanticFormatterCallback: _time,
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
          Row(
            children: [
              FilledButton.tonalIcon(
                style: ButtonStyle(
                  animationDuration: motion,
                  minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                  shadowColor: const WidgetStatePropertyAll(Colors.black),
                  side: const WidgetStatePropertyAll(
                    BorderSide(color: Colors.white24),
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  elevation: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.pressed) ? 1 : 4,
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
              Expanded(child: Text('${_time(position)} / ${_time(duration)}')),
              if (widget.onFullscreen != null)
                IconButton(
                  tooltip: widget.fullscreen ? 'Exit fullscreen' : 'Fullscreen',
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: AspectRatio(
          aspectRatio: value.isInitialized ? value.aspectRatio : 16 / 9,
          child: GestureDetector(
            onTap: widget.onToggleControls,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.controller != null && value.isInitialized)
                    VideoPlayer(widget.controller!),
                  if (widget.busy || value.isBuffering)
                    const Center(
                      child: CircularProgressIndicator(
                        semanticsLabel: 'Loading video',
                      ),
                    ),
                  ExcludeFocus(
                    excluding: !widget.controlsVisible,
                    child: ExcludeSemantics(
                      excluding: !widget.controlsVisible,
                      child: IgnorePointer(
                        ignoring: !widget.controlsVisible,
                        child: AnimatedOpacity(
                          opacity: widget.controlsVisible ? 1 : 0,
                          duration: motion,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: _controls(value, motion),
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

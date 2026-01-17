import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../providers/api_provider.dart';

class RenderedVideoTrimmerDialog extends StatefulWidget {
  final String videoPath; // Kept for compatibility, not used
  final String fileName;
  final Function(double startTime, double endTime) onConfirm;
  final double? duration;
  final int? totalFrames;
  final double? fps;

  const RenderedVideoTrimmerDialog({
    super.key,
    required this.videoPath,
    required this.fileName,
    required this.onConfirm,
    this.duration,
    this.totalFrames,
    this.fps,
  });

  @override
  State<RenderedVideoTrimmerDialog> createState() =>
      _RenderedVideoTrimmerDialogState();
}

class _RenderedVideoTrimmerDialogState
    extends State<RenderedVideoTrimmerDialog> {
  late double _duration;
  late int _totalFrames;
  late double _fps;

  double _startTime = 0.0;
  double _endTime = 0.0;
  double _currentPosition = 0.0;
  
  // Playback state
  bool _isPlaying = false;
  Timer? _playbackTimer;

  @override
  void initState() {
    super.initState();
    _duration = widget.duration ?? 10.0;
    _totalFrames = widget.totalFrames ?? 200;
    _fps = widget.fps ?? 20.0;
    _endTime = _duration;
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  void _togglePlayPause() {
    setState(() {
      _isPlaying = !_isPlaying;
    });

    if (_isPlaying) {
      // Start playback timer
      final frameDuration = Duration(milliseconds: (1000 / _fps).round());
      _playbackTimer = Timer.periodic(frameDuration, (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        
        setState(() {
          _currentPosition += 1 / _fps;
          if (_currentPosition >= _duration) {
            _currentPosition = 0.0; // Loop
          }
        });
      });
    } else {
      // Stop playback
      _playbackTimer?.cancel();
      _playbackTimer = null;
    }
  }

  void _seekToPosition(double seconds) {
    setState(() {
      _currentPosition = seconds.clamp(0.0, _duration);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.75,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Trim Rendered Video',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.fileName,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const Divider(),

            // Video preview with frame playback
            Expanded(
              child: Column(
                children: [
                  // Frame viewer
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: _RenderedVideoFrameViewer(
                          fileName: widget.fileName,
                          currentPosition: _currentPosition,
                          fps: _fps,
                          totalFrames: _totalFrames,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Video info
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            const Text('Frames', style: TextStyle(fontSize: 12)),
                            Text('$_totalFrames', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Column(
                          children: [
                            const Text('FPS', style: TextStyle(fontSize: 12)),
                            Text('${_fps.toStringAsFixed(1)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Column(
                          children: [
                            const Text('Duration', style: TextStyle(fontSize: 12)),
                            Text(_formatDuration(_duration), style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            const Divider(),

            // Timeline controls
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Current position display
                Row(
                  children: [
                    IconButton(
                      icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: _togglePlayPause,
                    ),
                    Expanded(
                      child: Slider(
                        value: _currentPosition,
                        min: 0,
                        max: _duration,
                        onChanged: (value) {
                          _seekToPosition(value);
                        },
                      ),
                    ),
                    Text(
                      _formatDuration(_currentPosition),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // Trim controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Trim Video',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Reset'),
                      onPressed: () {
                        setState(() {
                          _startTime = 0.0;
                          _endTime = _duration;
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 50, child: Text('Start:')),
                    Expanded(
                      child: Slider(
                        value: _startTime,
                        min: 0,
                        max: _endTime,
                        onChanged: (value) {
                          setState(() {
                            _startTime = value;
                            if (_startTime >= _endTime) {
                              _endTime = _startTime + 0.1;
                            }
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(_formatDuration(_startTime)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 50, child: Text('End:')),
                    Expanded(
                      child: Slider(
                        value: _endTime,
                        min: _startTime,
                        max: _duration,
                        onChanged: (value) {
                          setState(() {
                            _endTime = value;
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(_formatDuration(_endTime)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    'Duration: ${_formatDuration(_endTime - _startTime)}',
                    style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onConfirm(_startTime, _endTime);
                  },
                  child: const Text('Trim'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).toInt());
    final minutes = duration.inMinutes;
    final secs = duration.inSeconds % 60;
    final millis = (duration.inMilliseconds % 1000) ~/ 100;
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.${millis}';
  }
}

// Frame viewer widget that fetches and displays frames from the API
class _RenderedVideoFrameViewer extends StatelessWidget {
  final String fileName;
  final double currentPosition;
  final double fps;
  final int totalFrames;

  const _RenderedVideoFrameViewer({
    required this.fileName,
    required this.currentPosition,
    required this.fps,
    required this.totalFrames,
  });

  @override
  Widget build(BuildContext context) {
    final apiProvider = Provider.of<ApiProvider>(context, listen: false);
    
    // Calculate current frame index
    final frameIndex = (currentPosition * fps).floor().clamp(0, totalFrames - 1);
    
    // Build frame URL
    final frameUrl = '${apiProvider.baseUrl}/api/videos/${Uri.encodeComponent(fileName)}/frame/$frameIndex';

    return Stack(
      children: [
        // Frame image
        Center(
          child: Image.network(
            frameUrl,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                  const SizedBox(height: 8),
                  Text(
                    'Frame $frameIndex',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              );
            },
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return const Center(
                child: CircularProgressIndicator(color: Colors.white54),
              );
            },
          ),
        ),
        // Frame counter overlay
        Positioned(
          bottom: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Frame $frameIndex / $totalFrames',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

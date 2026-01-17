import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class RenderedVideoTrimmerDialog extends StatefulWidget {
  final String videoPath; // Kept for compatibility, not used
  final String fileName;
  final Function(double startTime, double endTime) onConfirm;
  final double? duration;
  final int? totalFrames;
  final double? fps;
  final String apiHost;
  final int apiPort;

  const RenderedVideoTrimmerDialog({
    super.key,
    required this.videoPath,
    required this.fileName,
    required this.onConfirm,
    this.duration,
    this.totalFrames,
    this.fps,
    required this.apiHost,
    this.apiPort = 5000,
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
                          apiHost: widget.apiHost,
                          apiPort: widget.apiPort,
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
  final String apiHost;
  final int apiPort;

  const _RenderedVideoFrameViewer({
    required this.fileName,
    required this.currentPosition,
    required this.fps,
    required this.totalFrames,
    required this.apiHost,
    required this.apiPort,
  });

  @override
  Widget build(BuildContext context) {
    return _RenderedVideoFrameViewerStateful(
      fileName: fileName,
      currentPosition: currentPosition,
      fps: fps,
      totalFrames: totalFrames,
      apiHost: apiHost,
      apiPort: apiPort,
    );
  }
}

class _RenderedVideoFrameViewerStateful extends StatefulWidget {
  final String fileName;
  final double currentPosition;
  final double fps;
  final int totalFrames;
  final String apiHost;
  final int apiPort;

  const _RenderedVideoFrameViewerStateful({
    required this.fileName,
    required this.currentPosition,
    required this.fps,
    required this.totalFrames,
    required this.apiHost,
    required this.apiPort,
  });

  @override
  State<_RenderedVideoFrameViewerStateful> createState() => _RenderedVideoFrameViewerStatefulState();
}

class _RenderedVideoFrameViewerStatefulState extends State<_RenderedVideoFrameViewerStateful> {
  final Map<int, Uint8List> _frameCache = {};
  final Set<int> _inFlight = {};
  static const int _maxCache = 120;
  static const int _prefetchAhead = 10;
  static const int _prefetchBehind = 3;
  int _lastFrameIndex = -1;
  String? _error;

  @override
  void didUpdateWidget(covariant _RenderedVideoFrameViewerStateful oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeFetchAndPrefetch();
  }

  @override
  void initState() {
    super.initState();
    _maybeFetchAndPrefetch();
  }

  @override
  void dispose() {
    _frameCache.clear();
    _inFlight.clear();
    super.dispose();
  }

  void _maybeFetchAndPrefetch() {
    final frameIndex = _currentFrameIndex;
    if (frameIndex == _lastFrameIndex) return;
    _lastFrameIndex = frameIndex;

    _fetchFrame(frameIndex);
    _prefetchAround(frameIndex);
    _evictIfNeeded(frameIndex);
  }

  int get _currentFrameIndex {
    return (widget.currentPosition * widget.fps).floor().clamp(0, widget.totalFrames - 1);
  }

  Future<void> _fetchFrame(int frameIndex) async {
    if (_frameCache.containsKey(frameIndex) || _inFlight.contains(frameIndex)) return;
    _inFlight.add(frameIndex);
    try {
      final url = 'http://${widget.apiHost}:${widget.apiPort}/api/videos/${Uri.encodeComponent(widget.fileName)}/frame/$frameIndex';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        _frameCache[frameIndex] = response.bodyBytes;
        if (mounted) {
          setState(() {
            _error = null;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _error = 'Frame $frameIndex unavailable (${response.statusCode})';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Frame $frameIndex error: $e';
        });
      }
    } finally {
      _inFlight.remove(frameIndex);
    }
  }

  void _prefetchAround(int center) {
    for (int i = 1; i <= _prefetchAhead; i++) {
      final next = center + i;
      if (next < widget.totalFrames) _fetchFrame(next);
    }
    for (int i = 1; i <= _prefetchBehind; i++) {
      final prev = center - i;
      if (prev >= 0) _fetchFrame(prev);
    }
  }

  void _evictIfNeeded(int center) {
    if (_frameCache.length <= _maxCache) return;
    final keys = _frameCache.keys.toList()
      ..sort((a, b) => (a - center).abs().compareTo((b - center).abs()));
    // Keep closest _maxCache frames, remove the rest
    for (int i = _maxCache; i < keys.length; i++) {
      _frameCache.remove(keys[i]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frameIndex = _currentFrameIndex;
    final bytes = _frameCache[frameIndex];

    Widget content;
    if (bytes != null) {
      content = Image.memory(
        bytes,
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.contain,
      );
    } else if (_error != null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.white54, size: 48),
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      content = const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }

    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: content,
                ),
              ),
            );
          },
        ),
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
              'Frame $frameIndex / ${widget.totalFrames}',
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

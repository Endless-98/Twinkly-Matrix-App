import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// A robust frame viewer that maintains a single displayed image and never flickers.
/// Uses a simple double-buffering approach: always show current image until next is ready.
class _FrameBuffer {
  final Map<int, Uint8List> _cache = {};
  Uint8List? _currentDisplay;
  int _displayedIndex = -1;
  
  static const int maxSize = 400;
  
  Uint8List? get current => _currentDisplay;
  int get displayedIndex => _displayedIndex;
  
  /// Store a frame in cache. Returns true if this is a new frame.
  bool store(int index, Uint8List bytes) {
    final isNew = !_cache.containsKey(index);
    _cache[index] = bytes;
    return isNew;
  }
  
  /// Get the best frame to display for target index.
  /// Updates internal display state. Never returns null if any frame exists.
  Uint8List? getBestFrame(int targetIndex) {
    // Exact match - update display
    if (_cache.containsKey(targetIndex)) {
      _currentDisplay = _cache[targetIndex];
      _displayedIndex = targetIndex;
      return _currentDisplay;
    }
    
    // Find nearest frame (prefer behind for smooth forward playback)
    int? bestIndex;
    for (final idx in _cache.keys) {
      if (idx <= targetIndex) {
        if (bestIndex == null || idx > bestIndex) bestIndex = idx;
      }
    }
    // If nothing behind, take anything
    bestIndex ??= _cache.keys.isNotEmpty ? _cache.keys.reduce((a, b) => (a - targetIndex).abs() < (b - targetIndex).abs() ? a : b) : null;
    
    if (bestIndex != null) {
      _currentDisplay = _cache[bestIndex];
      _displayedIndex = bestIndex;
    }
    
    return _currentDisplay;
  }
  
  /// Evict frames far from center to keep memory bounded.
  void evict(int center) {
    if (_cache.length <= maxSize) return;
    final sorted = _cache.keys.toList()
      ..sort((a, b) => (a - center).abs().compareTo((b - center).abs()));
    for (int i = maxSize; i < sorted.length; i++) {
      _cache.remove(sorted[i]);
    }
  }
  
  bool has(int index) => _cache.containsKey(index);
  void clear() {
    _cache.clear();
    _currentDisplay = null;
    _displayedIndex = -1;
  }
}

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
                  // Frame viewer with LED wall aspect ratio
                  AspectRatio(
                    aspectRatio: 90 / 50,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        color: Colors.black,
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
/// Stateless wrapper for the frame viewer.
class _RenderedVideoFrameViewer extends StatefulWidget {
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
  State<_RenderedVideoFrameViewer> createState() => _RenderedVideoFrameViewerState();
}

/// Robust frame viewer with simple double-buffer pattern.
/// Key principle: ALWAYS show something. Never clear the display.
class _RenderedVideoFrameViewerState extends State<_RenderedVideoFrameViewer> {
  final _FrameBuffer _buffer = _FrameBuffer();
  final Set<int> _pending = {};
  final http.Client _client = http.Client();
  
  // Prefetch window
  static const int _prefetchAhead = 80;
  static const int _prefetchBehind = 20;
  
  int _lastRequestedFrame = -1;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _prefetchInitial();
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    _buffer.clear();
    _pending.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _RenderedVideoFrameViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureFramesLoaded();
  }

  int get _targetFrame => (widget.currentPosition * widget.fps).floor().clamp(0, widget.totalFrames - 1);

  String _frameUrl(int idx) =>
      'http://${widget.apiHost}:${widget.apiPort}/api/videos/${Uri.encodeComponent(widget.fileName)}/frame/$idx';

  /// Initial prefetch of first N frames for instant playback start.
  void _prefetchInitial() {
    const batchSize = 60;
    for (int i = 0; i < batchSize && i < widget.totalFrames; i++) {
      _fetchFrame(i);
    }
    _ensureFramesLoaded();
  }

  /// Ensure current frame and surrounding window are being fetched.
  void _ensureFramesLoaded() {
    final target = _targetFrame;
    if (target == _lastRequestedFrame) return;
    _lastRequestedFrame = target;

    // Fetch target first (highest priority)
    _fetchFrame(target);

    // Prefetch ahead (more important for forward playback)
    for (int i = 1; i <= _prefetchAhead; i++) {
      final idx = target + i;
      if (idx < widget.totalFrames) _fetchFrame(idx);
    }

    // Prefetch behind (for scrubbing backwards)
    for (int i = 1; i <= _prefetchBehind; i++) {
      final idx = target - i;
      if (idx >= 0) _fetchFrame(idx);
    }

    // Evict distant frames to bound memory
    _buffer.evict(target);
  }

  /// Fetch a single frame. Fires and forgets; updates UI only when ready.
  Future<void> _fetchFrame(int idx) async {
    if (_buffer.has(idx) || _pending.contains(idx)) return;
    _pending.add(idx);

    try {
      final response = await _client.get(Uri.parse(_frameUrl(idx)));
      if (_disposed) return;
      
      if (response.statusCode == 200) {
        _buffer.store(idx, response.bodyBytes);
        
        // Only rebuild if this frame is what we're currently trying to show
        // OR if we have nothing displayed yet
        if (mounted && (idx == _targetFrame || _buffer.current == null)) {
          setState(() {});
        }
      }
    } catch (_) {
      // Silently ignore fetch errors
    } finally {
      _pending.remove(idx);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _targetFrame;
    final bytes = _buffer.getBestFrame(target);

    Widget content;
    if (bytes != null) {
      // gaplessPlayback is critical: keeps old image until new one decodes
      content = Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    } else {
      // Only show loading spinner before first frame arrives
      content = const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: content),
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
              'Frame $target / ${widget.totalFrames}',
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

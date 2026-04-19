import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// A robust frame viewer that maintains a single displayed image and never flickers.
class _FrameBuffer {
  final Map<int, Uint8List> _cache = {};
  Uint8List? _currentDisplay;
  int _displayedIndex = -1;

  static const int maxSize = 400;

  Uint8List? get current => _currentDisplay;
  int get displayedIndex => _displayedIndex;

  bool store(int index, Uint8List bytes) {
    final isNew = !_cache.containsKey(index);
    _cache[index] = bytes;
    return isNew;
  }

  Uint8List? getBestFrame(int targetIndex) {
    if (_cache.containsKey(targetIndex)) {
      _currentDisplay = _cache[targetIndex];
      _displayedIndex = targetIndex;
      return _currentDisplay;
    }

    int? bestIndex;
    for (final idx in _cache.keys) {
      if (idx <= targetIndex) {
        if (bestIndex == null || idx > bestIndex) bestIndex = idx;
      }
    }
    bestIndex ??= _cache.keys.isNotEmpty
        ? _cache.keys.reduce(
            (a, b) => (a - targetIndex).abs() < (b - targetIndex).abs() ? a : b)
        : null;

    if (bestIndex != null) {
      _currentDisplay = _cache[bestIndex];
      _displayedIndex = bestIndex;
    }

    return _currentDisplay;
  }

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
  final Function(double startTime, double endTime, String outputName) onConfirm;
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

  bool _isPlaying = false;
  Timer? _playbackTimer;

  late TextEditingController _outputNameController;

  @override
  void initState() {
    super.initState();
    _duration = widget.duration ?? 10.0;
    _totalFrames = widget.totalFrames ?? 200;
    _fps = widget.fps ?? 20.0;
    _endTime = _duration;

    final stem = widget.fileName.contains('.')
        ? widget.fileName.substring(0, widget.fileName.lastIndexOf('.'))
        : widget.fileName;
    _outputNameController = TextEditingController(text: '${stem}_trim');
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _outputNameController.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      setState(() => _isPlaying = false);
    } else {
      // Snap to start of trim region if outside
      if (_currentPosition < _startTime || _currentPosition >= _endTime) {
        setState(() => _currentPosition = _startTime);
      }
      setState(() => _isPlaying = true);

      final frameDuration = Duration(milliseconds: (1000 / _fps).round());
      _playbackTimer = Timer.periodic(frameDuration, (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _currentPosition += 1 / _fps;
          if (_currentPosition >= _endTime) {
            _currentPosition = _startTime; // Loop within trim region
          }
        });
      });
    }
  }

  void _seekToPosition(double seconds) {
    setState(() {
      _currentPosition = seconds.clamp(0.0, _duration);
    });
  }

  void _updateTrimRange(RangeValues values) {
    setState(() {
      _startTime = values.start;
      _endTime = values.end;
      // Clamp current position to the new trim range
      _currentPosition = _currentPosition.clamp(_startTime, _endTime);
    });
  }

  String _displayName(String fileName) {
    final nameOnly =
        fileName.contains('/') ? fileName.split('/').last : fileName;
    final stem = nameOnly.contains('.')
        ? nameOnly.substring(0, nameOnly.lastIndexOf('.'))
        : nameOnly;
    return stem.replaceAll('_', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final trimDuration = _endTime - _startTime;
    final selectedFrames =
        ((trimDuration * _fps).round()).clamp(0, _totalFrames);
    final outputNameEmpty = _outputNameController.text.trim().isEmpty;
    final canConfirm = !outputNameEmpty && trimDuration >= 1 / _fps;

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: MediaQuery.of(context).size.width * 0.92,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Trim Video',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          _displayName(widget.fileName),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: Colors.white54),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Frame viewer
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
              const SizedBox(height: 6),

              // Video stats strip
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _statChip('Frames', '$_totalFrames'),
                    _divider(),
                    _statChip('FPS', _fps.toStringAsFixed(1)),
                    _divider(),
                    _statChip('Length', _formatDuration(_duration)),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Seek bar (full video)
              Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.cyanAccent,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: Colors.cyanAccent.withAlpha(200),
                        inactiveTrackColor: Colors.grey[700],
                        thumbColor: Colors.cyanAccent,
                        overlayColor: Colors.cyanAccent.withAlpha(50),
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: _currentPosition,
                        min: 0,
                        max: _duration,
                        onChanged: _seekToPosition,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 78,
                    child: Text(
                      '${_formatDuration(_currentPosition)} / ${_formatDuration(_duration)}',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.white70),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),

              // Trim region (RangeSlider)
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.cyanAccent.withAlpha(60)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Trim  •  ${_formatDuration(trimDuration)}  ($selectedFrames frames)',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.cyanAccent),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text('Reset',
                              style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            setState(() {
                              _startTime = 0.0;
                              _endTime = _duration;
                              _currentPosition =
                                  _currentPosition.clamp(0.0, _duration);
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor:
                            Colors.cyanAccent.withAlpha(200),
                        inactiveTrackColor: Colors.grey[700],
                        thumbColor: Colors.cyanAccent,
                        overlayColor: Colors.cyanAccent.withAlpha(50),
                        rangeThumbShape:
                            const RoundRangeSliderThumbShape(
                                enabledThumbRadius: 8),
                        trackHeight: 4,
                      ),
                      child: RangeSlider(
                        values: RangeValues(_startTime, _endTime),
                        min: 0,
                        max: _duration,
                        onChanged: (values) {
                          if (values.end - values.start < 1 / _fps) return;
                          _updateTrimRange(values);
                        },
                      ),
                    ),
                    // Start / End tap-to-seek chips
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTap: () => _seekToPosition(_startTime),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey[850],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.skip_previous,
                                    size: 14,
                                    color: Colors.cyanAccent),
                                const SizedBox(width: 4),
                                Text(
                                  _formatDuration(_startTime),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.cyanAccent,
                                      fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _seekToPosition(_endTime),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey[850],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _formatDuration(_endTime),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.cyanAccent,
                                      fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.skip_next,
                                    size: 14,
                                    color: Colors.cyanAccent),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Output name
              TextField(
                controller: _outputNameController,
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Save as',
                  labelStyle: const TextStyle(color: Colors.white54),
                  hintText: 'output_name',
                  hintStyle: const TextStyle(color: Colors.white30),
                  suffixText: '.npz',
                  suffixStyle: const TextStyle(color: Colors.white38),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey[700]!),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide:
                        const BorderSide(color: Colors.cyanAccent),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.grey[700],
                      disabledForegroundColor: Colors.white38,
                    ),
                    icon: const Icon(Icons.content_cut, size: 16),
                    label:
                        Text('Trim  ${_formatDuration(trimDuration)}'),
                    onPressed: canConfirm
                        ? () {
                            final outputName =
                                '${_outputNameController.text.trim()}.npz';
                            Navigator.of(context).pop();
                            widget.onConfirm(
                                _startTime, _endTime, outputName);
                          }
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statChip(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 11, color: Colors.white54)),
        Text(value,
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.white)),
      ],
    );
  }

  Widget _divider() => Container(
        height: 24,
        width: 1,
        color: Colors.grey[700],
      );

  String _formatDuration(double seconds) {
    final d = Duration(milliseconds: (seconds * 1000).toInt());
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    final ms = (d.inMilliseconds % 1000) ~/ 100;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$ms';
  }
}

// ── Frame viewer ──────────────────────────────────────────────────────────────

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
  State<_RenderedVideoFrameViewer> createState() =>
      _RenderedVideoFrameViewerState();
}

class _RenderedVideoFrameViewerState
    extends State<_RenderedVideoFrameViewer> {
  final _FrameBuffer _buffer = _FrameBuffer();
  final Set<int> _pending = {};
  final http.Client _client = http.Client();

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

  int get _targetFrame =>
      (widget.currentPosition * widget.fps)
          .floor()
          .clamp(0, widget.totalFrames - 1);

  String _frameUrl(int idx) =>
      'http://${widget.apiHost}:${widget.apiPort}/api/videos/'
      '${Uri.encodeComponent(widget.fileName)}/frame/$idx';

  void _prefetchInitial() {
    const batchSize = 60;
    for (int i = 0; i < batchSize && i < widget.totalFrames; i++) {
      _fetchFrame(i);
    }
    _ensureFramesLoaded();
  }

  void _ensureFramesLoaded() {
    final target = _targetFrame;
    if (target == _lastRequestedFrame) return;
    _lastRequestedFrame = target;

    _fetchFrame(target);

    for (int i = 1; i <= _prefetchAhead; i++) {
      final idx = target + i;
      if (idx < widget.totalFrames) _fetchFrame(idx);
    }

    for (int i = 1; i <= _prefetchBehind; i++) {
      final idx = target - i;
      if (idx >= 0) _fetchFrame(idx);
    }

    _buffer.evict(target);
  }

  Future<void> _fetchFrame(int idx) async {
    if (_buffer.has(idx) || _pending.contains(idx)) return;
    _pending.add(idx);

    try {
      final response = await _client.get(Uri.parse(_frameUrl(idx)));
      if (_disposed) return;

      if (response.statusCode == 200) {
        _buffer.store(idx, response.bodyBytes);

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
      content = Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    } else {
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
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

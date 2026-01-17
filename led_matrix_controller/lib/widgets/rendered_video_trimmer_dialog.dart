import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _duration = widget.duration ?? 10.0;
    _totalFrames = widget.totalFrames ?? 200;
    _fps = widget.fps ?? 20.0;
    _endTime = _duration;
  }


  void _togglePlayPause() {
    // For rendered videos, we just move the timeline slider
    setState(() {
      // Placeholder for play/pause logic
    });
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

            // Video info
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // Simple gradient representation
                    Container(
                      height: 150,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.blue.shade400,
                            Colors.purple.shade400,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.video_library,
                              size: 48,
                              color: Colors.white,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Rendered Video',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(color: Colors.white),
                            ),
                          ],
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Video Information:',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total Frames:'),
                              Text('$_totalFrames'),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Frame Rate:'),
                              Text('${_fps.toStringAsFixed(1)} FPS'),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Duration:'),
                              Text('${_formatDuration(_duration)}'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
                      icon: const Icon(Icons.play_arrow),
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

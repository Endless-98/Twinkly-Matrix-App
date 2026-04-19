import 'package:flutter/material.dart';
import 'dart:async';
import 'package:video_player/video_player.dart';

class RenderedVideoTrimmerDialog extends StatefulWidget {
  final String videoPath;
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

  VideoPlayerController? _controller;
  bool _videoReady = false;
  bool _videoError = false;
  String? _errorMessage;

  Timer? _positionTimer;

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

    _initVideo();
  }

  Future<void> _initVideo() async {
    final encoded = Uri.encodeComponent(widget.fileName);
    final url = 'http://${widget.apiHost}:${widget.apiPort}'
        '/api/videos/$encoded/preview';

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      _controller = controller;

      await controller.initialize();
      if (!mounted) return;

      await controller.setVolume(0.0); // No audio in rendered preview
      await controller.seekTo(Duration.zero); // Show first frame on Android

      // Use video duration if available (more accurate than metadata)
      final videoDur = controller.value.duration.inMilliseconds / 1000.0;
      if (videoDur > 0) {
        _duration = videoDur;
        _endTime = _duration;
      }

      controller.setLooping(false);
      controller.addListener(_onVideoUpdate);

      setState(() => _videoReady = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _videoError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _onVideoUpdate() {
    if (!mounted || _controller == null) return;
    final pos = _controller!.value.position.inMilliseconds / 1000.0;
    setState(() => _currentPosition = pos);

    // Loop within trim region during playback
    if (_controller!.value.isPlaying && pos >= _endTime) {
      _controller!.seekTo(Duration(milliseconds: (_startTime * 1000).round()));
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _controller?.removeListener(_onVideoUpdate);
    _controller?.dispose();
    _outputNameController.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_controller == null || !_videoReady) return;

    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      // Snap to trim start if outside trim region
      if (_currentPosition < _startTime || _currentPosition >= _endTime) {
        _controller!.seekTo(
            Duration(milliseconds: (_startTime * 1000).round()));
      }
      _controller!.play();
    }
  }

  void _seekToPosition(double seconds) {
    final clamped = seconds.clamp(0.0, _duration);
    _controller?.seekTo(Duration(milliseconds: (clamped * 1000).round()));
    setState(() => _currentPosition = clamped);
  }

  void _updateTrimRange(RangeValues values) {
    setState(() {
      _startTime = values.start;
      _endTime = values.end;
    });
    // If playing and current position is outside new range, seek to start
    if (_controller != null &&
        _controller!.value.isPlaying &&
        (_currentPosition < _startTime || _currentPosition > _endTime)) {
      _controller!.seekTo(
          Duration(milliseconds: (_startTime * 1000).round()));
    }
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
    final isPlaying = _controller?.value.isPlaying ?? false;

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
                        Text('Trim Video',
                            style: Theme.of(context).textTheme.titleLarge),
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

              // Video player
              AspectRatio(
                aspectRatio: 90 / 50,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    color: Colors.black,
                    child: _buildVideoArea(),
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
                    _vertDivider(),
                    _statChip('FPS', _fps.toStringAsFixed(1)),
                    _vertDivider(),
                    _statChip('Length', _formatDuration(_duration)),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // Seek bar
              Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
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
                        value: _currentPosition.clamp(0.0, _duration),
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

              // Trim region
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
                          'Trim  \u2022  ${_formatDuration(trimDuration)}  ($selectedFrames frames)',
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _seekChip(
                          icon: Icons.skip_previous,
                          label: _formatDuration(_startTime),
                          onTap: () => _seekToPosition(_startTime),
                        ),
                        _seekChip(
                          icon: Icons.skip_next,
                          label: _formatDuration(_endTime),
                          onTap: () => _seekToPosition(_endTime),
                          iconFirst: false,
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

  Widget _buildVideoArea() {
    if (_videoError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.redAccent, size: 32),
              const SizedBox(height: 8),
              Text(
                'Could not load preview',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 10),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (!_videoReady || _controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.cyanAccent),
            SizedBox(height: 8),
            Text('Generating preview...',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(_controller!),
          if (!_controller!.value.isPlaying)
            Container(
              decoration: BoxDecoration(
                color: Colors.black38,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(12),
              child: const Icon(Icons.play_arrow,
                  color: Colors.white, size: 36),
            ),
        ],
      ),
    );
  }

  Widget _seekChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool iconFirst = true,
  }) {
    final iconW = Icon(icon, size: 14, color: Colors.cyanAccent);
    final textW = Text(
      label,
      style: const TextStyle(
          fontSize: 12,
          color: Colors.cyanAccent,
          fontWeight: FontWeight.w500),
    );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: iconFirst
              ? [iconW, const SizedBox(width: 4), textW]
              : [textW, const SizedBox(width: 4), iconW],
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

  Widget _vertDivider() => Container(
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

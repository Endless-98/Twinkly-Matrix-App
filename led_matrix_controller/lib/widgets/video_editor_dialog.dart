import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';

class VideoEditorDialog extends StatefulWidget {
  final String videoPath;
  final String fileName;
  final Function(double startTime, double endTime, Rect? cropRect) onConfirm;

  const VideoEditorDialog({
    super.key,
    required this.videoPath,
    required this.fileName,
    required this.onConfirm,
  });

  @override
  State<VideoEditorDialog> createState() => _VideoEditorDialogState();
}

class _VideoEditorDialogState extends State<VideoEditorDialog> {
  static const double _ledAspectRatio = 90 / 50; // Keep crop locked to curtain aspect
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _isLoading = true;
  String? _error;

  // Trim controls
  double _startTime = 0.0;
  double _endTime = 0.0;
  double _currentPosition = 0.0;

  // Crop controls
  bool _isCropping = false;
  Rect? _cropRect;
  Offset? _cropStart;
  Offset? _cropEnd;
  bool _isMovingCrop = false;
  Offset? _dragOffset;
  Size? _viewSize;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.videoPath));
      await _controller.initialize();
      
      setState(() {
        _isInitialized = true;
        _isLoading = false;
        _endTime = _controller.value.duration.inMilliseconds / 1000.0;
      });

      _controller.addListener(() {
        if (mounted) {
          setState(() {
            _currentPosition = _controller.value.position.inMilliseconds / 1000.0;
          });
        }
      });

      // Auto-play on load
      _controller.play();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _seekToPosition(double seconds) {
    _controller.seekTo(Duration(milliseconds: (seconds * 1000).toInt()));
  }

  void _togglePlayPause() {
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  void _handleCropPanStart(DragStartDetails details, Size viewSize) {
    final localPosition = details.localPosition;
    final normalized = _normalizePosition(localPosition, viewSize);

    // If tapping inside existing crop, start moving it
    if (_cropRect != null && _cropRect!.contains(normalized)) {
      _isMovingCrop = true;
      _dragOffset = normalized - _cropRect!.topLeft;
      return;
    }

    // Start a new crop selection
    setState(() {
      _isMovingCrop = false;
      _cropStart = normalized;
      _cropEnd = normalized;
      _cropRect = _buildAspectLockedRect(_cropStart!, _cropEnd!);
    });
  }

  void _handleCropPanUpdate(DragUpdateDetails details, Size viewSize) {
    final localPosition = details.localPosition;
    final normalized = _normalizePosition(localPosition, viewSize);

    if (_isMovingCrop && _cropRect != null && _dragOffset != null) {
      final width = _cropRect!.width;
      final height = _cropRect!.height;
      // Maintain size and aspect while moving
      var newLeft = (normalized.dx - _dragOffset!.dx).clamp(0.0, 1.0 - width);
      var newTop = (normalized.dy - _dragOffset!.dy).clamp(0.0, 1.0 - height);

      setState(() {
        _cropRect = Rect.fromLTWH(newLeft, newTop, width, height);
      });
      return;
    }

    if (_cropStart == null) return;

    setState(() {
      _cropEnd = normalized;
      _cropRect = _buildAspectLockedRect(_cropStart!, _cropEnd!);
    });
  }

  void _handleCropPanEnd(DragEndDetails details) {
    setState(() {
      _cropStart = null;
      _cropEnd = null;
      _isMovingCrop = false;
      _dragOffset = null;
    });
  }

  Offset _normalizePosition(Offset position, Size viewSize) {
    // Convert pixel position to normalized 0-1 coordinates, clamped to bounds
    return Offset(
      (position.dx / viewSize.width).clamp(0.0, 1.0),
      (position.dy / viewSize.height).clamp(0.0, 1.0),
    );
  }

  Rect _buildAspectLockedRect(Offset start, Offset current) {
    // Create a rect that respects the LED aspect ratio and stays within bounds
    final dx = current.dx - start.dx;
    final dy = current.dy - start.dy;

    final widthAbs = dx.abs();
    final heightAbs = dy.abs();

    // Decide size based on whichever dimension is more restrictive for the aspect ratio
    double targetWidth;
    double targetHeight;

    if (widthAbs / (heightAbs == 0 ? 0.0001 : heightAbs) > _ledAspectRatio) {
      // Width is too large relative to height; limit by height
      targetHeight = heightAbs;
      targetWidth = targetHeight * _ledAspectRatio;
    } else {
      // Height is too large; limit by width
      targetWidth = widthAbs;
      targetHeight = targetWidth / _ledAspectRatio;
    }

    // Ensure a small minimum size to avoid zero-area rects
    const double minSize = 0.02; // 2% of the view
    targetWidth = targetWidth.clamp(minSize, 1.0);
    targetHeight = targetHeight.clamp(minSize / _ledAspectRatio, 1.0);

    // Determine orientation (drag direction)
    final left = dx >= 0 ? start.dx : start.dx - targetWidth;
    final top = dy >= 0 ? start.dy : start.dy - targetHeight;

    // Clamp to viewport
    final clampedLeft = left.clamp(0.0, 1.0 - targetWidth);
    final clampedTop = top.clamp(0.0, 1.0 - targetHeight);

    return Rect.fromLTWH(
      clampedLeft,
      clampedTop,
      targetWidth,
      targetHeight,
    );
  }

  Widget _buildCropOverlay(Size videoSize) {
    if (!_isCropping) return const SizedBox.shrink();

    return CustomPaint(
      painter: CropOverlayPainter(
        cropRect: _cropRect,
        cropStart: _cropStart,
        cropEnd: _cropEnd,
        videoSize: videoSize,
      ),
      child: Container(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Edit Video',
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
            
            // Video Player
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text('Error: $_error'))
                      : _isInitialized
                          ? AspectRatio(
                              aspectRatio: _controller.value.aspectRatio,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
                                  _viewSize = viewSize;
                                  return GestureDetector(
                                    onPanStart: _isCropping
                                        ? (details) => _handleCropPanStart(details, viewSize)
                                        : null,
                                    onPanUpdate: _isCropping
                                        ? (details) => _handleCropPanUpdate(details, viewSize)
                                        : null,
                                    onPanEnd: _isCropping ? _handleCropPanEnd : null,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // Show video with crop applied (or full video if no crop)
                                        if (_cropRect != null)
                                          ClipRect(
                                            child: Transform.translate(
                                              offset: Offset(
                                                -_cropRect!.left * viewSize.width,
                                                -_cropRect!.top * viewSize.height,
                                              ),
                                              child: SizedBox(
                                                width: viewSize.width / _cropRect!.width,
                                                height: viewSize.height / _cropRect!.height,
                                                child: VideoPlayer(_controller),
                                              ),
                                            ),
                                          )
                                        else
                                          VideoPlayer(_controller),
                                        if (_isCropping)
                                          _buildCropOverlay(viewSize),
                                        if (!_controller.value.isPlaying && !_isCropping)
                                          Center(
                                            child: IconButton(
                                              icon: const Icon(
                                                Icons.play_circle_outline,
                                                size: 64,
                                                color: Colors.white,
                                              ),
                                              onPressed: _togglePlayPause,
                                            ),
                                          ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            )
                          : const Center(child: Text('Failed to load video')),
            ),
            
            const SizedBox(height: 16),
            
            // Playback controls
            if (_isInitialized) ...[
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: _togglePlayPause,
                  ),
                  Expanded(
                    child: Slider(
                      value: _currentPosition,
                      min: 0,
                      max: _endTime,
                      onChanged: (value) {
                        _seekToPosition(value);
                      },
                    ),
                  ),
                  Text(
                    '${_formatDuration(_currentPosition)} / ${_formatDuration(_endTime)}',
                  ),
                ],
              ),
              
              const Divider(),
              
              // Trim controls
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Trim Video', style: TextStyle(fontWeight: FontWeight.bold)),
                      TextButton.icon(
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Reset'),
                        onPressed: () {
                          setState(() {
                            _startTime = 0.0;
                            _endTime = _controller.value.duration.inMilliseconds / 1000.0;
                          });
                        },
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 60, child: Text('Start:')),
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
                  Row(
                    children: [
                      const SizedBox(width: 60, child: Text('End:')),
                      Expanded(
                        child: Slider(
                          value: _endTime,
                          min: _startTime,
                          max: _controller.value.duration.inMilliseconds / 1000.0,
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
                  Center(
                    child: Text(
                      'Duration: ${_formatDuration(_endTime - _startTime)}',
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
              
              const Divider(),
              
              // Crop controls
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Crop Video', style: TextStyle(fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          if (_cropRect != null)
                            TextButton.icon(
                              icon: const Icon(Icons.clear, size: 16),
                              label: const Text('Clear'),
                              onPressed: () {
                                setState(() {
                                  _cropRect = null;
                                });
                              },
                            ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            icon: Icon(_isCropping ? Icons.check : Icons.crop),
                            label: Text(_isCropping ? 'Done' : 'Enable'),
                            onPressed: () {
                              setState(() {
                                _isCropping = !_isCropping;
                                if (!_isCropping) {
                                  _cropStart = null;
                                  _cropEnd = null;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (_isCropping)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'Drag on the video to select crop area',
                        style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
                      ),
                    ),
                  if (_cropRect != null)
                    Text(
                      'Crop: ${(_cropRect!.width * 100).toStringAsFixed(0)}% × ${(_cropRect!.height * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ],
            
            const Divider(),
            
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
                  onPressed: _isInitialized
                      ? () {
                          Navigator.of(context).pop();
                          widget.onConfirm(_startTime, _endTime, _cropRect);
                        }
                      : null,
                  child: const Text('Upload & Render'),
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

class CropOverlayPainter extends CustomPainter {
  final Rect? cropRect;
  final Offset? cropStart;
  final Offset? cropEnd;
  final Size videoSize;

  CropOverlayPainter({
    required this.cropRect,
    required this.cropStart,
    required this.cropEnd,
    required this.videoSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    final cropPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Draw semi-transparent overlay
    if (cropRect != null) {
      final rect = Rect.fromLTRB(
        cropRect!.left * size.width,
        cropRect!.top * size.height,
        cropRect!.right * size.width,
        cropRect!.bottom * size.height,
      );

      // Draw darkened areas outside crop
      canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), paint);
      canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), paint);
      canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), paint);
      canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), paint);

      // Draw crop rectangle
      canvas.drawRect(rect, cropPaint);

      // Draw corner handles
      final handleSize = 12.0;
      final handlePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(rect.left, rect.top), handleSize / 2, handlePaint);
      canvas.drawCircle(Offset(rect.right, rect.top), handleSize / 2, handlePaint);
      canvas.drawCircle(Offset(rect.left, rect.bottom), handleSize / 2, handlePaint);
      canvas.drawCircle(Offset(rect.right, rect.bottom), handleSize / 2, handlePaint);
    }

    // Draw in-progress crop selection
    if (cropStart != null && cropEnd != null) {
      final tempRect = Rect.fromPoints(
        Offset(cropStart!.dx * size.width, cropStart!.dy * size.height),
        Offset(cropEnd!.dx * size.width, cropEnd!.dy * size.height),
      );

      final dashedPaint = Paint()
        ..color = Colors.yellow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawRect(tempRect, dashedPaint);
    }
  }

  @override
  bool shouldRepaint(CropOverlayPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect ||
        oldDelegate.cropStart != cropStart ||
        oldDelegate.cropEnd != cropEnd;
  }
}

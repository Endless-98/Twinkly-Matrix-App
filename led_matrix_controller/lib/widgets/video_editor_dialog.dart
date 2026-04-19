import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:image/image.dart' as img;
import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';

class VideoEditorDialog extends StatefulWidget {
  final String videoPath;
  final String fileName;
  final Function(double startTime, double endTime, Rect? cropRect,
      double brightness, double contrast, double hue) onConfirm;

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
  // LED curtain dimensions: 90 wide x 50 tall (always landscape orientation regardless of input video)
  static const double _ledAspectRatio = 90 / 50;
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

  // Color adjustment controls (applied at render time)
  double _brightness = 0.0;  // -100 to +100
  double _contrast = 1.0;    // 0.5 to 2.0
  double _hue = 0.0;         // -180 to +180 degrees

  // Color preview state
  bool _previewMode = false;
  Uint8List? _previewBytes;
  bool _generatingPreview = false;
  Timer? _previewDebounce;

  /// Builds a combined ColorFilter matrix for live preview.
  /// Combines brightness offset, contrast scaling, and hue rotation in RGB space.
  List<double> _buildColorMatrix() {
    final c = _contrast;
    final b = _brightness;
    final hRad = _hue * math.pi / 180.0;
    final cosH = math.cos(hRad);
    final sinH = math.sin(hRad);
    final sq3 = 1.0 / math.sqrt(3.0);
    // Luminance-preserving hue rotation matrix (rows sum to 1)
    final h00 = cosH + (1 - cosH) / 3;
    final h01 = (1 - cosH) / 3 - sinH * sq3;
    final h02 = (1 - cosH) / 3 + sinH * sq3;
    final h10 = (1 - cosH) / 3 + sinH * sq3;
    final h11 = cosH + (1 - cosH) / 3;
    final h12 = (1 - cosH) / 3 - sinH * sq3;
    final h20 = (1 - cosH) / 3 - sinH * sq3;
    final h21 = (1 - cosH) / 3 + sinH * sq3;
    final h22 = cosH + (1 - cosH) / 3;
    // Contrast scales around midpoint 128; brightness adds flat offset
    final offset = 128.0 * (1 - c) + b;
    return [
      c * h00, c * h01, c * h02, 0, offset,
      c * h10, c * h11, c * h12, 0, offset,
      c * h20, c * h21, c * h22, 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  bool get _hasColorAdj => _brightness != 0.0 || _contrast != 1.0 || _hue != 0.0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.videoPath));
      await _controller.initialize();
      await _controller.setVolume(0.0); // No audio — LED wall plays silently
      await _controller.seekTo(Duration.zero); // Show first frame
      
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
    _previewDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Schedules a preview frame regeneration after a short debounce.
  void _schedulePreviewUpdate() {
    if (!_previewMode) return;
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 350), _generatePreview);
  }

  /// Extracts the current frame from the video and applies the color matrix,
  /// then stores the result in [_previewBytes] for display.
  Future<void> _generatePreview() async {
    if (!_isInitialized || !mounted) return;
    setState(() => _generatingPreview = true);
    try {
      final frameBytes = await VideoThumbnail.thumbnailData(
        video: widget.videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 540,
        quality: 88,
        timeMs: (_currentPosition * 1000).toInt(),
      );
      if (frameBytes == null || !mounted) {
        if (mounted) setState(() => _generatingPreview = false);
        return;
      }
      final adjusted = await compute(_applyColorAdjustments, {
        'bytes': frameBytes,
        'brightness': _brightness,
        'contrast': _contrast,
        'hue': _hue,
      });
      if (mounted) setState(() { _previewBytes = adjusted; _generatingPreview = false; });
    } catch (_) {
      if (mounted) setState(() => _generatingPreview = false);
    }
  }

  /// Runs in an isolate. Applies the same RGB color matrix used by the Python
  /// renderer so the preview matches the rendered output exactly.
  static Uint8List _applyColorAdjustments(Map<String, dynamic> args) {
    final bytes = args['bytes'] as Uint8List;
    final c = args['contrast'] as double;
    final b = args['brightness'] as double;
    final hueDeg = args['hue'] as double;

    final src = img.decodeImage(bytes);
    if (src == null) return bytes;

    final hRad = hueDeg * math.pi / 180.0;
    final cosH = math.cos(hRad);
    final sinH = math.sin(hRad);
    final sq3 = 1.0 / math.sqrt(3.0);

    final h00 = cosH + (1 - cosH) / 3;
    final h01 = (1 - cosH) / 3 - sinH * sq3;
    final h02 = (1 - cosH) / 3 + sinH * sq3;
    final h10 = (1 - cosH) / 3 + sinH * sq3;
    final h11 = cosH + (1 - cosH) / 3;
    final h12 = (1 - cosH) / 3 - sinH * sq3;
    final h20 = (1 - cosH) / 3 - sinH * sq3;
    final h21 = (1 - cosH) / 3 + sinH * sq3;
    final h22 = cosH + (1 - cosH) / 3;
    final offset = 128.0 * (1 - c) + b;

    final dst = img.Image(width: src.width, height: src.height, numChannels: 3);
    for (final pixel in src) {
      final r = pixel.r.toDouble();
      final g = pixel.g.toDouble();
      final bv = pixel.b.toDouble();
      dst.setPixelRgb(
        pixel.x, pixel.y,
        (c * h00 * r + c * h01 * g + c * h02 * bv + offset).clamp(0.0, 255.0),
        (c * h10 * r + c * h11 * g + c * h12 * bv + offset).clamp(0.0, 255.0),
        (c * h20 * r + c * h21 * g + c * h22 * bv + offset).clamp(0.0, 255.0),
      );
    }
    return Uint8List.fromList(img.encodeJpg(dst, quality: 88));
  }

  void _seekToPosition(double seconds) {
    _controller.seekTo(Duration(milliseconds: (seconds * 1000).toInt()));
    _schedulePreviewUpdate();
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
      _cropRect = _buildAspectLockedRect(_cropStart!, _cropEnd!, viewSize);
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
      _cropRect = _buildAspectLockedRect(_cropStart!, _cropEnd!, viewSize);
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

  Rect _buildAspectLockedRect(Offset start, Offset current, Size viewSize) {
    // Adjust LED aspect ratio by viewport aspect ratio to account for normalized coordinates
    final viewportAspectRatio = viewSize.width / viewSize.height;
    final adjustedAspectRatio = _ledAspectRatio / viewportAspectRatio;
    
    // Create a rect that respects the LED aspect ratio and stays within bounds
    final dx = current.dx - start.dx;
    final dy = current.dy - start.dy;

    final widthAbs = dx.abs();
    final heightAbs = dy.abs();

    // Decide size based on whichever dimension is more restrictive for the aspect ratio
    double targetWidth;
    double targetHeight;

    if (widthAbs / (heightAbs == 0 ? 0.0001 : heightAbs) > adjustedAspectRatio) {
      // Width is too large relative to height; limit by height
      targetHeight = heightAbs;
      targetWidth = targetHeight * adjustedAspectRatio;
    } else {
      // Height is too large; limit by width
      targetWidth = widthAbs;
      targetHeight = targetWidth / adjustedAspectRatio;
    }

    // Maintain aspect ratio when clamping to viewport bounds
    // If width exceeds bounds, scale both down proportionally
    if (targetWidth > 1.0) {
      final scale = 1.0 / targetWidth;
      targetWidth = 1.0;
      targetHeight *= scale;
    }
    // If height exceeds bounds, scale both down proportionally
    if (targetHeight > 1.0) {
      final scale = 1.0 / targetHeight;
      targetHeight = 1.0;
      targetWidth *= scale;
    }

    // Ensure minimum size
    const double minSize = 0.02; // 2% of the view
    targetWidth = targetWidth.clamp(minSize, 1.0);
    
    // CRITICAL: Always recalculate height from width to maintain exact aspect ratio
    // This prevents the independent height clamp from breaking the 90:50 ratio
    targetHeight = targetWidth / adjustedAspectRatio;
    targetHeight = targetHeight.clamp(minSize / adjustedAspectRatio, 1.0);
    
    // If height was clamped, adjust width to match
    if (targetHeight < targetWidth / adjustedAspectRatio) {
      targetWidth = targetHeight * adjustedAspectRatio;
    }

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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Dialog.fullscreen(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            widget.fileName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _isInitialized
                    ? () {
                        Navigator.of(context).pop();
                        widget.onConfirm(
                            _startTime, _endTime, _cropRect,
                            _brightness, _contrast, _hue);
                      }
                    : null,
                icon: const Icon(Icons.upload, size: 18),
                label: const Text('Render'),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
              ),
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: cs.error),
                        const SizedBox(height: 12),
                        Text('Failed to load video', style: TextStyle(color: cs.error)),
                        const SizedBox(height: 4),
                        Text(_error!, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                      ],
                    ),
                  )
                : _isInitialized
                    ? _buildEditorBody(cs)
                    : const Center(child: Text('Failed to initialize')),
      ),
    );
  }

  Widget _buildEditorBody(ColorScheme cs) {
    return Column(
      children: [
        // --- Video preview ---
        Expanded(
          flex: 3,
          child: Container(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewSize = Size(constraints.maxWidth, constraints.maxHeight);
                    return GestureDetector(
                      onTap: _isCropping ? null : _togglePlayPause,
                      onPanStart: _isCropping
                          ? (details) => _handleCropPanStart(details, viewSize)
                          : null,
                      onPanUpdate: _isCropping
                          ? (details) => _handleCropPanUpdate(details, viewSize)
                          : null,
                      onPanEnd: _isCropping ? _handleCropPanEnd : null,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Show color-adjusted still frame in preview mode,
                            // otherwise show the live video player.
                            if (_previewMode && _previewBytes != null)
                              Image.memory(_previewBytes!, fit: BoxFit.fill)
                            else
                              VideoPlayer(_controller),
                            if (_isCropping) _buildCropOverlay(viewSize),
                            if (_cropRect != null && !_isCropping)
                              IgnorePointer(child: _buildCropOverlay(viewSize)),
                            // Loading spinner while generating preview
                            if (_previewMode && _generatingPreview)
                              Container(
                                color: Colors.black54,
                                child: const Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            if (!_previewMode && !_controller.value.isPlaying && !_isCropping)
                              Center(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black38,
                                    shape: BoxShape.circle,
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  child: const Icon(Icons.play_arrow, size: 48, color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),

        // --- Playback scrubber ---
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  _controller.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
                ),
                onPressed: _togglePlayPause,
              ),
              Text(
                _formatDuration(_currentPosition),
                style: TextStyle(fontSize: 12, color: Colors.grey[400], fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: cs.primary,
                    inactiveTrackColor: Colors.white12,
                    thumbColor: cs.primary,
                  ),
                  child: Slider(
                    value: _currentPosition.clamp(0.0, _controller.value.duration.inMilliseconds / 1000.0),
                    min: 0,
                    max: _controller.value.duration.inMilliseconds / 1000.0,
                    onChanged: _seekToPosition,
                  ),
                ),
              ),
              Text(
                _formatDuration(_controller.value.duration.inMilliseconds / 1000.0),
                style: TextStyle(fontSize: 12, color: Colors.grey[400], fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
        ),

        // --- Controls panel ---
        Expanded(
          flex: 2,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildTrimSection(cs),
                  const SizedBox(height: 20),
                  _buildColorSection(cs),
                  const SizedBox(height: 20),
                  _buildCropSection(cs),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrimSection(ColorScheme cs) {
    final maxDuration = _controller.value.duration.inMilliseconds / 1000.0;
    final trimmedDuration = _endTime - _startTime;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.content_cut_rounded, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            const Text('Trim', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _formatDuration(trimmedDuration),
                style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
            if (_startTime > 0 || _endTime < maxDuration)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _startTime = 0.0;
                    _endTime = maxDuration;
                  });
                },
                child: Text('Reset', style: TextStyle(fontSize: 12, color: cs.primary)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _buildTrimSlider('Start', _startTime, 0, _endTime - 0.1, (v) {
          setState(() => _startTime = v);
        }, cs),
        const SizedBox(height: 8),
        _buildTrimSlider('End', _endTime, _startTime + 0.1, maxDuration, (v) {
          setState(() => _endTime = v);
        }, cs),
      ],
    );
  }

  Widget _buildTrimSlider(String label, double value, double min, double max, ValueChanged<double> onChanged, ColorScheme cs) {
    return Row(
      children: [
        SizedBox(
          width: 38,
          child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ),
        Text(
          _formatDuration(value),
          style: TextStyle(fontSize: 12, color: Colors.grey[300], fontFeatures: const [FontFeature.tabularFigures()]),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: cs.primary.withValues(alpha: 0.6),
              inactiveTrackColor: Colors.white10,
              thumbColor: cs.primary,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildColorSection(ColorScheme cs) {
    final hasAdj = _hasColorAdj;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune_rounded, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            const Text('Color', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (hasAdj)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _brightness = 0.0;
                    _contrast = 1.0;
                    _hue = 0.0;
                  });
                  _schedulePreviewUpdate();
                },
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('Reset', style: TextStyle(fontSize: 12, color: cs.primary)),
                ),
              ),
            FilledButton.tonalIcon(
              onPressed: () {
                final entering = !_previewMode;
                setState(() {
                  _previewMode = entering;
                  if (!entering) _previewBytes = null;
                });
                if (entering) {
                  _controller.pause();
                  _generatePreview();
                }
              },
              icon: Icon(
                _previewMode ? Icons.videocam_rounded : Icons.preview_rounded,
                size: 15,
              ),
              label: Text(
                _previewMode ? 'Live' : 'Preview',
                style: const TextStyle(fontSize: 12),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _previewMode
                    ? cs.primary.withValues(alpha: 0.25)
                    : null,
                foregroundColor: _previewMode ? cs.primary : null,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Brightness
        _buildColorRow(
          label: 'Brightness',
          icon: Icons.brightness_6_rounded,
          value: _brightness,
          min: -100,
          max: 100,
          defaultValue: 0,
          displayText: _brightness == 0 ? '0' : '${_brightness > 0 ? "+" : ""}${_brightness.toStringAsFixed(0)}',
          onChanged: (v) { setState(() => _brightness = v); _schedulePreviewUpdate(); },
          cs: cs,
        ),
        const SizedBox(height: 8),
        // Contrast
        _buildColorRow(
          label: 'Contrast',
          icon: Icons.contrast_rounded,
          value: _contrast,
          min: 0.5,
          max: 2.0,
          defaultValue: 1.0,
          displayText: '${_contrast.toStringAsFixed(2)}×',
          onChanged: (v) { setState(() => _contrast = v); _schedulePreviewUpdate(); },
          cs: cs,
        ),
        const SizedBox(height: 8),
        // Hue
        _buildColorRow(
          label: 'Hue',
          icon: Icons.palette_rounded,
          value: _hue,
          min: -180,
          max: 180,
          defaultValue: 0,
          displayText: _hue == 0 ? '0°' : '${_hue > 0 ? "+" : ""}${_hue.toStringAsFixed(0)}°',
          onChanged: (v) { setState(() => _hue = v); _schedulePreviewUpdate(); },
          cs: cs,
        ),
      ],
    );
  }

  Widget _buildColorRow({
    required String label,
    required IconData icon,
    required double value,
    required double min,
    required double max,
    required double defaultValue,
    required String displayText,
    required ValueChanged<double> onChanged,
    required ColorScheme cs,
  }) {
    final isDefault = (value - defaultValue).abs() < 0.001;
    return Row(
      children: [
        Icon(icon, size: 15, color: isDefault ? Colors.grey[600] : cs.primary),
        const SizedBox(width: 6),
        SizedBox(
          width: 72,
          child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ),
        GestureDetector(
          onTap: isDefault ? null : () => onChanged(defaultValue),
          child: SizedBox(
            width: 42,
            child: Text(
              displayText,
              style: TextStyle(
                fontSize: 12,
                color: isDefault ? Colors.grey[600] : cs.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: isDefault ? Colors.white24 : cs.primary.withValues(alpha: 0.7),
              inactiveTrackColor: Colors.white10,
              thumbColor: isDefault ? Colors.grey : cs.primary,
            ),
            child: Slider(value: value, min: min, max: max, onChanged: onChanged),
          ),
        ),
      ],
    );
  }

  Widget _buildCropSection(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.crop_rounded, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            const Text('Crop', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('90:50', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            const Spacer(),
            if (_cropRect != null && !_isCropping)
              TextButton(
                onPressed: () => setState(() => _cropRect = null),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Clear', style: TextStyle(fontSize: 12)),
              ),
            const SizedBox(width: 4),
            FilledButton.tonalIcon(
              onPressed: () {
                setState(() {
                  _isCropping = !_isCropping;
                  if (!_isCropping) {
                    _cropStart = null;
                    _cropEnd = null;
                  }
                });
              },
              icon: Icon(_isCropping ? Icons.check : Icons.crop, size: 16),
              label: Text(_isCropping ? 'Done' : 'Select', style: const TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        if (_isCropping)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Drag on the video to select the crop area. Tap and drag inside the selection to move it.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
        if (_cropRect != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Crop: ${(_cropRect!.width * 100).toStringAsFixed(0)}% × ${(_cropRect!.height * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ),
      ],
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
      ..color = Colors.black.withValues(alpha: 0.5)
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

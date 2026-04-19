import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../services/platform_screen_capture.dart';
import '../services/ddp_sender.dart';
import '../services/app_logger.dart';
import '../providers/app_state.dart';
import '../widgets/curtain_preview.dart';

/// Top-level function so it can run in a background isolate via compute().
/// Blends 85% sharp (nearest-neighbour centre pixel) with 15% area-average
/// (box filter), keeping the image crisp while softening aliasing.
Uint8List _composeBubbleFrameIsolate(Map<String, dynamic> args) {
  final Uint8List sourceFrame = args['source'];
  final int bubbleX = args['bx'];
  final int bubbleY = args['by'];
  final int bubbleW = args['bw'];
  final int bubbleH = args['bh'];
  final double cropL = args['cl'];
  final double cropT = args['ct'];
  final double cropW = args['cw'];
  final double cropH = args['ch'];
  final double brightness = (args['brightness'] as num? ?? 1.0).toDouble();

  const matrixW = 90;
  const matrixH = 50;
  final fullFrame = Uint8List(matrixW * matrixH * 3);

  final srcPixelCount = sourceFrame.length ~/ 3;
  int srcW, srcH;
  if (sourceFrame.length == matrixW * matrixH * 3) {
    srcW = matrixW;
    srcH = matrixH;
  } else if (sourceFrame.length == matrixW * 100 * 3) {
    srcW = matrixW;
    srcH = 100;
  } else if (sourceFrame.length == 360 * 640 * 3) {
    srcW = 360;
    srcH = 640;
  } else {
    srcW = matrixW;
    srcH = srcPixelCount ~/ srcW;
    if (srcW * srcH * 3 != sourceFrame.length) {
      srcW = matrixW;
      srcH = matrixH;
    }
  }

  // Source crop rectangle in pixel coordinates (floating point for precision)
  final cxStartF = cropL * srcW;
  final cyStartF = cropT * srcH;
  final cWidthF = cropW * srcW;
  final cHeightF = cropH * srcH;

  // Step size: how many source pixels each bubble pixel covers
  final xStep = cWidthF / bubbleW;
  final yStep = cHeightF / bubbleH;

  for (int by = 0; by < bubbleH; by++) {
    final destY = bubbleY + by;
    if (destY < 0 || destY >= matrixH) continue;
    final destRowBase = destY * matrixW;

    // Source Y range for this bubble row
    final srcYStartF = cyStartF + by * yStep;
    final srcYEndF = srcYStartF + yStep;
    final srcYStart = srcYStartF.floor().clamp(0, srcH - 1);
    final srcYEnd = srcYEndF.ceil().clamp(srcYStart + 1, srcH);

    for (int bx = 0; bx < bubbleW; bx++) {
      final destX = bubbleX + bx;
      if (destX < 0 || destX >= matrixW) continue;

      // Source X range for this bubble pixel
      final srcXStartF = cxStartF + bx * xStep;
      final srcXEndF = srcXStartF + xStep;
      final srcXStart = srcXStartF.floor().clamp(0, srcW - 1);
      final srcXEnd = srcXEndF.ceil().clamp(srcXStart + 1, srcW);

      int rSum = 0, gSum = 0, bSum = 0, count = 0;

      for (int sy = srcYStart; sy < srcYEnd; sy++) {
        final rowBase = sy * srcW;
        for (int sx = srcXStart; sx < srcXEnd; sx++) {
          final idx = (rowBase + sx) * 3;
          if (idx + 2 < sourceFrame.length) {
            rSum += sourceFrame[idx];
            gSum += sourceFrame[idx + 1];
            bSum += sourceFrame[idx + 2];
            count++;
          }
        }
      }

      if (count > 0) {
        // Centre pixel for the sharp component (nearest-neighbour)
        final srcCX = (cxStartF + (bx + 0.5) * xStep).round().clamp(0, srcW - 1);
        final srcCY = (cyStartF + (by + 0.5) * yStep).round().clamp(0, srcH - 1);
        final sharpIdx = (srcCY * srcW + srcCX) * 3;

        // 85% sharp + 15% blurred
        const blurW = 0.15;
        const sharpW = 0.85;
        final dstIdx = (destRowBase + destX) * 3;
        if (dstIdx + 2 < fullFrame.length && sharpIdx + 2 < sourceFrame.length) {
          fullFrame[dstIdx]     = (sharpW * sourceFrame[sharpIdx]     + blurW * rSum / count).round();
          fullFrame[dstIdx + 1] = (sharpW * sourceFrame[sharpIdx + 1] + blurW * gSum / count).round();
          fullFrame[dstIdx + 2] = (sharpW * sourceFrame[sharpIdx + 2] + blurW * bSum / count).round();
        }
      }
    }
  }

  // Apply brightness scaling (0.05–3.0)
  if (brightness != 1.0) {
    for (int i = 0; i < fullFrame.length; i++) {
      fullFrame[i] = (fullFrame[i] * brightness).round().clamp(0, 255);
    }
  }

  return fullFrame;
}

/// Page for casting a selected portion of the screen as a draggable/resizable
/// bubble overlay on the LED curtain. The rest of the curtain remains black
/// (transparent to FPP overlay), allowing the existing pattern to show through.
class CastBubblePage extends ConsumerStatefulWidget {
  const CastBubblePage({super.key});

  @override
  ConsumerState<CastBubblePage> createState() => _CastBubblePageState();
}

class _CastBubblePageState extends ConsumerState<CastBubblePage>
    with WidgetsBindingObserver {
  bool isCapturing = false;
  bool isInitializing = false;
  String statusMessage = 'Ready';
  int frameCount = 0;
  double currentFps = 0.0;
  bool _overlayActive = false;
  double _brightness = 1.0;

  static const _channel = MethodChannel('com.twinklywall.led_matrix_controller/screen_capture');

  // Screen crop selection (normalized 0-1 coordinates)
  // Default matches 90:50 aspect in 360×640 capture: (0.8*360)/(0.25*640) = 1.8
  Rect _cropRect = const Rect.fromLTWH(0.1, 0.3, 0.8, 0.25);

  /// Aspect ratio (width/height) of the bubble on the LED curtain.
  /// Locked to 90:50 = 1.8 to match the curtain. The compose function
  /// independently maps X/Y from crop→bubble, so content renders correctly
  /// regardless of capture-space distortion.
  double get _cropAspect => 90.0 / 50.0;

  /// Applies a new crop rect (from overlay or full-screen toggle).
  void _applyCropRect(Rect rect) {
    const aspect = 90.0 / 50.0;
    final currentSize = ref.read(bubbleSizeProvider);
    var newH = currentSize.width / aspect;
    var newW = currentSize.width;
    // If height would exceed curtain, clamp and recompute width
    if (newH > 50) {
      newH = 50;
      newW = newH * aspect;
    }
    newW = newW.clamp(4.0, 90.0);
    newH = (newW / aspect).clamp(4.0, 50.0);
    final newSize = Size(newW, newH);
    final currentPos = ref.read(bubblePositionProvider);
    final clampedPos = Offset(
      currentPos.dx.clamp(0.0, 90.0 - newSize.width),
      currentPos.dy.clamp(0.0, 50.0 - newSize.height),
    );
    setState(() { _cropRect = rect; });
    ref.read(bubbleSizeProvider.notifier).state = newSize;
    ref.read(bubblePositionProvider.notifier).state = clampedPos;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handleMethodCall);
    logger.info('Cast Bubble page initialized', module: 'UI');
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'stopCast' && isCapturing) {
      logger.info('Overlay X button — stopping cast', module: 'CAST');
      await _stopCapture();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stop casting and close overlay when phone sleeps or app is backgrounded
    if (state == AppLifecycleState.paused && isCapturing) {
      logger.info('App paused (screen off?) — stopping cast', module: 'CAST');
      _stopCapture();
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _toggleCapture() async {
    if (isCapturing) {
      await _stopCapture();
    } else {
      await _startCapture();
    }
  }

  Future<void> _startCapture() async {
    setState(() {
      isInitializing = true;
      statusMessage = '🔄 Starting capture...';
    });

    try {
      logger.info('Requesting screen capture (Android: 360x640)', module: 'CAST');

      // On Android, start capture at higher resolution for cropping
      final success = await PlatformScreenCaptureService.startCapture(
        captureWidth: Platform.isAndroid ? 360 : null,
        captureHeight: Platform.isAndroid ? 640 : null,
      );

      if (!success) {
        logger.error('startCapture returned false', module: 'CAST');
        setState(() {
          isInitializing = false;
          statusMessage = '❌ Failed to start capture';
        });
        return;
      }

      logger.success('Screen capture started', module: 'CAST');

      // Brief delay to let the MediaProjection stabilize
      await Future.delayed(const Duration(milliseconds: 500));

      setState(() {
        isInitializing = false;
        isCapturing = true;
        statusMessage = '✅ Capture started';
      });

      // Auto-show overlay on Android
      if (Platform.isAndroid) {
        await _showOverlay();
      }

      _startBubbleMirroringLoop();
    } catch (e, stackTrace) {
      logger.error('startCapture exception: $e', module: 'CAST');
      logger.error('Stack: ${stackTrace.toString().split('\n').take(5).join('\n')}', module: 'CAST');
      setState(() {
        isInitializing = false;
        statusMessage = '❌ Error: $e';
      });
    }
  }

  Future<void> _stopCapture() async {
    logger.info('Stopping bubble cast', module: 'CAST');
    setState(() { isCapturing = false; });

    // Auto-hide overlay
    if (_overlayActive) {
      await _hideOverlay();
    }

    try {
      await PlatformScreenCaptureService.stopCapture();
      DDPSender.disposeStatic();
    } catch (e) {
      logger.error('Error stopping capture: $e', module: 'CAST');
    }
    setState(() {
      statusMessage = '✅ Stopped ($frameCount frames sent)';
    });
  }

  Future<void> _startBubbleMirroringLoop() async {
    final fppIp = ref.read(fppIpProvider);
    final fppPort = ref.read(fppDdpPortProvider);
    final fallbackPort = fppPort == 4048 ? null : 4048;

    DDPSender.setDebugLevel(1);
    logger.info('Starting bubble cast loop: $fppIp:$fppPort', module: 'CAST');

    const targetIntervalMs = 25; // 40 FPS
    final stopwatch = Stopwatch()..start();
    int nextFrameTargetMs = targetIntervalMs;
    int localFrameCount = 0;
    // Only count real service errors, not null frames (which are normal on Android
    // when acquireLatestImage() returns null between screen refreshes)
    int serviceFailures = 0;
    const maxServiceFailures = 60;
    // Null frame tracking: only abort if we get zero good frames for >10 seconds
    DateTime? lastGoodFrameTime;
    const nullFrameTimeoutSeconds = 10;

    // Cache last composed frame to re-send on null capture (screen not refreshed)
    Uint8List? lastComposedFrame;

    int totalMsAcc = 0;
    int captureMsAcc = 0;
    int sendMsAcc = 0;

    while (isCapturing) {
      try {
        final frameStart = stopwatch.elapsedMilliseconds;

        // Read crop rect — if overlay is active, pull from native
        if (_overlayActive) {
          try {
            final state = await _channel.invokeMethod('getOverlayBubble');
            if (state is Map && state['active'] == true) {
              final newCrop = Rect.fromLTWH(
                (state['cropLeft'] as num).toDouble(),
                (state['cropTop'] as num).toDouble(),
                (state['cropWidth'] as num).toDouble(),
                (state['cropHeight'] as num).toDouble(),
              );
              _cropRect = newCrop;
            } else {
              _overlayActive = false;
            }
          } catch (_) {}
        }

        // Read bubble position/size from providers
        final bubblePos = ref.read(bubblePositionProvider);
        final bubbleSize = ref.read(bubbleSizeProvider);
        final bubbleX = bubblePos.dx.round();
        final bubbleY = bubblePos.dy.round();
        final bubbleW = bubbleSize.width.round();
        final bubbleH = bubbleSize.height.round();

        final screenshotStart = DateTime.now();
        final rawFrame = await PlatformScreenCaptureService.captureFrame();
        final captureMs = DateTime.now().difference(screenshotStart).inMilliseconds;

        Uint8List? fullFrame;

        if (rawFrame != null) {
          if (localFrameCount == 0) {
            logger.info('First frame received! ${rawFrame.length} bytes, captureMs=$captureMs', module: 'CAST');
          }
          // Got a real new frame — reset trackers
          lastGoodFrameTime = DateTime.now();
          serviceFailures = 0;

          // Offload heavy pixel work to a background isolate
          fullFrame = await compute(_composeBubbleFrameIsolate, {
            'source': rawFrame,
            'bx': bubbleX,
            'by': bubbleY,
            'bw': bubbleW,
            'bh': bubbleH,
            'cl': _cropRect.left,
            'ct': _cropRect.top,
            'cw': _cropRect.width,
            'ch': _cropRect.height,
            'brightness': _brightness,
          });
          lastComposedFrame = fullFrame;
        } else {
          // Null frame = screen hasn't changed since last poll (normal on Android).
          // Reuse the last composed frame to keep the LED wall updated.
          fullFrame = lastComposedFrame;

          // Only abort if we've had zero good frames for too long (service died)
          if (lastGoodFrameTime == null) {
            serviceFailures++;
            // Log diagnostics periodically while waiting for first frame
            if (serviceFailures == 10 || serviceFailures == 30 || serviceFailures == 50) {
              final debugInfo = await PlatformScreenCaptureService.captureDebugInfo();
              logger.warn('Waiting for first frame (attempt $serviceFailures/60): nativeDebug=$debugInfo', module: 'CAST');
            }
            if (serviceFailures >= maxServiceFailures) {
              // Get full diagnostic info before aborting
              final debugInfo = await PlatformScreenCaptureService.captureDebugInfo();
              logger.error('No frames received after ${maxServiceFailures} attempts — capture may have failed. Debug: $debugInfo', module: 'CAST');
              if (mounted) setState(() { statusMessage = '❌ No frames from capture service'; });
              break;
            }
          } else {
            final elapsed = DateTime.now().difference(lastGoodFrameTime!).inSeconds;
            if (elapsed >= nullFrameTimeoutSeconds) {
              logger.error('No new frames for ${elapsed}s — capture stalled', module: 'CAST');
              if (mounted) setState(() { statusMessage = '❌ Capture stalled (${elapsed}s no frames)'; });
              break;
            }
          }

          // No frame to send yet — wait and retry
          if (fullFrame == null) {
            await Future.delayed(const Duration(milliseconds: 50));
            continue;
          }
        }

        // Send to FPP
        final sendStart = DateTime.now();
        final sentPrimary = await DDPSender.sendFrameStatic(fppIp, fullFrame!, port: fppPort);
        if (fallbackPort != null) {
          await DDPSender.sendFrameStatic(fppIp, fullFrame, port: fallbackPort);
        }
        final sendMs = DateTime.now().difference(sendStart).inMilliseconds;

        if (!sentPrimary) {
          serviceFailures++;
          if (serviceFailures >= maxServiceFailures) {
            if (mounted) setState(() { statusMessage = '❌ Cannot reach FPP at $fppIp:$fppPort'; });
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        if (rawFrame != null) {
          // Only count FPS/stats on real new frames
          localFrameCount++;
          captureMsAcc += captureMs;
          sendMsAcc += sendMs;

          final totalMs = stopwatch.elapsedMilliseconds - frameStart;
          totalMsAcc += totalMs;

          if (localFrameCount % 20 == 0 && mounted) {
            final avgFps = 20000 / (totalMsAcc > 0 ? totalMsAcc : 1);
            final avgCaptureMs = (captureMsAcc / 20).toStringAsFixed(1);
            final avgSendMs = (sendMsAcc / 20).toStringAsFixed(1);
            totalMsAcc = 0;
            captureMsAcc = 0;
            sendMsAcc = 0;
            setState(() {
              frameCount = localFrameCount;
              currentFps = avgFps;
              statusMessage = '📺 ${avgFps.toStringAsFixed(1)} FPS | Capture: ${avgCaptureMs}ms | Send: ${avgSendMs}ms';
            });
          }
        }

        // Pace to target FPS
        final waitMs = nextFrameTargetMs - stopwatch.elapsedMilliseconds;
        if (waitMs > 0) {
          await Future.delayed(Duration(milliseconds: waitMs));
        }
        nextFrameTargetMs += targetIntervalMs;
        if (stopwatch.elapsedMilliseconds > nextFrameTargetMs) {
          nextFrameTargetMs = stopwatch.elapsedMilliseconds + targetIntervalMs;
        }
      } catch (e, stackTrace) {
        serviceFailures++;
        logger.error('Cast loop error ($serviceFailures): $e', module: 'CAST');
        logger.error('Stack: ${stackTrace.toString().split('\n').take(5).join('\n')}', module: 'CAST');
        if (serviceFailures >= maxServiceFailures) {
          if (mounted) setState(() { statusMessage = '❌ Error: $e'; });
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
    }

    if (mounted) {
      setState(() { frameCount = localFrameCount; });
    }
    logger.info('Bubble cast loop ended ($localFrameCount frames)', module: 'CAST');

    // If the loop exited unexpectedly (error break) while the UI still shows
    // casting as active, run a proper stop to close the DDP socket and release
    // the screen capture service.
    if (mounted && isCapturing) {
      logger.warn('Loop exited while isCapturing=true — running cleanup', module: 'CAST');
      await _stopCapture();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bubblePos = ref.watch(bubblePositionProvider);
    final bubbleSize = ref.watch(bubbleSizeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cast Bubble'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Card
            _buildStatusCard(),
            const SizedBox(height: 16),

            // Curtain Preview with draggable bubble
            _buildCurtainSection(bubblePos, bubbleSize),
            const SizedBox(height: 16),

            // Bubble Info
            _buildBubbleInfo(bubblePos, bubbleSize),
            const SizedBox(height: 20),

            // Action buttons
            _buildActionButtons(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isCapturing
              ? [Colors.cyan.withOpacity(0.2), Colors.cyan.withOpacity(0.1)]
              : [Colors.grey.withOpacity(0.2), Colors.grey.withOpacity(0.1)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCapturing ? Colors.cyan.withOpacity(0.5) : Colors.grey.withOpacity(0.3),
          width: 2,
        ),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCapturing ? Colors.cyan.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
              border: Border.all(color: isCapturing ? Colors.cyan : Colors.grey, width: 2),
            ),
            child: Center(
              child: isInitializing
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(
                      isCapturing ? Icons.picture_in_picture : Icons.picture_in_picture_alt,
                      size: 24,
                      color: isCapturing ? Colors.cyan : Colors.grey,
                    ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCapturing ? 'CASTING BUBBLE' : 'IDLE',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isCapturing ? Colors.cyan : Colors.grey,
                    letterSpacing: 1.5,
                  ),
                ),
                if (isCapturing && currentFps > 0)
                  Text(
                    '${currentFps.toStringAsFixed(1)} FPS • $frameCount frames',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                const SizedBox(height: 4),
                Text(
                  statusMessage,
                  style: TextStyle(fontSize: 11, color: _getStatusColor()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurtainSection(Offset bubblePos, Size bubbleSize) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.grid_on, size: 18, color: Colors.cyan),
              const SizedBox(width: 8),
              const Text(
                'LED Curtain — Drag & Resize Bubble',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Drag the bubble to position it. Use corner handles to resize.',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: CurtainPreview(
              bubblePosition: bubblePos,
              bubbleSize: bubbleSize,
              cropAspect: _cropAspect,
              onBubbleChanged: (pos, size) {
                ref.read(bubblePositionProvider.notifier).state = pos;
                ref.read(bubbleSizeProvider.notifier).state = size;
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBubbleInfo(Offset pos, Size size) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildInfoItem('Position', '${pos.dx.round()}, ${pos.dy.round()}'),
          _buildInfoItem('Size', '${size.width.round()} × ${size.height.round()}'),
          _buildInfoItem('Pixels', '${(size.width * size.height).round()}'),
        ],
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.cyan)),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Brightness slider
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.brightness_6, size: 18, color: Colors.cyan),
              const SizedBox(width: 8),
              const Text('Brightness:'),
              Expanded(
                child: Slider(
                  value: _brightness,
                  min: 0.05,
                  max: 3.0,
                  divisions: 59,
                  label: '${(_brightness * 100).round()}%',
                  onChanged: (v) => setState(() => _brightness = v),
                ),
              ),
              SizedBox(
                width: 48,
                child: Text('${(_brightness * 100).round()}%',
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Desktop-only: full-screen toggle
        if (!Platform.isAndroid && !Platform.isIOS) ...[
          SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: isCapturing ? null : () {
                setState(() {
                  _cropRect = const Rect.fromLTWH(0.0, 0.0, 1.0, 1.0);
                });
                ref.read(bubblePositionProvider.notifier).state = const Offset(0, 0);
                ref.read(bubbleSizeProvider.notifier).state = const Size(90.0, 50.0);
              },
              icon: const Icon(Icons.fullscreen, size: 22),
              label: const Text('Full Screen', style: TextStyle(fontSize: 14)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.cyan,
                side: const BorderSide(color: Colors.cyan),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: !isInitializing ? _toggleCapture : null,
            icon: isInitializing
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(isCapturing ? Icons.stop : Icons.play_arrow, size: 26),
            label: Text(
              isCapturing ? 'Stop Cast' : 'Start Cast',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isCapturing ? Colors.red : Colors.cyan,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showOverlay() async {
    try {
      // Check overlay permission first on Android
      if (Platform.isAndroid) {
        final canDraw = await _channel.invokeMethod('canDrawOverlays') as bool? ?? false;
        if (!canDraw) {
          if (!mounted) return;
          final shouldOpen = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Permission Required'),
              content: const Text(
                'TwinklyWall needs the "Display over other apps" permission to show the crop overlay.\n\n'
                'Please enable it in the next screen, then return here.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );
          if (shouldOpen != true) return;
        }
      }

      await _channel.invokeMethod('showOverlay', {
        'cropLeft': _cropRect.left,
        'cropTop': _cropRect.top,
        'cropWidth': _cropRect.width,
        'cropHeight': _cropRect.height,
      });
      setState(() { _overlayActive = true; });
      logger.info('Overlay shown', module: 'UI');
    } on PlatformException catch (e) {
      logger.error('Overlay error: ${e.message}', module: 'UI');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Overlay permission required')),
        );
      }
    }
  }

  Future<void> _hideOverlay() async {
    try {
      // Pull final crop state from overlay before closing
      final state = await _channel.invokeMethod('getOverlayBubble');
      if (state is Map && state['active'] == true) {
        _applyCropRect(Rect.fromLTWH(
          (state['cropLeft'] as num).toDouble(),
          (state['cropTop'] as num).toDouble(),
          (state['cropWidth'] as num).toDouble(),
          (state['cropHeight'] as num).toDouble(),
        ));
      }
      await _channel.invokeMethod('hideOverlay');
      setState(() { _overlayActive = false; });
      logger.info('Overlay hidden', module: 'UI');
    } catch (e) {
      logger.error('Error hiding overlay: $e', module: 'UI');
    }
  }

  Color _getStatusColor() {
    if (isCapturing) return Colors.cyan;
    if (statusMessage.contains('❌')) return Colors.red;
    if (statusMessage.contains('⚠️')) return Colors.orange;
    return Colors.blue;
  }
}

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:async/async.dart';
import 'package:image/image.dart' as img;

/// Persistent FFmpeg stream for continuous screen capture
/// Keeps FFmpeg running and streams raw RGB data for multiple frames
class ScreenCaptureService {
  static const platform = MethodChannel('com.twinklywall.led_matrix_controller/screen_capture');
  
  static bool _isCapturingDesktop = false;
  static Process? _ffmpegProcess;
  static bool _streamInitialized = false;
  static Uint8List _stdoutRemainder = Uint8List(0);
  static StreamQueue<List<int>>? _stdoutQueue;
  
  // Frame dimensions - will auto-detect from display
  static int _screenWidth = 1920;
  static int _screenHeight = 1080;
  static const int _targetWidth = 90;
  static const int _targetHeight = 50;
  static const int _bytesPerPixel = 3; // RGB24
  static const int _targetFrameSize = _targetWidth * _targetHeight * _bytesPerPixel;

  /// Start capturing the screen
  static Future<bool> startCapture() async {
    try {
      if (Platform.isAndroid) {
        await platform.invokeMethod('startScreenCapture');
        return true;
      } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        _isCapturingDesktop = true;
        debugPrint("[START] Desktop screen capture started");
        
        // Detect screen size
        await _detectScreenSize();
        
        // Start persistent FFmpeg stream
        final success = await _startFFmpegStream();
        if (success) {
          _streamInitialized = true;
          debugPrint("[START] FFmpeg stream initialized successfully");
        } else {
          debugPrint("[START] Failed to initialize FFmpeg stream");
          return false;
        }
        
        return true;
      } else {
        debugPrint("[START] Screen capture not supported on ${Platform.operatingSystem}");
        return false;
      }
    } on PlatformException catch (e) {
      debugPrint("[START] Failed to start screen capture: '${e.message}'");
      return false;
    }
  }

  /// Detect screen resolution using xrandr
  static Future<void> _detectScreenSize() async {
    try {
      final result = await Process.run('xrandr', []).timeout(const Duration(seconds: 2));
      final output = result.stdout.toString();
      
      // Parse xrandr output for primary display resolution
      // Format: "HDMI-1 connected primary 1920x1080+0+0"
      final lines = output.split('\n');
      for (final line in lines) {
        if (line.contains('connected primary')) {
          final match = RegExp(r'(\d+)x(\d+)').firstMatch(line);
          if (match != null) {
            _screenWidth = int.parse(match.group(1)!);
            _screenHeight = int.parse(match.group(2)!);
            debugPrint("[DETECT] Screen size: ${_screenWidth}x${_screenHeight}");
            return;
          }
        }
      }
    } catch (e) {
      debugPrint("[DETECT] Could not detect screen size: $e, using default 1920x1080");
    }
  }

  /// Start persistent FFmpeg process that streams raw RGB data
  static Future<bool> _startFFmpegStream() async {
    try {
      debugPrint("[FFMPEG] Starting persistent stream");
      debugPrint("[FFMPEG] Display: :0.0, Capture: ${_screenWidth}x${_screenHeight}, Output: ${_targetWidth}x${_targetHeight}");
      
      // Kill any existing process
      _ffmpegProcess?.kill();
      await _stdoutQueue?.cancel();
      _stdoutQueue = null;
      
      // Start FFmpeg with x11grab, downscale and output raw RGB24 to stdout
      // Low latency flags keep buffering minimal so reads stay aligned
      final display = Platform.environment['DISPLAY'] ?? ':0.0';
      debugPrint("[FFMPEG] Using display: $display");
      _ffmpegProcess = await Process.start(
        'ffmpeg',
        [
          '-hide_banner',
          '-loglevel', 'info',           // Show info to debug
          '-nostdin',                    // Do not wait on stdin
          '-fflags', 'nobuffer',         // Reduce buffering
          '-flags', 'low_delay',
          '-rtbufsize', '0',
          '-probesize', '32',
          '-analyzeduration', '0',
          '-flush_packets', '1',
          '-f', 'x11grab',                // X11 screen capture input
          '-video_size', '${_screenWidth}x${_screenHeight}',
          '-framerate', '60',             // Higher source framerate to reduce frame wait time
          '-vsync', '0',                  // Do not sync to timestamps
          '-i', display,                  // X11 display from env
          '-vf', 'scale=${_targetWidth}:${_targetHeight}:flags=fast_bilinear', // Downscale before output
          '-pix_fmt', 'rgb24',            // Output format: RGB24 (3 bytes per pixel)
          '-f', 'rawvideo',               // Raw video output format
          'pipe:1'                        // Write to stdout
        ],
      );
      
      if (_ffmpegProcess == null) {
        debugPrint("[FFMPEG] Failed to start process");
        return false;
      }

      _stdoutQueue = StreamQueue(_ffmpegProcess!.stdout);
      
      // Log stderr for debugging
      _ffmpegProcess!.stderr.transform(utf8.decoder).listen((data) {
        debugPrint("[FFMPEG STDERR] $data");
      });
      
      // Log when process exits
      _ffmpegProcess!.exitCode.then((code) {
        debugPrint("[FFMPEG] Process exited with code: $code");
      });
      
      debugPrint("[FFMPEG] Process started, PID: ${_ffmpegProcess!.pid}");
      return true;
    } catch (e) {
      debugPrint("[FFMPEG] Failed to start stream: $e");
      return false;
    }
  }

  /// Stop capturing the screen
  static Future<bool> stopCapture() async {
    try {
      if (Platform.isAndroid) {
        await platform.invokeMethod('stopScreenCapture');
        return true;
      } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        _isCapturingDesktop = false;
        _streamInitialized = false;
        _stdoutRemainder = Uint8List(0);
        final queue = _stdoutQueue;
        _stdoutQueue = null;
        if (queue != null) {
          try {
            await queue.cancel(immediate: true);
          } catch (_) {
            // Ignore cancellation errors
          }
        }
        
        // Kill FFmpeg process
        if (_ffmpegProcess != null) {
          _ffmpegProcess!.kill();
          _ffmpegProcess = null;
          debugPrint("[STOP] FFmpeg process killed");
        }
        
        debugPrint("[STOP] Desktop screen capture stopped");
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint("[STOP] Failed to stop screen capture: '${e.message}'");
      return false;
    }
  }

  /// Check if screen is currently being captured
  static Future<bool> isCapturing() async {
    try {
      if (Platform.isAndroid) {
        final bool result = await platform.invokeMethod('isCapturing');
        return result;
      } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        return _isCapturingDesktop && _streamInitialized && _ffmpegProcess != null;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint("[STATUS] Failed to check capture status: '${e.message}'");
      return false;
    }
  }

  /// Capture a single screenshot from the persistent stream
  static Future<Uint8List?> captureScreenshot() async {
    final startTime = DateTime.now();
    debugPrint("[CAPTURE] ======== NEW FRAME ========");
    
    try {
      if (Platform.isAndroid) {
        final result = await platform.invokeMethod('captureScreenshot');
        if (result is Uint8List) {
          return result;
        }
        return null;
      } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        if (!_streamInitialized || _ffmpegProcess == null) {
          debugPrint("[CAPTURE] Stream not initialized!");
          return null;
        }
        
        // Read one frame from FFmpeg stdout
        final frameData = await _readFrameFromStream();
        if (frameData == null) {
          return null;
        }
        
        final totalTime = DateTime.now().difference(startTime);
        debugPrint("[CAPTURE] Total frame time: ${totalTime.inMilliseconds}ms");
        
        // Process the raw RGB data
        return await _processRawRGBData(frameData);
      }
      return null;
    } catch (e) {
      debugPrint("[CAPTURE] Unexpected error: $e");
      return null;
    }
  }

  /// Read one complete frame from FFmpeg stdout
  /// FFmpeg outputs raw RGB24: width * height * 3 bytes per frame
  static Future<Uint8List?> _readFrameFromStream() async {
    final readStartTime = DateTime.now();
    
    try {
      if (_ffmpegProcess == null) {
        debugPrint("[STREAM] Process is null");
        return null;
      }
      final frameSize = _targetFrameSize;
      debugPrint("[STREAM] Reading frame: $frameSize bytes (${_targetWidth}x${_targetHeight} @ 3bpp)");

      // Ensure we have a continuous buffer to pull exact frame sizes
      final builder = BytesBuilder(copy: false);
      if (_stdoutRemainder.isNotEmpty) {
        builder.add(_stdoutRemainder);
      }

      final queue = _stdoutQueue;
      if (queue == null) {
        debugPrint("[STREAM] Queue is null");
        _streamInitialized = false;
        return null;
      }

      while (builder.length < frameSize) {
        try {
          if (!await queue.hasNext) {
            debugPrint("[STREAM] EOF reached or process died");
            _streamInitialized = false;
            return null;
          }
          final chunk = await queue.next;
          if (chunk.isEmpty) {
            debugPrint("[STREAM] Empty chunk encountered");
            continue;
          }
          builder.add(chunk);
        } on StateError catch (e) {
          debugPrint("[STREAM] Queue canceled or closed: $e");
          _streamInitialized = false;
          return null;
        }
      }

      final combined = builder.takeBytes();
      final frameBytes = Uint8List.sublistView(combined, 0, frameSize);
      final remainingLength = combined.length - frameSize;
      _stdoutRemainder = remainingLength > 0
          ? Uint8List.sublistView(combined, frameSize)
          : Uint8List(0);

      final readDuration = DateTime.now().difference(readStartTime);
      // Add a quick checksum to correlate frames with DDP sender logs
      int sum32 = 0;
      for (int i = 0; i < frameBytes.length; i++) {
        sum32 = (sum32 + frameBytes[i]) & 0xFFFFFFFF;
      }
      final isBlackFrame = sum32 == 0;
      debugPrint("[STREAM] Read complete in ${readDuration.inMilliseconds}ms, remainder: ${_stdoutRemainder.length} bytes, checksum(sum32)=$sum32, black=${isBlackFrame}");

      return frameBytes;
    } catch (e) {
      debugPrint("[STREAM] Error reading frame: $e");
      _streamInitialized = false;
      return null;
    }
  }

  /// Process raw RGB24 data: resize to 90x50, return as RGB
  static Future<Uint8List?> _processRawRGBData(Uint8List rgbData) async {
    final processStartTime = DateTime.now();
    debugPrint("[PROCESS] Input: ${rgbData.length} bytes (raw RGB24)");
    
    try {
      // Fast path: FFmpeg already scaled to the target size
      if (rgbData.length == _targetFrameSize) {
        debugPrint("[PROCESS] Using pre-scaled frame (${_targetWidth}x${_targetHeight})");
        return rgbData;
      }

      // Fallback: if FFmpeg output is full resolution, downscale in Dart
      final expectedFullSize = _screenWidth * _screenHeight * _bytesPerPixel;
      if (rgbData.length != expectedFullSize) {
        debugPrint("[PROCESS] Unexpected frame size ${rgbData.length}, expected ${expectedFullSize} or ${_targetFrameSize}");
        return null;
      }

      // Decode raw RGB24 to Image object - create Image from raw RGB bytes
      final decodeStartTime = DateTime.now();
      final image = img.Image(
        width: _screenWidth,
        height: _screenHeight,
      );
      
      // Copy RGB data into image
      var dataOffset = 0;
      for (var y = 0; y < _screenHeight; y++) {
        for (var x = 0; x < _screenWidth; x++) {
          final r = rgbData[dataOffset++];
          final g = rgbData[dataOffset++];
          final b = rgbData[dataOffset++];
          image.setPixelRgba(x, y, r, g, b, 255);
        }
      }
      
      final decodeDuration = DateTime.now().difference(decodeStartTime);
      debugPrint("[PROCESS] Decode: ${decodeDuration.inMilliseconds}ms");

      // Resize to 90x50
      final resizeStartTime = DateTime.now();
      final resized = img.copyResize(
        image,
        width: _targetWidth,
        height: _targetHeight,
        interpolation: img.Interpolation.linear,
      );
      final resizeDuration = DateTime.now().difference(resizeStartTime);
      debugPrint("[PROCESS] Resize: ${resizeDuration.inMilliseconds}ms");

      // Convert to raw RGB data (13,500 bytes: 90 * 50 * 3)
      final convertStartTime = DateTime.now();
      final outputSize = _targetFrameSize;
      final rgbOutput = Uint8List(outputSize);
      var outputOffset = 0;

      for (final pixel in resized) {
        rgbOutput[outputOffset++] = pixel.r.toInt();
        rgbOutput[outputOffset++] = pixel.g.toInt();
        rgbOutput[outputOffset++] = pixel.b.toInt();
      }
      final convertDuration = DateTime.now().difference(convertStartTime);
      debugPrint("[PROCESS] RGB conversion: ${convertDuration.inMilliseconds}ms");

      final totalProcessDuration = DateTime.now().difference(processStartTime);
      debugPrint("[PROCESS] Total processing: ${totalProcessDuration.inMilliseconds}ms");
      debugPrint("[PROCESS] Output: ${rgbOutput.length} bytes");
      
      return rgbOutput;
    } catch (e) {
      debugPrint("[PROCESS] Error: $e");
      return null;
    }
  }
}

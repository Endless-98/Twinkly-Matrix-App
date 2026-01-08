import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as Math;
import 'package:async/async.dart';
import 'package:image/image.dart' as img;
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import '../providers/app_state.dart';

/// Persistent FFmpeg stream for continuous screen capture
/// Keeps FFmpeg running and streams raw RGB data for multiple frames
class ScreenCaptureService {
  static const platform = MethodChannel('com.twinklywall.led_matrix_controller/screen_capture');
  
  static bool _isCapturingDesktop = false;
  static Process? _ffmpegProcess;
  static bool _streamInitialized = false;
  static Uint8List _stdoutRemainder = Uint8List(0);
  static StreamQueue<List<int>>? _stdoutQueue;
  static bool _receivedFirstFrame = false;
  static Uint8List? _preFrameBuffer;
  static Uint8List? _outFrameBuffer;
  static Uint8List? _gammaLut;
  
  // Frame dimensions - will auto-detect from display
  static int _screenWidth = 1920;
  static int _screenHeight = 1080;
  static const int _targetWidth = 90;
  static const int _targetHeight = 50;
  static const int _bytesPerPixel = 3; // RGB24
  static const int _targetFrameSize = _targetWidth * _targetHeight * _bytesPerPixel;
  // Pre-target capture height to correct LED staggering aspect
  static const int _preTargetHeight = 100;
  static const int _preTargetFrameSize = _targetWidth * _preTargetHeight * _bytesPerPixel;
  
  // Capture mode settings
  static CaptureMode _captureMode = CaptureMode.desktop;
  static String? _selectedWindowTitle;
  static int _regionX = 0;
  static int _regionY = 0;
  static int _regionWidth = 800;
  static int _regionHeight = 600;

  /// Set capture mode
  static void setCaptureMode(CaptureMode mode, {String? windowTitle, int? x, int? y, int? width, int? height}) {
    _captureMode = mode;
    if (mode == CaptureMode.appWindow && windowTitle != null) {
      _selectedWindowTitle = windowTitle;
    } else if (mode == CaptureMode.region) {
      if (x != null) _regionX = x;
      if (y != null) _regionY = y;
      if (width != null) _regionWidth = width;
      if (height != null) _regionHeight = height;
    }
    debugPrint("[CONFIG] Capture mode set to: $mode");
  }

  /// Enumerate available windows (Windows only)
  static Future<List<String>> enumerateWindows() async {
    if (!Platform.isWindows) {
      debugPrint("[WINDOWS] Window enumeration only supported on Windows");
      return [];
    }

    try {
      // Use PowerShell to list only taskbar-visible windows (MainWindowHandle != 0)
      // This filters out background/system/tool windows like Task Manager popups
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r'''
        [System.Diagnostics.Process]::GetProcesses() |
          Where-Object { $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) } |
          Select-Object -ExpandProperty MainWindowTitle
        '''
      ]).timeout(const Duration(seconds: 5));

      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final windows = output
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
        debugPrint("[WINDOWS] Found ${windows.length} taskbar windows");
        return windows;
      } else {
        debugPrint("[WINDOWS] Failed to enumerate: ${result.stderr}");
        return [];
      }
    } catch (e) {
      debugPrint("[WINDOWS] Error enumerating windows: $e");
      return [];
    }
  }

  /// Start capturing the screen
  static Future<bool> startCapture() async {
    try {
      if (Platform.isAndroid) {
        final result = await platform.invokeMethod<bool>('startScreenCapture');
        return result ?? false;
      } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        _isCapturingDesktop = true;
        debugPrint("[START] Desktop screen capture started");
        
        // Log environment info for debugging
        final display = Platform.environment['DISPLAY'] ?? 'not set';
        final sessionType = Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown';
        debugPrint("[START] DISPLAY=$display, XDG_SESSION_TYPE=$sessionType");
        
        if (sessionType == 'wayland') {
          debugPrint("[START] WARNING: Wayland session detected. x11grab may not work. Consider switching to X11 session or running on Windows.");
        }
        
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

  /// Detect screen resolution
  static Future<void> _detectScreenSize() async {
    try {
      if (Platform.isWindows) {
        // On Windows, use PowerShell to get screen resolution
        final result = await Process.run('powershell', [
          '-Command',
          r'[System.Windows.Forms.Screen]::PrimaryScreen.Bounds | Select-Object Width, Height'
        ]).timeout(const Duration(seconds: 2));
        
        final output = result.stdout.toString();
        final widthMatch = RegExp(r'Width\s*:\s*(\d+)').firstMatch(output);
        final heightMatch = RegExp(r'Height\s*:\s*(\d+)').firstMatch(output);
        
        if (widthMatch != null && heightMatch != null) {
          _screenWidth = int.parse(widthMatch.group(1)!);
          _screenHeight = int.parse(heightMatch.group(1)!);
          debugPrint("[DETECT] Windows screen size: ${_screenWidth}x${_screenHeight}");
          return;
        }
      } else {
        // Linux: use xrandr
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
      }
    } catch (e) {
      debugPrint("[DETECT] Could not detect screen size: $e, using default 1920x1080");
    }
  }

  /// Start persistent FFmpeg process that streams raw RGB data
  static Future<bool> _startFFmpegStream() async {
    try {
      debugPrint("[FFMPEG] Starting persistent stream");
      debugPrint("[FFMPEG] Mode: $_captureMode, Capture: ${_screenWidth}x${_screenHeight}, Output: ${_targetWidth}x${_targetHeight}");
      
      // Kill any existing process
      _ffmpegProcess?.kill();
      await _stdoutQueue?.cancel();
      _stdoutQueue = null;
      
      List<String> ffmpegArgs;
      
      if (Platform.isWindows) {
        // Windows: Use gdigrab for screen capture
        debugPrint("[FFMPEG] Using Windows gdigrab input");
        
        // Base args - gdigrab minimal options for continuous capture
        ffmpegArgs = [
          '-hide_banner',
          '-loglevel', 'error',  // Show errors to stderr for diagnostics
          '-nostdin',
          '-f', 'gdigrab',
          '-framerate', '20',  // 20fps target for LED wall
          '-probesize', '32',  // Minimize probe size
          '-fflags', 'nobuffer+flush_packets',  // Disable internal buffering
          '-flags', 'low_delay',  // Low latency mode
        ];
        
        // Mode-specific args
        switch (_captureMode) {
          case CaptureMode.desktop:
            // Capture entire desktop
            ffmpegArgs.addAll([
              '-i', 'desktop',
            ]);
            break;
            
          case CaptureMode.appWindow:
            // Capture specific window by title
            if (_selectedWindowTitle == null || _selectedWindowTitle!.isEmpty) {
              debugPrint("[FFMPEG] No window title specified for app capture");
              return false;
            }
            debugPrint("[FFMPEG] Capturing window: $_selectedWindowTitle");
            ffmpegArgs.addAll([
              '-i', 'title=$_selectedWindowTitle',
            ]);
            break;
            
          case CaptureMode.region:
            // Capture specific region
            debugPrint("[FFMPEG] Capturing region: x=$_regionX, y=$_regionY, ${_regionWidth}x$_regionHeight");
            ffmpegArgs.addAll([
              '-offset_x', '$_regionX',
              '-offset_y', '$_regionY',
              '-video_size', '${_regionWidth}x$_regionHeight',
              '-i', 'desktop',
            ]);
            break;
        }
        
        // Output scaling and format conversion
        // Supersample and fill, then crop to exact 180x200 (no pad error cases):
        // 1) Scale to at least 180x200 (AR increase) with Lanczos
        // 2) Center-crop to 180x200
        // 3) Downscale to 90x100 with Lanczos
        // Keeps full height, trims sides as needed without invalid pad dims.
        final superSampleWidth = _targetWidth * 2;  // 180
        final superSampleHeight = _preTargetHeight * 2;  // 200
        
        ffmpegArgs.addAll([
          '-vf',
          'scale=w=${superSampleWidth}:h=${superSampleHeight}:force_original_aspect_ratio=increase:flags=lanczos,'  // Ensure >=180x200
          'crop=${superSampleWidth}:${superSampleHeight}:(iw-ow)/2:(ih-oh)/2,'  // Center-crop to 180x200
          'scale=${_targetWidth}:${_preTargetHeight}:flags=lanczos,'  // Final downscale with quality filtering
          'format=rgb24',  // Ensure RGB24 format
          '-pix_fmt', 'rgb24',
          '-s', '${_targetWidth}x${_preTargetHeight}',
          '-f', 'rawvideo',
          'pipe:1'
        ]);
      } else {
        // Linux: Use x11grab (only desktop mode supported for now)
        final display = Platform.environment['DISPLAY'] ?? ':0.0';
        debugPrint("[FFMPEG] Using display: $display (Linux x11grab)");
        
        if (_captureMode != CaptureMode.desktop) {
          debugPrint("[FFMPEG] WARNING: Only desktop capture supported on Linux currently");
        }
        
        final superSampleWidth = _targetWidth * 2;  // 180
        final superSampleHeight = _preTargetHeight * 2;  // 200
        
        ffmpegArgs = [
          '-hide_banner',
          '-loglevel', 'info',
          '-nostdin',
          '-fflags', 'nobuffer',
          '-flags', 'low_delay',
          '-rtbufsize', '0',
          '-probesize', '32',
          '-analyzeduration', '0',
          '-flush_packets', '1',
          '-f', 'x11grab',
          '-video_size', '${_screenWidth}x${_screenHeight}',
          '-framerate', '60',
          '-vsync', '0',
          '-i', display,
          '-vf',
          'scale=w=${superSampleWidth}:h=${superSampleHeight}:force_original_aspect_ratio=increase:flags=lanczos,'  // Ensure >=180x200
          'crop=${superSampleWidth}:${superSampleHeight}:(iw-ow)/2:(ih-oh)/2,'  // Center-crop to 180x200
          'scale=${_targetWidth}:${_preTargetHeight}:flags=lanczos,'  // Final downscale with quality filtering
          'format=rgb24',  // Ensure RGB24 format
          '-pix_fmt', 'rgb24',
          '-s', '${_targetWidth}x${_preTargetHeight}',
          '-f', 'rawvideo',
          'pipe:1'
        ];
      }
      
      _ffmpegProcess = await Process.start('ffmpeg', ffmpegArgs);
      
      if (_ffmpegProcess == null) {
        debugPrint("[FFMPEG] Failed to start process");
        return false;
      }

      _stdoutQueue = StreamQueue(_ffmpegProcess!.stdout);
      
      // Log stderr for debugging - FFmpeg errors will help diagnose issues
      var stderrLines = StringBuffer();
      _ffmpegProcess!.stderr.transform(utf8.decoder).listen((data) {
        stderrLines.write(data);
        // Log stderr in chunks to see what FFmpeg is reporting
        if (data.contains('\n')) {
          final lines = stderrLines.toString().split('\n');
          for (final line in lines) {
            if (line.isNotEmpty) {
              debugPrint("[FFMPEG STDERR] $line");
            }
          }
          stderrLines.clear();
        }
      }, onError: (e) {
        debugPrint("[FFMPEG STDERR ERROR] $e");
      });
      
      // Log when process exits
      _ffmpegProcess!.exitCode.then((code) {
        debugPrint("[FFMPEG] Process exited with code: $code");
      });
      
      debugPrint("[FFMPEG] Process started, PID: ${_ffmpegProcess!.pid}");
      // Prepare buffers
      _preFrameBuffer = Uint8List(_preTargetFrameSize);
      _outFrameBuffer = Uint8List(_targetFrameSize);
      _initGammaLut(2.2);
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
        
        // Process the raw RGB data (already scaled by FFmpeg)
        return frameData;  // Skip processing, already in correct format
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
    try {
      if (_ffmpegProcess == null) {
        debugPrint("[STREAM] ERROR: Process is null");
        return null;
      }
      // Read pre-target size (90x100) from FFmpeg
      final frameSize = _preTargetFrameSize;
      final preBuf = _preFrameBuffer ?? Uint8List(_preTargetFrameSize);
      int writeOffset = 0;

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

      // Consume any remainder first
      if (_stdoutRemainder.isNotEmpty && writeOffset < frameSize) {
        final copyLen = (frameSize - writeOffset) < _stdoutRemainder.length
            ? (frameSize - writeOffset)
            : _stdoutRemainder.length;
        preBuf.setRange(writeOffset, writeOffset + copyLen, _stdoutRemainder);
        writeOffset += copyLen;
        _stdoutRemainder = (_stdoutRemainder.length > copyLen)
            ? Uint8List.sublistView(_stdoutRemainder, copyLen)
            : Uint8List(0);
      }

      while (writeOffset < frameSize) {
        try {
          // Use longer timeout for first frame to allow FFmpeg warmup
          final timeout = _receivedFirstFrame
              ? const Duration(milliseconds: 150)
              : const Duration(seconds: 3);
          final hasNext = await queue.hasNext.timeout(timeout);
          if (!hasNext) {
            if (writeOffset > 0) {
              debugPrint("[STREAM] Incomplete frame: ${writeOffset}/$frameSize bytes");
            }
            _streamInitialized = false;
            return null;
          }

          final chunk = await queue.next;
          if (chunk.isEmpty) {
            continue;
          }
          final remaining = frameSize - writeOffset;
          final copyLen = chunk.length <= remaining ? chunk.length : remaining;
          preBuf.setRange(writeOffset, writeOffset + copyLen, chunk);
          writeOffset += copyLen;
          if (chunk.length > copyLen) {
            // Save remainder for next frame
            _stdoutRemainder = Uint8List.fromList(chunk.sublist(copyLen));
          }
        } on StateError catch (e) {
          debugPrint("[STREAM] Queue error: $e");
          _streamInitialized = false;
          return null;
        } on TimeoutException {
          // Don't fail the stream on timeout; just keep waiting
          debugPrint("[STREAM] Waiting for FFmpeg data...");
          continue;
        }
      }

      _receivedFirstFrame = true;

      // Fold + gamma in single pass using LUT
      final outBuf = _outFrameBuffer ?? Uint8List(_targetFrameSize);
      _foldAndGammaInterleave(preBuf, outBuf);
      return outBuf;
    } catch (e) {
      debugPrint("[STREAM] Error reading frame: $e");
      _streamInitialized = false;
      return null;
    }
  }

  /// Initialize gamma LUT for fast per-channel mapping
  static void _initGammaLut(double gamma) {
    final lut = Uint8List(256);
    for (int v = 0; v < 256; v++) {
      lut[v] = (255.0 * Math.pow(v / 255.0, gamma)).round().clamp(0, 255);
    }
    _gammaLut = lut;
  }

  /// Fold 90x100 -> 90x50 and apply gamma via LUT in one pass
  static void _foldAndGammaInterleave(Uint8List pre, Uint8List out) {
    final width = _targetWidth;
    final half = _preTargetHeight ~/ 2; // 50
    final lut = _gammaLut ?? Uint8List(256);

    int outIdx = 0;
    for (int y = 0; y < half; y++) {
      // Match renderer's staggered sampling:
      // - Even columns sample from even source rows: srcY = y*2
      // - Odd columns sample from odd  source rows: srcY = y*2 + 1
      // This preserves the vertical stagger exactly as in the Python renderer.
      final evenRow = y * 2;
      final oddRow = evenRow + 1;
      for (int x = 0; x < width; x++) {
        final srcY = (x % 2 == 0) ? evenRow : oddRow;
        final srcIdx = (srcY * width + x) * 3;
        out[outIdx++] = lut[pre[srcIdx]];
        out[outIdx++] = lut[pre[srcIdx + 1]];
        out[outIdx++] = lut[pre[srcIdx + 2]];
      }
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
      final decodeStartTime = DateTime.now();      final image = img.Image(
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
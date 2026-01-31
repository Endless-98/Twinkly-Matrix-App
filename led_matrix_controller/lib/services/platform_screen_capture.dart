import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:async/async.dart';
import '../providers/app_state.dart';
import 'windows_screen_capture.dart' if (dart.library.io) 'windows_screen_capture.dart';

/// Platform capability information for screen capture
class ScreenCaptureCapabilities {
  final bool supportsDesktopCapture;
  final bool supportsWindowCapture;
  final bool supportsRegionCapture;
  final bool requiresPermission;
  final String platformName;
  final String captureMethod;
  final List<String> limitations;
  final List<String> setupInstructions;

  const ScreenCaptureCapabilities({
    required this.supportsDesktopCapture,
    required this.supportsWindowCapture,
    required this.supportsRegionCapture,
    required this.requiresPermission,
    required this.platformName,
    required this.captureMethod,
    this.limitations = const [],
    this.setupInstructions = const [],
  });
}

/// Capture status with detailed information
class CaptureStatus {
  final bool isCapturing;
  final bool isInitialized;
  final String message;
  final int framesProcessed;
  final double currentFps;
  final String? error;

  const CaptureStatus({
    this.isCapturing = false,
    this.isInitialized = false,
    this.message = 'Ready',
    this.framesProcessed = 0,
    this.currentFps = 0.0,
    this.error,
  });

  CaptureStatus copyWith({
    bool? isCapturing,
    bool? isInitialized,
    String? message,
    int? framesProcessed,
    double? currentFps,
    String? error,
  }) {
    return CaptureStatus(
      isCapturing: isCapturing ?? this.isCapturing,
      isInitialized: isInitialized ?? this.isInitialized,
      message: message ?? this.message,
      framesProcessed: framesProcessed ?? this.framesProcessed,
      currentFps: currentFps ?? this.currentFps,
      error: error,
    );
  }
}

/// Unified platform-aware screen capture service
/// Automatically detects platform and uses the appropriate capture method
class PlatformScreenCaptureService {
  static const _channel = MethodChannel('com.twinklywall.led_matrix_controller/screen_capture');
  
  // State
  static bool _isCapturing = false;
  static bool _isInitialized = false;
  static Process? _ffmpegProcess;
  static StreamQueue<List<int>>? _stdoutQueue;
  static Uint8List _stdoutRemainder = Uint8List(0);
  static bool _receivedFirstFrame = false;
  
  // Frame buffers
  static Uint8List? _preFrameBuffer;
  static Uint8List? _outFrameBuffer;
  static Uint8List? _gammaLut;
  
  // Screen dimensions (auto-detected)
  static int _screenWidth = 1920;
  static int _screenHeight = 1080;
  
  // Output dimensions for LED matrix
  static const int targetWidth = 90;
  static const int targetHeight = 50;
  static const int _bytesPerPixel = 3;
  static const int _targetFrameSize = targetWidth * targetHeight * _bytesPerPixel;
  static const int _preTargetHeight = 100;
  static const int _preTargetFrameSize = targetWidth * _preTargetHeight * _bytesPerPixel;
  
  // Capture settings
  static CaptureMode _captureMode = CaptureMode.desktop;
  static String? _selectedWindowTitle;
  static int _regionX = 0;
  static int _regionY = 0;
  static int _regionWidth = 800;
  static int _regionHeight = 600;
  
  /// Get platform-specific capabilities
  static ScreenCaptureCapabilities getCapabilities() {
    if (Platform.isAndroid) {
      return const ScreenCaptureCapabilities(
        supportsDesktopCapture: true,
        supportsWindowCapture: false,
        supportsRegionCapture: false,
        requiresPermission: true,
        platformName: 'Android',
        captureMethod: 'MediaProjection API',
        limitations: [
          'Requires user permission each session',
          'Only full-screen capture available',
          'Battery usage may increase during capture',
        ],
        setupInstructions: [
          'Tap "Start Mirroring" to begin',
          'Grant screen recording permission when prompted',
          'Keep the app in foreground for best performance',
        ],
      );
    } else if (Platform.isIOS) {
      return const ScreenCaptureCapabilities(
        supportsDesktopCapture: false,
        supportsWindowCapture: false,
        supportsRegionCapture: false,
        requiresPermission: true,
        platformName: 'iOS',
        captureMethod: 'Not Available',
        limitations: [
          'iOS does not allow in-app screen capture',
          'Use AirPlay mirroring instead',
          'Or use the broadcast extension feature',
        ],
        setupInstructions: [
          'Screen capture is not directly available on iOS',
          'Consider using external capture solutions',
        ],
      );
    } else if (Platform.isWindows) {
      return const ScreenCaptureCapabilities(
        supportsDesktopCapture: true,
        supportsWindowCapture: false,
        supportsRegionCapture: false,
        requiresPermission: false,
        platformName: 'Windows',
        captureMethod: 'Native GDI Screen Capture',
        limitations: [
          'Some protected content (DRM) may appear black',
          'Performance depends on display resolution',
        ],
        setupInstructions: [
          'No setup required - just click "Start Mirroring"!',
          '',
          'The app uses native Windows APIs for screen capture.',
          'No additional software installation needed.',
          '',
          'Works on Windows 7 and newer.',
        ],
      );
    } else if (Platform.isLinux) {
      final sessionType = Platform.environment['XDG_SESSION_TYPE'] ?? 'unknown';
      if (sessionType == 'wayland') {
        return ScreenCaptureCapabilities(
          supportsDesktopCapture: true,
          supportsWindowCapture: false,
          supportsRegionCapture: true,
          requiresPermission: true,
          platformName: 'Linux (Wayland)',
          captureMethod: 'PipeWire/Portal (FFmpeg)',
          limitations: const [
            'Window capture not available on Wayland',
            'Portal permission required',
            'Some compositors may have issues',
          ],
          setupInstructions: const [
            'FFmpeg with PipeWire support required',
            'Install: sudo apt install ffmpeg pipewire',
            'Grant permission when portal dialog appears',
          ],
        );
      } else {
        return const ScreenCaptureCapabilities(
          supportsDesktopCapture: true,
          supportsWindowCapture: false,
          supportsRegionCapture: true,
          requiresPermission: false,
          platformName: 'Linux (X11)',
          captureMethod: 'X11 Screen Capture (FFmpeg)',
          limitations: [
            'Window-specific capture not yet implemented',
            'Wayland sessions require different setup',
          ],
          setupInstructions: [
            'FFmpeg must be installed',
            'Install: sudo apt install ffmpeg',
            'Ensure DISPLAY environment is set',
          ],
        );
      }
    } else if (Platform.isMacOS) {
      return const ScreenCaptureCapabilities(
        supportsDesktopCapture: true,
        supportsWindowCapture: true,
        supportsRegionCapture: true,
        requiresPermission: true,
        platformName: 'macOS',
        captureMethod: 'AVFoundation Screen Capture (FFmpeg)',
        limitations: [
          'Screen Recording permission required in System Preferences',
          'Some DRM content may not capture',
        ],
        setupInstructions: [
          'FFmpeg must be installed (brew install ffmpeg)',
          'Enable Screen Recording in System Preferences > Privacy',
          'Restart app after granting permission',
        ],
      );
    }
    
    return const ScreenCaptureCapabilities(
      supportsDesktopCapture: false,
      supportsWindowCapture: false,
      supportsRegionCapture: false,
      requiresPermission: false,
      platformName: 'Unknown',
      captureMethod: 'Not Supported',
      limitations: ['Platform not supported'],
      setupInstructions: [],
    );
  }

  /// Check if the current platform supports screen capture
  static bool isPlatformSupported() {
    return Platform.isAndroid || 
           Platform.isWindows || 
           Platform.isLinux || 
           Platform.isMacOS;
  }

  /// Configure capture mode with optional parameters
  static void setCaptureMode(
    CaptureMode mode, {
    String? windowTitle,
    int? x,
    int? y,
    int? width,
    int? height,
  }) {
    _captureMode = mode;
    if (mode == CaptureMode.appWindow && windowTitle != null) {
      _selectedWindowTitle = windowTitle;
    } else if (mode == CaptureMode.region) {
      if (x != null) _regionX = x;
      if (y != null) _regionY = y;
      if (width != null) _regionWidth = width;
      if (height != null) _regionHeight = height;
    }
    debugPrint('[CAPTURE] Mode set to: $mode');
  }

  /// Get list of capturable windows (platform-dependent)
  static Future<List<String>> getAvailableWindows() async {
    final caps = getCapabilities();
    if (!caps.supportsWindowCapture) {
      return [];
    }

    if (Platform.isWindows) {
      return _enumerateWindowsWindows();
    } else if (Platform.isMacOS) {
      return _enumerateWindowsMacOS();
    }
    
    return [];
  }

  static Future<List<String>> _enumerateWindowsWindows() async {
    try {
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
        return result.stdout.toString()
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList();
      }
    } catch (e) {
      debugPrint('[WINDOWS] Error enumerating windows: $e');
    }
    return [];
  }

  static Future<List<String>> _enumerateWindowsMacOS() async {
    try {
      // Use AppleScript to get window list
      final result = await Process.run('osascript', [
        '-e',
        'tell application "System Events" to get name of every application process whose visible is true'
      ]).timeout(const Duration(seconds: 5));

      if (result.exitCode == 0) {
        return result.stdout.toString()
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (e) {
      debugPrint('[MACOS] Error enumerating windows: $e');
    }
    return [];
  }

  /// Start screen capture
  static Future<bool> startCapture() async {
    if (_isCapturing) {
      debugPrint('[CAPTURE] Already capturing');
      return true;
    }

    try {
      if (Platform.isAndroid) {
        return await _startAndroidCapture();
      } else if (Platform.isWindows) {
        return await _startWindowsCapture();
      } else if (Platform.isLinux) {
        return await _startLinuxCapture();
      } else if (Platform.isMacOS) {
        return await _startMacOSCapture();
      } else if (Platform.isIOS) {
        debugPrint('[CAPTURE] iOS screen capture not supported in-app');
        return false;
      }
      
      return false;
    } catch (e) {
      debugPrint('[CAPTURE] Error starting capture: $e');
      return false;
    }
  }

  /// Stop screen capture
  static Future<bool> stopCapture() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('stopScreenCapture');
      }
      
      // Clean up Windows native capture
      if (Platform.isWindows && _windowsCapture != null) {
        _windowsCapture!.cleanup();
        _windowsCapture = null;
      }
      
      // Common cleanup for desktop platforms using FFmpeg
      _isCapturing = false;
      _isInitialized = false;
      _stdoutRemainder = Uint8List(0);
      _receivedFirstFrame = false;
      
      final queue = _stdoutQueue;
      _stdoutQueue = null;
      if (queue != null) {
        try {
          await queue.cancel(immediate: true);
        } catch (_) {}
      }
      
      if (_ffmpegProcess != null) {
        _ffmpegProcess!.kill();
        _ffmpegProcess = null;
        debugPrint('[CAPTURE] FFmpeg process terminated');
      }
      
      return true;
    } catch (e) {
      debugPrint('[CAPTURE] Error stopping capture: $e');
      return false;
    }
  }

  /// Check if currently capturing
  static Future<bool> isCapturing() async {
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod('isCapturing') ?? false;
      } catch (_) {
        return false;
      }
    }
    if (Platform.isWindows) {
      return _isCapturing && _isInitialized && _windowsCapture != null;
    }
    return _isCapturing && _isInitialized && _ffmpegProcess != null;
  }

  /// Capture a single frame
  static Future<Uint8List?> captureFrame() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('captureScreenshot');
        return result is Uint8List ? result : null;
      }
      
      if (Platform.isWindows) {
        return await _captureWindowsFrame();
      }
      
      if (!_isInitialized || _ffmpegProcess == null) {
        return null;
      }
      
      return await _readFrameFromStream();
    } catch (e) {
      debugPrint('[CAPTURE] Frame capture error: $e');
      return null;
    }
  }

  // ========== ANDROID CAPTURE ==========
  
  static Future<bool> _startAndroidCapture() async {
    try {
      final result = await _channel.invokeMethod<bool>('startScreenCapture');
      _isCapturing = result ?? false;
      _isInitialized = _isCapturing;
      return _isCapturing;
    } on PlatformException catch (e) {
      debugPrint('[ANDROID] Capture failed: ${e.message}');
      return false;
    }
  }

  // ========== WINDOWS CAPTURE (Native FFI) ==========
  
  static WindowsScreenCapture? _windowsCapture;
  
  static Future<bool> _startWindowsCapture() async {
    try {
      // Initialize gamma LUT for processing
      _initGammaLut(2.2);
      _preFrameBuffer = Uint8List(_preTargetFrameSize);
      _outFrameBuffer = Uint8List(_targetFrameSize);
      
      // Create and initialize Windows capture at double height for frame folding
      _windowsCapture = WindowsScreenCapture();
      final success = _windowsCapture!.initialize(targetWidth, _preTargetHeight);
      
      if (!success) {
        debugPrint('[WINDOWS] Failed to initialize native capture');
        _windowsCapture = null;
        return false;
      }
      
      _isCapturing = true;
      _isInitialized = true;
      debugPrint('[WINDOWS] Native screen capture started (${targetWidth}x$_preTargetHeight)');
      return true;
    } catch (e) {
      debugPrint('[WINDOWS] Capture start error: $e');
      _windowsCapture?.cleanup();
      _windowsCapture = null;
      return false;
    }
  }
  
  static int _windowsFrameCount = 0;
  static int _windowsBlackFrames = 0;
  
  static Future<Uint8List?> _captureWindowsFrame() async {
    try {
      if (!_isInitialized || _windowsCapture == null) {
        debugPrint('[WIN_CAPTURE] Not initialized - capture: ${_windowsCapture != null}, init: $_isInitialized');
        return null;
      }
      
      final frameData = _windowsCapture!.captureFrame();
      if (frameData == null) {
        debugPrint('[WIN_CAPTURE] captureFrame returned null');
        return null;
      }
      
      _windowsFrameCount++;
      
      // Check if frame is all black
      int nonZero = 0;
      for (int i = 0; i < frameData.length && nonZero == 0; i++) {
        if (frameData[i] > 0) nonZero++;
      }
      if (nonZero == 0) {
        _windowsBlackFrames++;
      }
      
      // Log every 100 frames
      if (_windowsFrameCount % 100 == 1) {
        debugPrint('[WIN_CAPTURE] Frame $_windowsFrameCount: size=${frameData.length}, black_frames=$_windowsBlackFrames');
      }
      
      // Copy to pre-buffer and apply frame processing (folding for LED layout)
      final preBuf = _preFrameBuffer ?? Uint8List(frameData.length);
      preBuf.setAll(0, frameData);
      
      final outBuf = _outFrameBuffer ?? Uint8List(_targetFrameSize);
      _processFrame(preBuf, outBuf);
      
      return outBuf;
    } catch (e) {
      debugPrint('[WINDOWS] Frame capture error: $e');
      return null;
    }
  }

  // ========== LINUX CAPTURE ==========
  
  static Future<bool> _startLinuxCapture() async {
    await _detectScreenSize();
    
    final sessionType = Platform.environment['XDG_SESSION_TYPE'] ?? 'x11';
    final display = Platform.environment['DISPLAY'] ?? ':0.0';
    
    final args = <String>[
      '-hide_banner',
      '-loglevel', 'error',
      '-nostdin',
      '-fflags', 'nobuffer',
      '-flags', 'low_delay',
      '-probesize', '32',
    ];
    
    if (sessionType == 'wayland') {
      // Wayland: Use PipeWire capture
      debugPrint('[LINUX] Using PipeWire for Wayland session');
      args.addAll([
        '-f', 'pipewire',
        '-framerate', '20',
        '-i', 'default',
      ]);
    } else {
      // X11: Use x11grab
      debugPrint('[LINUX] Using X11 grab on display: $display');
      
      if (_captureMode == CaptureMode.region) {
        args.addAll([
          '-f', 'x11grab',
          '-video_size', '${_regionWidth}x$_regionHeight',
          '-framerate', '20',
          '-i', '$display+$_regionX,$_regionY',
        ]);
      } else {
        args.addAll([
          '-f', 'x11grab',
          '-video_size', '${_screenWidth}x${_screenHeight}',
          '-framerate', '20',
          '-i', display,
        ]);
      }
    }
    
    _addOutputProcessing(args);
    
    return await _startFFmpegProcess(args);
  }

  // ========== MACOS CAPTURE ==========
  
  static Future<bool> _startMacOSCapture() async {
    await _detectScreenSize();
    
    final args = <String>[
      '-hide_banner',
      '-loglevel', 'error',
      '-nostdin',
      '-f', 'avfoundation',
      '-framerate', '20',
      '-capture_cursor', '0',
      '-i', '1:', // Screen capture device
    ];
    
    _addOutputProcessing(args);
    
    return await _startFFmpegProcess(args);
  }

  // ========== COMMON HELPERS ==========
  
  static void _addOutputProcessing(List<String> args) {
    final superWidth = targetWidth * 2;
    final superHeight = _preTargetHeight * 2;
    
    args.addAll([
      '-vf',
      'scale=w=$superWidth:h=$superHeight:force_original_aspect_ratio=increase:flags=lanczos,'
      'crop=$superWidth:$superHeight:(iw-ow)/2:(ih-oh)/2,'
      'scale=$targetWidth:$_preTargetHeight:flags=lanczos,'
      'format=rgb24',
      '-pix_fmt', 'rgb24',
      '-s', '${targetWidth}x$_preTargetHeight',
      '-f', 'rawvideo',
      'pipe:1'
    ]);
  }

  static Future<bool> _startFFmpegProcess(List<String> args) async {
    try {
      debugPrint('[FFMPEG] Starting with ${args.length} arguments');
      
      // Kill existing process
      _ffmpegProcess?.kill();
      await _stdoutQueue?.cancel();
      _stdoutQueue = null;
      
      _ffmpegProcess = await Process.start('ffmpeg', args);
      
      if (_ffmpegProcess == null) {
        return false;
      }
      
      _stdoutQueue = StreamQueue(_ffmpegProcess!.stdout);
      
      // Log stderr for debugging
      _ffmpegProcess!.stderr.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n').where((l) => l.isNotEmpty)) {
          debugPrint('[FFMPEG] $line');
        }
      });
      
      _ffmpegProcess!.exitCode.then((code) {
        debugPrint('[FFMPEG] Exited with code: $code');
        _isCapturing = false;
        _isInitialized = false;
      });
      
      // Initialize buffers
      _preFrameBuffer = Uint8List(_preTargetFrameSize);
      _outFrameBuffer = Uint8List(_targetFrameSize);
      _initGammaLut(2.2);
      
      _isCapturing = true;
      _isInitialized = true;
      
      debugPrint('[FFMPEG] Started successfully, PID: ${_ffmpegProcess!.pid}');
      return true;
    } catch (e) {
      debugPrint('[FFMPEG] Start failed: $e');
      return false;
    }
  }

  static Future<void> _detectScreenSize() async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          r'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::PrimaryScreen.Bounds | Select-Object Width, Height'
        ]).timeout(const Duration(seconds: 3));
        
        final output = result.stdout.toString();
        final widthMatch = RegExp(r'Width\s*:\s*(\d+)').firstMatch(output);
        final heightMatch = RegExp(r'Height\s*:\s*(\d+)').firstMatch(output);
        
        if (widthMatch != null && heightMatch != null) {
          _screenWidth = int.parse(widthMatch.group(1)!);
          _screenHeight = int.parse(heightMatch.group(1)!);
        }
      } else if (Platform.isLinux) {
        final result = await Process.run('xrandr', []).timeout(const Duration(seconds: 2));
        final output = result.stdout.toString();
        
        for (final line in output.split('\n')) {
          if (line.contains('connected primary')) {
            final match = RegExp(r'(\d+)x(\d+)').firstMatch(line);
            if (match != null) {
              _screenWidth = int.parse(match.group(1)!);
              _screenHeight = int.parse(match.group(2)!);
              break;
            }
          }
        }
      } else if (Platform.isMacOS) {
        final result = await Process.run('system_profiler', ['SPDisplaysDataType']).timeout(const Duration(seconds: 3));
        final output = result.stdout.toString();
        final match = RegExp(r'Resolution:\s*(\d+)\s*x\s*(\d+)').firstMatch(output);
        if (match != null) {
          _screenWidth = int.parse(match.group(1)!);
          _screenHeight = int.parse(match.group(2)!);
        }
      }
      
      debugPrint('[DETECT] Screen size: ${_screenWidth}x$_screenHeight');
    } catch (e) {
      debugPrint('[DETECT] Failed to detect screen size: $e');
    }
  }

  static Future<Uint8List?> _readFrameFromStream() async {
    try {
      if (_ffmpegProcess == null || _stdoutQueue == null) {
        return null;
      }
      
      final frameSize = _preTargetFrameSize;
      final preBuf = _preFrameBuffer ?? Uint8List(frameSize);
      int writeOffset = 0;
      
      // Use remainder from previous read
      if (_stdoutRemainder.isNotEmpty) {
        final copyLen = math.min(frameSize, _stdoutRemainder.length);
        preBuf.setRange(0, copyLen, _stdoutRemainder);
        writeOffset = copyLen;
        _stdoutRemainder = _stdoutRemainder.length > copyLen
            ? Uint8List.sublistView(_stdoutRemainder, copyLen)
            : Uint8List(0);
      }
      
      final queue = _stdoutQueue!;
      
      while (writeOffset < frameSize) {
        try {
          final timeout = _receivedFirstFrame
              ? const Duration(milliseconds: 150)
              : const Duration(seconds: 3);
          
          final hasNext = await queue.hasNext.timeout(timeout);
          if (!hasNext) {
            _isInitialized = false;
            return null;
          }
          
          final chunk = await queue.next;
          if (chunk.isEmpty) continue;
          
          final remaining = frameSize - writeOffset;
          final copyLen = math.min(chunk.length, remaining);
          preBuf.setRange(writeOffset, writeOffset + copyLen, chunk);
          writeOffset += copyLen;
          
          if (chunk.length > copyLen) {
            _stdoutRemainder = Uint8List.fromList(chunk.sublist(copyLen));
          }
        } on TimeoutException {
          continue;
        } on StateError {
          _isInitialized = false;
          return null;
        }
      }
      
      _receivedFirstFrame = true;
      
      // Process frame with gamma correction and folding
      final outBuf = _outFrameBuffer ?? Uint8List(_targetFrameSize);
      _processFrame(preBuf, outBuf);
      return outBuf;
    } catch (e) {
      debugPrint('[STREAM] Error: $e');
      _isInitialized = false;
      return null;
    }
  }

  static void _initGammaLut(double gamma) {
    final lut = Uint8List(256);
    for (int v = 0; v < 256; v++) {
      lut[v] = (255.0 * math.pow(v / 255.0, gamma)).round().clamp(0, 255);
    }
    _gammaLut = lut;
  }

  static void _processFrame(Uint8List pre, Uint8List out) {
    final width = targetWidth;
    final half = _preTargetHeight ~/ 2;
    final lut = _gammaLut ?? Uint8List(256);

    int outIdx = 0;
    for (int y = 0; y < half; y++) {
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
}

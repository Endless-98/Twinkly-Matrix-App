import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'app_logger.dart';

// Windows GDI32 and User32 bindings for native screen capture
// This avoids the need for FFmpeg or complex C++ plugins

// Type definitions
typedef HDC = IntPtr;
typedef HWND = IntPtr;
typedef HBITMAP = IntPtr;
typedef HGDIOBJ = IntPtr;
typedef BOOL = Int32;
typedef UINT = Uint32;
typedef DWORD = Uint32;
typedef LONG = Int32;
typedef WORD = Uint16;

// GDI functions
typedef GetDCNative = IntPtr Function(IntPtr hwnd);
typedef GetDCDart = int Function(int hwnd);

typedef ReleaseDCNative = Int32 Function(IntPtr hwnd, IntPtr hdc);
typedef ReleaseDCDart = int Function(int hwnd, int hdc);

typedef CreateCompatibleDCNative = IntPtr Function(IntPtr hdc);
typedef CreateCompatibleDCDart = int Function(int hdc);

typedef DeleteDCNative = Int32 Function(IntPtr hdc);
typedef DeleteDCDart = int Function(int hdc);

typedef CreateCompatibleBitmapNative = IntPtr Function(IntPtr hdc, Int32 width, Int32 height);
typedef CreateCompatibleBitmapDart = int Function(int hdc, int width, int height);

typedef SelectObjectNative = IntPtr Function(IntPtr hdc, IntPtr h);
typedef SelectObjectDart = int Function(int hdc, int h);

typedef DeleteObjectNative = Int32 Function(IntPtr ho);
typedef DeleteObjectDart = int Function(int ho);

typedef BitBltNative = Int32 Function(
  IntPtr hdc, Int32 x, Int32 y, Int32 cx, Int32 cy,
  IntPtr hdcSrc, Int32 x1, Int32 y1, Uint32 rop
);
typedef BitBltDart = int Function(
  int hdc, int x, int y, int cx, int cy,
  int hdcSrc, int x1, int y1, int rop
);

typedef GetDIBitsNative = Int32 Function(
  IntPtr hdc, IntPtr hbm, Uint32 start, Uint32 cLines,
  Pointer<Uint8> lpvBits, Pointer<BITMAPINFO> lpbmi, Uint32 usage
);
typedef GetDIBitsDart = int Function(
  int hdc, int hbm, int start, int cLines,
  Pointer<Uint8> lpvBits, Pointer<BITMAPINFO> lpbmi, int usage
);

typedef GetSystemMetricsNative = Int32 Function(Int32 nIndex);
typedef GetSystemMetricsDart = int Function(int nIndex);

typedef StretchBltNative = Int32 Function(
  IntPtr hdcDest, Int32 xDest, Int32 yDest, Int32 wDest, Int32 hDest,
  IntPtr hdcSrc, Int32 xSrc, Int32 ySrc, Int32 wSrc, Int32 hSrc,
  Uint32 rop
);
typedef StretchBltDart = int Function(
  int hdcDest, int xDest, int yDest, int wDest, int hDest,
  int hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc,
  int rop
);

typedef SetStretchBltModeNative = Int32 Function(IntPtr hdc, Int32 mode);
typedef SetStretchBltModeDart = int Function(int hdc, int mode);

// Window management functions
typedef FindWindowWNative = IntPtr Function(Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName);
typedef FindWindowWDart = int Function(Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName);

typedef GetWindowRectNative = Int32 Function(IntPtr hWnd, Pointer<RECT> lpRect);
typedef GetWindowRectDart = int Function(int hWnd, Pointer<RECT> lpRect);

typedef IsWindowNative = Int32 Function(IntPtr hWnd);
typedef IsWindowDart = int Function(int hWnd);



// RECT structure for window bounds
base class RECT extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

// BITMAPINFOHEADER structure
base class BITMAPINFOHEADER extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

// BITMAPINFO structure (header + color table, we use RGB so no color table needed)
base class BITMAPINFO extends Struct {
  external BITMAPINFOHEADER bmiHeader;
  @Array(4)
  external Array<Uint8> bmiColors;  // Placeholder for RGBQUAD
}

// Constants
const int SRCCOPY = 0x00CC0020;
const int DIB_RGB_COLORS = 0;
const int BI_RGB = 0;
const int SM_CXSCREEN = 0;
const int SM_CYSCREEN = 1;
const int HALFTONE = 4;

/// Capture mode for the GDI capture engine
enum WindowsCaptureMode { desktop, window, region }

/// Native Windows screen capture using GDI
/// No external dependencies required - uses Windows APIs directly via FFI
class WindowsScreenCapture {
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');
  
  // Function bindings
  static final GetDCDart _getDC = _user32
      .lookupFunction<GetDCNative, GetDCDart>('GetDC');
  
  static final ReleaseDCDart _releaseDC = _user32
      .lookupFunction<ReleaseDCNative, ReleaseDCDart>('ReleaseDC');
  
  static final GetSystemMetricsDart _getSystemMetrics = _user32
      .lookupFunction<GetSystemMetricsNative, GetSystemMetricsDart>('GetSystemMetrics');
  
  static final CreateCompatibleDCDart _createCompatibleDC = _gdi32
      .lookupFunction<CreateCompatibleDCNative, CreateCompatibleDCDart>('CreateCompatibleDC');
  
  static final DeleteDCDart _deleteDC = _gdi32
      .lookupFunction<DeleteDCNative, DeleteDCDart>('DeleteDC');
  
  static final CreateCompatibleBitmapDart _createCompatibleBitmap = _gdi32
      .lookupFunction<CreateCompatibleBitmapNative, CreateCompatibleBitmapDart>('CreateCompatibleBitmap');
  
  static final SelectObjectDart _selectObject = _gdi32
      .lookupFunction<SelectObjectNative, SelectObjectDart>('SelectObject');
  
  static final DeleteObjectDart _deleteObject = _gdi32
      .lookupFunction<DeleteObjectNative, DeleteObjectDart>('DeleteObject');
  
  static final BitBltDart _bitBlt = _gdi32
      .lookupFunction<BitBltNative, BitBltDart>('BitBlt');
  
  static final GetDIBitsDart _getDIBits = _gdi32
      .lookupFunction<GetDIBitsNative, GetDIBitsDart>('GetDIBits');
  
  static final StretchBltDart _stretchBlt = _gdi32
      .lookupFunction<StretchBltNative, StretchBltDart>('StretchBlt');
  
  static final SetStretchBltModeDart _setStretchBltMode = _gdi32
      .lookupFunction<SetStretchBltModeNative, SetStretchBltModeDart>('SetStretchBltMode');
  
  // Window management bindings
  static final FindWindowWDart _findWindow = _user32
      .lookupFunction<FindWindowWNative, FindWindowWDart>('FindWindowW');
  
  static final GetWindowRectDart _getWindowRect = _user32
      .lookupFunction<GetWindowRectNative, GetWindowRectDart>('GetWindowRect');
  
  static final IsWindowDart _isWindow = _user32
      .lookupFunction<IsWindowNative, IsWindowDart>('IsWindow');
  

  
  // Cached resources
  int _screenDC = 0;
  int _memDC = 0;
  int _memBitmap = 0;
  int _oldBitmap = 0;
  int _screenWidth = 0;
  int _screenHeight = 0;
  int _targetWidth = 0;
  int _targetHeight = 0;
  bool _isInitialized = false;
  
  // Capture mode settings
  WindowsCaptureMode _captureMode = WindowsCaptureMode.desktop;
  int _targetHwnd = 0;        // For window capture
  int _regionX = 0;           // For region capture
  int _regionY = 0;
  int _regionWidth = 0;
  int _regionHeight = 0;
  Pointer<RECT>? _rectBuffer; // Reusable rect for window queries
  
  Pointer<BITMAPINFO>? _bitmapInfo;
  Pointer<Uint8>? _pixelBuffer;
  
  /// Find a window handle by its exact title
  static int findWindowByTitle(String title) {
    final titlePtr = title.toNativeUtf16();
    final hwnd = _findWindow(Pointer<Utf16>.fromAddress(0), titlePtr);
    malloc.free(titlePtr);
    return hwnd;
  }
  

  /// Check if a window handle is still valid
  static bool isValidWindow(int hwnd) {
    return _isWindow(hwnd) != 0;
  }
  
  /// Initialize the capture system with target dimensions
  bool initialize(
    int targetWidth,
    int targetHeight, {
    WindowsCaptureMode mode = WindowsCaptureMode.desktop,
    int hwnd = 0,
    int regionX = 0,
    int regionY = 0,
    int regionWidth = 0,
    int regionHeight = 0,
  }) {
    if (_isInitialized) {
      cleanup();
    }
    
    try {
      _targetWidth = targetWidth;
      _targetHeight = targetHeight;
      
      // Store capture mode settings
      _captureMode = mode;
      _targetHwnd = hwnd;
      _regionX = regionX;
      _regionY = regionY;
      _regionWidth = regionWidth;
      _regionHeight = regionHeight;
      
      // Get screen dimensions
      _screenWidth = _getSystemMetrics(SM_CXSCREEN);
      _screenHeight = _getSystemMetrics(SM_CYSCREEN);
      
      if (_screenWidth == 0 || _screenHeight == 0) {
        logger.error('Invalid screen size: ${_screenWidth}x$_screenHeight', module: 'GDI');
        return false;
      }
      
      // Validate mode-specific settings
      if (mode == WindowsCaptureMode.window) {
        if (_targetHwnd == 0 || _isWindow(_targetHwnd) == 0) {
          logger.error('Invalid window handle: $_targetHwnd', module: 'GDI');
          return false;
        }
        _rectBuffer = calloc<RECT>();
        logger.info('Window capture mode: hwnd=$_targetHwnd', module: 'GDI');
      } else if (mode == WindowsCaptureMode.region) {
        if (_regionWidth <= 0 || _regionHeight <= 0) {
          logger.error('Invalid region: ${_regionWidth}x$_regionHeight', module: 'GDI');
          return false;
        }
        logger.info('Region capture: $_regionX,$_regionY ${_regionWidth}x$_regionHeight', module: 'GDI');
      }
      
      logger.info('Screen: ${_screenWidth}x$_screenHeight, Target: ${_targetWidth}x$_targetHeight, Mode: $mode', module: 'GDI');
      
      // Get screen DC
      _screenDC = _getDC(0);
      if (_screenDC == 0) {
        logger.error('Failed to get screen DC', module: 'GDI');
        return false;
      }
      logger.success('Got screen DC: $_screenDC', module: 'GDI');
      
      // Create memory DC
      _memDC = _createCompatibleDC(_screenDC);
      if (_memDC == 0) {
        logger.error('Failed to create memory DC', module: 'GDI');
        cleanup();
        return false;
      }
      logger.success('Created memory DC: $_memDC', module: 'GDI');
      
      // Set stretch mode for quality scaling
      final modeSet = _setStretchBltMode(_memDC, HALFTONE);
      logger.info('Set stretch mode: $modeSet', module: 'GDI');
      
      // Create bitmap at target size
      _memBitmap = _createCompatibleBitmap(_screenDC, _targetWidth, _targetHeight);
      if (_memBitmap == 0) {
        logger.error('Failed to create bitmap (${_targetWidth}x${_targetHeight})', module: 'GDI');
        cleanup();
        return false;
      }
      logger.success('Created bitmap: $_memBitmap', module: 'GDI');
      
      // Select bitmap into memory DC
      _oldBitmap = _selectObject(_memDC, _memBitmap);
      if (_oldBitmap == 0) {
        logger.error('Failed to select bitmap into DC', module: 'GDI');
        cleanup();
        return false;
      }
      logger.success('Selected bitmap, old bitmap: $_oldBitmap', module: 'GDI');
      
      // Allocate bitmap info structure
      _bitmapInfo = calloc<BITMAPINFO>();
      _bitmapInfo!.ref.bmiHeader.biSize = sizeOf<BITMAPINFOHEADER>();
      _bitmapInfo!.ref.bmiHeader.biWidth = _targetWidth;
      _bitmapInfo!.ref.bmiHeader.biHeight = -_targetHeight;  // Negative for top-down
      _bitmapInfo!.ref.bmiHeader.biPlanes = 1;
      _bitmapInfo!.ref.bmiHeader.biBitCount = 24;  // RGB
      _bitmapInfo!.ref.bmiHeader.biCompression = BI_RGB;
      
      // Calculate row stride (must be DWORD aligned)
      final rowStride = ((_targetWidth * 3 + 3) & ~3);
      final bufferSize = rowStride * _targetHeight;
      
      // Allocate pixel buffer
      _pixelBuffer = calloc<Uint8>(bufferSize);
      
      _isInitialized = true;
      logger.success('GDI Capture initialized - ready!', module: 'GDI');
      return true;
    } catch (e) {
      logger.error('Init error: $e', module: 'GDI');
      cleanup();
      return false;
    }
  }
  
  // Frame counter for periodic logging
  int _frameCounter = 0;
  int _logInterval = 100;  // Log every N frames
  int _nonBlackFrames = 0;
  
  /// Capture the screen and return RGB data at target resolution
  Uint8List? captureFrame() {
    if (!_isInitialized) {
      logger.error('Capture called but not initialized', module: 'GDI');
      return null;
    }
    
    _frameCounter++;
    final shouldLog = _frameCounter % _logInterval == 1;
    
    if (shouldLog) {
      logger.info('GDI captureFrame() called (frame #$_frameCounter)', module: 'GDI');
    }
    
    try {
      // Determine source rectangle based on capture mode
      int srcX = 0, srcY = 0, srcW = _screenWidth, srcH = _screenHeight;
      
      switch (_captureMode) {
        case WindowsCaptureMode.desktop:
          // Full screen (default values already set)
          break;
          
        case WindowsCaptureMode.window:
          if (_targetHwnd == 0 || _isWindow(_targetHwnd) == 0) {
            if (shouldLog) {
              logger.warn('Target window no longer valid (hwnd=$_targetHwnd)', module: 'GDI');
            }
            return null;
          }
          // Get current window position (window may have moved)
          _getWindowRect(_targetHwnd, _rectBuffer!);
          srcX = _rectBuffer!.ref.left;
          srcY = _rectBuffer!.ref.top;
          srcW = _rectBuffer!.ref.right - _rectBuffer!.ref.left;
          srcH = _rectBuffer!.ref.bottom - _rectBuffer!.ref.top;
          
          // Clamp to screen bounds
          if (srcX < 0) { srcW += srcX; srcX = 0; }
          if (srcY < 0) { srcH += srcY; srcY = 0; }
          if (srcX + srcW > _screenWidth) srcW = _screenWidth - srcX;
          if (srcY + srcH > _screenHeight) srcH = _screenHeight - srcY;
          
          if (srcW <= 0 || srcH <= 0) {
            if (shouldLog) {
              logger.warn('Window has zero visible area', module: 'GDI');
            }
            return null;
          }
          break;
          
        case WindowsCaptureMode.region:
          srcX = _regionX;
          srcY = _regionY;
          srcW = _regionWidth;
          srcH = _regionHeight;
          
          // Clamp to screen bounds
          if (srcX < 0) { srcW += srcX; srcX = 0; }
          if (srcY < 0) { srcH += srcY; srcY = 0; }
          if (srcX + srcW > _screenWidth) srcW = _screenWidth - srcX;
          if (srcY + srcH > _screenHeight) srcH = _screenHeight - srcY;
          
          if (srcW <= 0 || srcH <= 0) return null;
          break;
      }
      
      // StretchBlt from screen to memory DC (with scaling)
      final result = _stretchBlt(
        _memDC, 0, 0, _targetWidth, _targetHeight,
        _screenDC, srcX, srcY, srcW, srcH,
        SRCCOPY,
      );
      
      if (result == 0) {
        logger.error('StretchBlt failed (result=0)', module: 'GDI');
        return null;
      }
      
      // Get the bitmap bits - use _screenDC (not _memDC) for proper color conversion
      final rowStride = ((_targetWidth * 3 + 3) & ~3);
      
      final lines = _getDIBits(
        _screenDC,  // Use screen DC for proper color conversion
        _memBitmap,
        0,
        _targetHeight,
        _pixelBuffer!,
        _bitmapInfo!,
        DIB_RGB_COLORS,
      );
      
      if (lines == 0) {
        logger.error('GetDIBits failed (lines=0)', module: 'GDI');
        return null;
      }
      
      if (shouldLog) {
        logger.info('Frame $_frameCounter: GetDIBits returned $lines lines', module: 'GDI');
      }
      
      // Convert BGR to RGB and remove padding
      final rgbData = Uint8List(_targetWidth * _targetHeight * 3);
      int outIdx = 0;
      int nonZeroCount = 0;
      int sumR = 0, sumG = 0, sumB = 0;
      
      for (int y = 0; y < _targetHeight; y++) {
        final rowStart = y * rowStride;
        for (int x = 0; x < _targetWidth; x++) {
          final srcIdx = rowStart + x * 3;
          // BGR -> RGB
          final r = _pixelBuffer![srcIdx + 2];
          final g = _pixelBuffer![srcIdx + 1];
          final b = _pixelBuffer![srcIdx];
          
          rgbData[outIdx++] = r;
          rgbData[outIdx++] = g;
          rgbData[outIdx++] = b;
          
          if (r > 0 || g > 0 || b > 0) {
            nonZeroCount++;
            sumR += r;
            sumG += g;
            sumB += b;
          }
        }
      }
      
      // Track non-black frames
      if (nonZeroCount > 0) {
        _nonBlackFrames++;
      }
      
      // Log capture stats periodically
      if (shouldLog) {
        final totalPixels = _targetWidth * _targetHeight;
        final pctNonZero = (nonZeroCount * 100 / totalPixels).toStringAsFixed(1);
        final avgR = nonZeroCount > 0 ? sumR ~/ nonZeroCount : 0;
        final avgG = nonZeroCount > 0 ? sumG ~/ nonZeroCount : 0;
        final avgB = nonZeroCount > 0 ? sumB ~/ nonZeroCount : 0;
        if (nonZeroCount == 0) {
          logger.warn('Frame $_frameCounter: ALL BLACK (0% non-black)', module: 'GDI');
        } else {
          logger.info('Frame $_frameCounter: $pctNonZero% non-black, RGB=($avgR,$avgG,$avgB)', module: 'GDI');
        }
      }
      
      return rgbData;
    } catch (e) {
      logger.error('Capture error: $e', module: 'GDI');
      return null;
    }
  }
  
  /// Get screen dimensions
  (int, int) getScreenDimensions() {
    return (_screenWidth, _screenHeight);
  }
  
  /// Check if initialized
  bool get isInitialized => _isInitialized;
  
  /// Clean up resources
  void cleanup() {
    if (_oldBitmap != 0 && _memDC != 0) {
      _selectObject(_memDC, _oldBitmap);
      _oldBitmap = 0;
    }
    
    if (_memBitmap != 0) {
      _deleteObject(_memBitmap);
      _memBitmap = 0;
    }
    
    if (_memDC != 0) {
      _deleteDC(_memDC);
      _memDC = 0;
    }
    
    if (_screenDC != 0) {
      _releaseDC(0, _screenDC);
      _screenDC = 0;
    }
    
    if (_bitmapInfo != null) {
      calloc.free(_bitmapInfo!);
      _bitmapInfo = null;
    }
    
    if (_pixelBuffer != null) {
      calloc.free(_pixelBuffer!);
      _pixelBuffer = null;
    }
    
    if (_rectBuffer != null) {
      calloc.free(_rectBuffer!);
      _rectBuffer = null;
    }
    
    _isInitialized = false;
    _captureMode = WindowsCaptureMode.desktop;
    _targetHwnd = 0;
    logger.info('GDI resources cleaned up', module: 'GDI');
  }
}

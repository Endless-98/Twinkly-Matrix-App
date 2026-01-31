import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

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
  
  Pointer<BITMAPINFO>? _bitmapInfo;
  Pointer<Uint8>? _pixelBuffer;
  
  /// Initialize the capture system with target dimensions
  bool initialize(int targetWidth, int targetHeight) {
    if (_isInitialized) {
      cleanup();
    }
    
    try {
      _targetWidth = targetWidth;
      _targetHeight = targetHeight;
      
      // Get screen dimensions
      _screenWidth = _getSystemMetrics(SM_CXSCREEN);
      _screenHeight = _getSystemMetrics(SM_CYSCREEN);
      
      debugPrint('[WIN_CAPTURE] Screen: ${_screenWidth}x$_screenHeight, Target: ${_targetWidth}x$_targetHeight');
      
      // Get screen DC
      _screenDC = _getDC(0);
      if (_screenDC == 0) {
        debugPrint('[WIN_CAPTURE] Failed to get screen DC');
        return false;
      }
      
      // Create memory DC
      _memDC = _createCompatibleDC(_screenDC);
      if (_memDC == 0) {
        debugPrint('[WIN_CAPTURE] Failed to create memory DC');
        cleanup();
        return false;
      }
      
      // Set stretch mode for quality scaling
      _setStretchBltMode(_memDC, HALFTONE);
      
      // Create bitmap at target size
      _memBitmap = _createCompatibleBitmap(_screenDC, _targetWidth, _targetHeight);
      if (_memBitmap == 0) {
        debugPrint('[WIN_CAPTURE] Failed to create bitmap');
        cleanup();
        return false;
      }
      
      // Select bitmap into memory DC
      _oldBitmap = _selectObject(_memDC, _memBitmap);
      
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
      debugPrint('[WIN_CAPTURE] Initialized successfully');
      return true;
    } catch (e) {
      debugPrint('[WIN_CAPTURE] Init error: $e');
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
      debugPrint('[WIN_CAPTURE] Not initialized');
      return null;
    }
    
    _frameCounter++;
    final shouldLog = _frameCounter % _logInterval == 1;
    
    try {
      // StretchBlt from screen to memory DC (with scaling)
      final result = _stretchBlt(
        _memDC, 0, 0, _targetWidth, _targetHeight,
        _screenDC, 0, 0, _screenWidth, _screenHeight,
        SRCCOPY,
      );
      
      if (result == 0) {
        debugPrint('[WIN_CAPTURE] StretchBlt failed (result=0)');
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
        debugPrint('[WIN_CAPTURE] GetDIBits failed (lines=0)');
        return null;
      }
      
      if (shouldLog) {
        debugPrint('[WIN_CAPTURE] GetDIBits returned $lines lines (expected $_targetHeight)');
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
        debugPrint('[WIN_CAPTURE] Frame $_frameCounter: $pctNonZero% non-black, avg RGB=($avgR,$avgG,$avgB), non-black frames: $_nonBlackFrames');
      }
      
      return rgbData;
    } catch (e) {
      debugPrint('[WIN_CAPTURE] Capture error: $e');
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
    
    _isInitialized = false;
    debugPrint('[WIN_CAPTURE] Cleaned up');
  }
}

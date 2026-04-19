import 'package:flutter/material.dart';

/// Visual preview of a phone screen where the user can drag/resize a selection
/// region to pick which part of the screen to capture into the cast bubble.
///
/// Displays a phone-shaped frame with the crop region shown as a draggable,
/// resizable rectangle with corner handles — identical UX to CurtainPreview.
class ScreenCropPreview extends StatefulWidget {
  /// Current crop region as normalized coordinates (0.0–1.0).
  final Rect cropRect;

  /// Called when the crop region changes.
  final ValueChanged<Rect> onCropChanged;

  const ScreenCropPreview({
    super.key,
    required this.cropRect,
    required this.onCropChanged,
  });

  @override
  State<ScreenCropPreview> createState() => _ScreenCropPreviewState();
}

class _ScreenCropPreviewState extends State<ScreenCropPreview> {
  late Rect _cropRect;
  _DragMode? _dragMode;
  Offset? _dragStart;
  Rect? _cropStart;

  static const double _handleSize = 28.0;    // drawn size
  static const double _handleHitSize = 52.0; // touch hit zone
  static const double _minCropFraction = 0.08;

  // Phone proportions (9:19.5 aspect ratio like modern phones)
  static const double _phoneAspect = 9.0 / 19.5;

  @override
  void initState() {
    super.initState();
    _cropRect = widget.cropRect;
  }

  @override
  void didUpdateWidget(ScreenCropPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragMode == null) {
      _cropRect = widget.cropRect;
    }
  }

  Rect _clampCrop(Rect r) {
    final w = r.width.clamp(_minCropFraction, 1.0);
    final h = r.height.clamp(_minCropFraction, 1.0);
    final l = r.left.clamp(0.0, 1.0 - w);
    final t = r.top.clamp(0.0, 1.0 - h);
    return Rect.fromLTWH(l, t, w, h);
  }

  void _onPanStart(DragStartDetails details, _PhoneLayout layout) {
    final local = details.localPosition;
    final nx = (local.dx - layout.phoneRect.left) / layout.phoneRect.width;
    final ny = (local.dy - layout.phoneRect.top) / layout.phoneRect.height;

    final cr = _cropRect;
    // Use larger hit zone for corner detection
    final hs  = _handleHitSize / layout.phoneRect.width;
    final hsY = _handleHitSize / layout.phoneRect.height;
    // Extra padding for body move hit zone
    final pad  = 14.0 / layout.phoneRect.width;
    final padY = 14.0 / layout.phoneRect.height;

    _dragStart = Offset(nx, ny);
    _cropStart = _cropRect;

    // Check corners first (large hit zones)
    if (_hitCorner(nx, ny, cr.right, cr.bottom, hs, hsY)) {
      _dragMode = _DragMode.resizeBR;
    } else if (_hitCorner(nx, ny, cr.left, cr.bottom, hs, hsY)) {
      _dragMode = _DragMode.resizeBL;
    } else if (_hitCorner(nx, ny, cr.right, cr.top, hs, hsY)) {
      _dragMode = _DragMode.resizeTR;
    } else if (_hitCorner(nx, ny, cr.left, cr.top, hs, hsY)) {
      _dragMode = _DragMode.resizeTL;
    } else if (nx >= cr.left - pad && nx <= cr.right + pad &&
               ny >= cr.top - padY && ny <= cr.bottom + padY) {
      _dragMode = _DragMode.move;
    } else {
      _dragMode = null;
    }
  }

  bool _hitCorner(double px, double py, double cx, double cy, double hsX, double hsY) {
    return (px - cx).abs() < hsX && (py - cy).abs() < hsY;
  }

  void _onPanUpdate(DragUpdateDetails details, _PhoneLayout layout) {
    if (_dragMode == null || _dragStart == null || _cropStart == null) return;

    final local = details.localPosition;
    final nx = (local.dx - layout.phoneRect.left) / layout.phoneRect.width;
    final ny = (local.dy - layout.phoneRect.top) / layout.phoneRect.height;
    final dx = nx - _dragStart!.dx;
    final dy = ny - _dragStart!.dy;
    final cs = _cropStart!;

    setState(() {
      switch (_dragMode!) {
        case _DragMode.move:
          _cropRect = _clampCrop(Rect.fromLTWH(cs.left + dx, cs.top + dy, cs.width, cs.height));
          break;
        case _DragMode.resizeBR:
          _cropRect = _clampCrop(Rect.fromLTWH(cs.left, cs.top, cs.width + dx, cs.height + dy));
          break;
        case _DragMode.resizeBL:
          final newL = cs.left + dx;
          final newW = cs.width - dx;
          _cropRect = _clampCrop(Rect.fromLTWH(newL, cs.top, newW, cs.height + dy));
          break;
        case _DragMode.resizeTR:
          final newT = cs.top + dy;
          final newH = cs.height - dy;
          _cropRect = _clampCrop(Rect.fromLTWH(cs.left, newT, cs.width + dx, newH));
          break;
        case _DragMode.resizeTL:
          final newL = cs.left + dx;
          final newW = cs.width - dx;
          final newT = cs.top + dy;
          final newH = cs.height - dy;
          _cropRect = _clampCrop(Rect.fromLTWH(newL, newT, newW, newH));
          break;
      }
    });
    // Live update — cast loop picks up new crop on next iteration
    widget.onCropChanged(_cropRect);
  }

  void _onPanEnd(DragEndDetails details) {
    if (_dragMode != null) {
      widget.onCropChanged(_cropRect);
    }
    _dragMode = null;
    _dragStart = null;
    _cropStart = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _PhoneLayout.compute(constraints.maxWidth, constraints.maxHeight);

        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, layout),
          onPanUpdate: (d) => _onPanUpdate(d, layout),
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _ScreenCropPainter(
              cropRect: _cropRect,
              layout: layout,
              handleSize: _handleSize,
            ),
          ),
        );
      },
    );
  }
}

enum _DragMode { move, resizeBR, resizeBL, resizeTR, resizeTL }

class _PhoneLayout {
  final Rect phoneRect;
  final double cornerRadius;

  _PhoneLayout({required this.phoneRect, required this.cornerRadius});

  static _PhoneLayout compute(double availW, double availH) {
    const phoneAspect = 9.0 / 19.5;
    double phoneW, phoneH;
    if (availW / availH > phoneAspect) {
      phoneH = availH * 0.95;
      phoneW = phoneH * phoneAspect;
    } else {
      phoneW = availW * 0.7;
      phoneH = phoneW / phoneAspect;
    }
    final left = (availW - phoneW) / 2;
    final top = (availH - phoneH) / 2;
    return _PhoneLayout(
      phoneRect: Rect.fromLTWH(left, top, phoneW, phoneH),
      cornerRadius: phoneW * 0.08,
    );
  }
}

class _ScreenCropPainter extends CustomPainter {
  final Rect cropRect;
  final _PhoneLayout layout;
  final double handleSize;

  _ScreenCropPainter({
    required this.cropRect,
    required this.layout,
    required this.handleSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pr = layout.phoneRect;
    final cr = layout.cornerRadius;

    // Phone body (dark background)
    final phoneRRect = RRect.fromRectAndRadius(pr, Radius.circular(cr));
    canvas.drawRRect(phoneRRect, Paint()..color = const Color(0xFF0A0A1A));
    canvas.drawRRect(
      phoneRRect,
      Paint()
        ..color = const Color(0xFF4A4A7E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Phone screen area (slightly inset)
    final screenInset = cr * 0.4;
    final screenRect = Rect.fromLTRB(
      pr.left + screenInset,
      pr.top + screenInset * 2,
      pr.right - screenInset,
      pr.bottom - screenInset * 2,
    );
    final screenRRect = RRect.fromRectAndRadius(screenRect, Radius.circular(cr * 0.3));
    canvas.drawRRect(screenRRect, Paint()..color = const Color(0xFF1A1A2E));

    // Simulated screen content — show app bars, content hints
    _drawFakeScreenContent(canvas, screenRect);

    // Dimmed overlay outside crop area
    final cropPixelRect = Rect.fromLTWH(
      pr.left + cropRect.left * pr.width,
      pr.top + cropRect.top * pr.height,
      cropRect.width * pr.width,
      cropRect.height * pr.height,
    );

    // Draw dim overlay using path subtraction
    final fullPath = Path()..addRect(pr);
    final cropPath = Path()..addRect(cropPixelRect);
    final dimPath = Path.combine(PathOperation.difference, fullPath, cropPath);
    canvas.drawPath(dimPath, Paint()..color = const Color(0xAA000000));

    // Crop selection border
    canvas.drawRect(
      cropPixelRect,
      Paint()
        ..color = Colors.orange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Crosshatch inside selection
    final crossPaint = Paint()
      ..color = const Color.fromRGBO(255, 152, 0, 0.08)
      ..strokeWidth = 1;
    final step = 12.0;
    for (double d = -cropPixelRect.height; d < cropPixelRect.width; d += step) {
      final x1 = (cropPixelRect.left + d).clamp(cropPixelRect.left, cropPixelRect.right);
      final y1 = cropPixelRect.top + (x1 - cropPixelRect.left - d).clamp(0.0, cropPixelRect.height);
      final x2 = (cropPixelRect.left + d + cropPixelRect.height).clamp(cropPixelRect.left, cropPixelRect.right);
      final y2 = cropPixelRect.top + (x2 - cropPixelRect.left - d).clamp(0.0, cropPixelRect.height);
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), crossPaint);
    }

    // Size label centered in crop
    final pctW = (cropRect.width * 100).round();
    final pctH = (cropRect.height * 100).round();
    final label = '${pctW}% × ${pctH}%';
    final labelPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Background for label
    final labelRect = Rect.fromCenter(
      center: cropPixelRect.center,
      width: labelPainter.width + 12,
      height: labelPainter.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = const Color(0xCC000000),
    );
    labelPainter.paint(
      canvas,
      Offset(labelRect.left + 6, labelRect.top + 3),
    );

    // Corner handles: L-bracket style (orange) with corner dots
    final bracketPaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = Colors.orange;
    final dotBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final arm = handleSize * 0.65;
    // TL
    canvas.drawLine(cropPixelRect.topLeft, cropPixelRect.topLeft + Offset(arm, 0), bracketPaint);
    canvas.drawLine(cropPixelRect.topLeft, cropPixelRect.topLeft + Offset(0, arm), bracketPaint);
    // TR
    canvas.drawLine(cropPixelRect.topRight, cropPixelRect.topRight + Offset(-arm, 0), bracketPaint);
    canvas.drawLine(cropPixelRect.topRight, cropPixelRect.topRight + Offset(0, arm), bracketPaint);
    // BL
    canvas.drawLine(cropPixelRect.bottomLeft, cropPixelRect.bottomLeft + Offset(arm, 0), bracketPaint);
    canvas.drawLine(cropPixelRect.bottomLeft, cropPixelRect.bottomLeft + Offset(0, -arm), bracketPaint);
    // BR
    canvas.drawLine(cropPixelRect.bottomRight, cropPixelRect.bottomRight + Offset(-arm, 0), bracketPaint);
    canvas.drawLine(cropPixelRect.bottomRight, cropPixelRect.bottomRight + Offset(0, -arm), bracketPaint);
    // Corner dots
    for (final corner in [
      cropPixelRect.topLeft, cropPixelRect.topRight,
      cropPixelRect.bottomLeft, cropPixelRect.bottomRight,
    ]) {
      canvas.drawCircle(corner, 5, dotPaint);
      canvas.drawCircle(corner, 5, dotBorderPaint);
    }

    // "Your Screen" label below phone
    final titlePainter = TextPainter(
      text: const TextSpan(
        text: 'Drag to select screen region',
        style: TextStyle(color: Color(0xFF8A8ABE), fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titlePainter.paint(
      canvas,
      Offset((size.width - titlePainter.width) / 2, pr.bottom + 6),
    );
  }

  void _drawFakeScreenContent(Canvas canvas, Rect screen) {
    // Status bar
    final barH = screen.height * 0.04;
    canvas.drawRect(
      Rect.fromLTWH(screen.left, screen.top, screen.width, barH),
      Paint()..color = const Color(0xFF252545),
    );

    // App bar
    canvas.drawRect(
      Rect.fromLTWH(screen.left, screen.top + barH, screen.width, barH * 1.5),
      Paint()..color = const Color(0xFF2A2A4A),
    );

    // Content blocks (simulated)
    final contentTop = screen.top + barH * 3;
    final blockH = screen.height * 0.06;
    for (int i = 0; i < 6; i++) {
      final y = contentTop + i * (blockH + 6);
      if (y + blockH > screen.bottom - barH) break;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(screen.left + 8, y, screen.width - 16, blockH),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xFF222240),
      );
    }

    // Bottom nav bar
    canvas.drawRect(
      Rect.fromLTWH(screen.left, screen.bottom - barH * 1.2, screen.width, barH * 1.2),
      Paint()..color = const Color(0xFF252545),
    );
  }

  @override
  bool shouldRepaint(_ScreenCropPainter oldDelegate) {
    return cropRect != oldDelegate.cropRect;
  }
}

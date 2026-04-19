import 'package:flutter/material.dart';

/// Visual preview of the 90x50 LED curtain with a draggable/resizable cast bubble.
///
/// The bubble represents where the captured screen content will appear on the
/// LED wall. Users can drag to reposition and use corner handles to resize.
class CurtainPreview extends StatefulWidget {
  /// Bubble position in LED pixel coordinates (0-89, 0-49).
  final Offset bubblePosition;

  /// Bubble size in LED pixels.
  final Size bubbleSize;

  /// Called when the bubble is moved or resized.
  final void Function(Offset position, Size size) onBubbleChanged;

  /// Aspect ratio (width/height) of the captured phone content.
  /// The bubble is locked to this ratio when resizing.
  final double cropAspect;

  static const int curtainWidth = 90;
  static const int curtainHeight = 50;

  const CurtainPreview({
    super.key,
    required this.bubblePosition,
    required this.bubbleSize,
    required this.onBubbleChanged,
    this.cropAspect = 90.0 / 50.0,
  });

  @override
  State<CurtainPreview> createState() => _CurtainPreviewState();
}

class _CurtainPreviewState extends State<CurtainPreview> {
  late Offset _bubblePos;
  late Size _bubbleSize;
  _DragMode? _dragMode;
  Offset? _dragStart;
  Offset? _posStart;
  Size? _sizeStart;
  Offset _canvasOffset = Offset.zero;

  // Drawn handle arm length; hit zone is larger
  static const double _handleSize = 28.0;
  static const double _handleHitSize = 52.0;
  static const double _minBubblePixels = 4.0;

  @override
  void initState() {
    super.initState();
    _bubblePos = widget.bubblePosition;
    _bubbleSize = widget.bubbleSize;
  }

  @override
  void didUpdateWidget(CurtainPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragMode == null) {
      _bubblePos = widget.bubblePosition;
      _bubbleSize = widget.bubbleSize;
    }
  }

  Offset _clampPosition(Offset pos, Size size) {
    return Offset(
      pos.dx.clamp(0.0, (CurtainPreview.curtainWidth - size.width).toDouble()),
      pos.dy.clamp(0.0, (CurtainPreview.curtainHeight - size.height).toDouble()),
    );
  }

  /// Returns a size with the given requested width, height derived from
  /// cropAspect, both clamped to the curtain bounds given topLeft position.
  Size _aspectSize(double requestedW, Offset topLeft) {
    final aspect = widget.cropAspect;
    final maxW = (CurtainPreview.curtainWidth - topLeft.dx)
        .clamp(_minBubblePixels, CurtainPreview.curtainWidth.toDouble());
    final maxH = (CurtainPreview.curtainHeight - topLeft.dy)
        .clamp(_minBubblePixels, CurtainPreview.curtainHeight.toDouble());
    var w = requestedW.clamp(_minBubblePixels, maxW);
    var h = w / aspect;
    if (h > maxH) {
      h = maxH;
      w = (h * aspect).clamp(_minBubblePixels, maxW);
      h = w / aspect;
    }
    return Size(w, h.clamp(_minBubblePixels, maxH));
  }

  void _onPanStart(DragStartDetails details, double scale, Offset canvasOffset) {
    _canvasOffset = canvasOffset;
    final local = details.localPosition - canvasOffset;
    final bx = _bubblePos.dx * scale;
    final by = _bubblePos.dy * scale;
    final bw = _bubbleSize.width * scale;
    final bh = _bubbleSize.height * scale;

    _dragStart = local;
    _posStart = _bubblePos;
    _sizeStart = _bubbleSize;

    // Check corners first using large hit zones
    if (_hitHandle(local, Offset(bx + bw, by + bh))) {
      _dragMode = _DragMode.resizeBR;
    } else if (_hitHandle(local, Offset(bx, by + bh))) {
      _dragMode = _DragMode.resizeBL;
    } else if (_hitHandle(local, Offset(bx + bw, by))) {
      _dragMode = _DragMode.resizeTR;
    } else if (_hitHandle(local, Offset(bx, by))) {
      _dragMode = _DragMode.resizeTL;
    } else if (local.dx >= bx - 10 && local.dx <= bx + bw + 10 &&
               local.dy >= by - 10 && local.dy <= by + bh + 10) {
      _dragMode = _DragMode.move;
    } else {
      _dragMode = null;
    }
  }

  bool _hitHandle(Offset point, Offset corner) {
    const h = _handleHitSize / 2;
    return (point.dx - corner.dx).abs() <= h && (point.dy - corner.dy).abs() <= h;
  }

  void _onPanUpdate(DragUpdateDetails details, double scale) {
    if (_dragMode == null || _dragStart == null) return;

    // Correct: compute delta from start position in canvas space
    final local = details.localPosition - _canvasOffset;
    final dx = (local.dx - _dragStart!.dx) / scale;
    final dy = (local.dy - _dragStart!.dy) / scale;

    setState(() {
      switch (_dragMode!) {
        case _DragMode.move:
          _bubblePos = _clampPosition(
            Offset(_posStart!.dx + dx, _posStart!.dy + dy),
            _bubbleSize,
          );
          break;

        case _DragMode.resizeBR:
          // Anchor = top-left. Width from dx, height derived from aspect.
          _bubbleSize = _aspectSize(_sizeStart!.width + dx, _posStart!);
          break;

        case _DragMode.resizeBL:
          // Anchor = top-right edge (right stays fixed).
          final rawW = _sizeStart!.width - dx;
          final tentativeX = (_posStart!.dx + _sizeStart!.width - rawW)
              .clamp(0.0, (CurtainPreview.curtainWidth - _minBubblePixels).toDouble());
          final newSize = _aspectSize(rawW, Offset(tentativeX, _posStart!.dy));
          final newX = (_posStart!.dx + _sizeStart!.width - newSize.width)
              .clamp(0.0, (CurtainPreview.curtainWidth - newSize.width).toDouble());
          _bubblePos = Offset(newX, _posStart!.dy);
          _bubbleSize = newSize;
          break;

        case _DragMode.resizeTR:
          // Anchor = bottom-left. Width from dx, top edge moves.
          final rawW = _sizeStart!.width + dx;
          final newSize = _aspectSize(rawW, Offset(_posStart!.dx, 0));
          final newY = (_posStart!.dy + _sizeStart!.height - newSize.height)
              .clamp(0.0, (CurtainPreview.curtainHeight - newSize.height).toDouble());
          _bubblePos = Offset(_posStart!.dx, newY);
          _bubbleSize = newSize;
          break;

        case _DragMode.resizeTL:
          // Anchor = bottom-right. Both edges move.
          final rawW = _sizeStart!.width - dx;
          final tentativeX = (_posStart!.dx + _sizeStart!.width - rawW)
              .clamp(0.0, (CurtainPreview.curtainWidth - _minBubblePixels).toDouble());
          final newSize = _aspectSize(rawW, Offset(tentativeX, 0));
          final newX = (_posStart!.dx + _sizeStart!.width - newSize.width)
              .clamp(0.0, (CurtainPreview.curtainWidth - newSize.width).toDouble());
          final newY = (_posStart!.dy + _sizeStart!.height - newSize.height)
              .clamp(0.0, (CurtainPreview.curtainHeight - newSize.height).toDouble());
          _bubblePos = Offset(newX, newY);
          _bubbleSize = newSize;
          break;
      }
    });
    // Live update — cast loop picks up new position/size on next iteration
    widget.onBubbleChanged(_bubblePos, _bubbleSize);
  }

  void _onPanEnd(DragEndDetails details) {
    if (_dragMode != null) {
      // Snap to integer LED coordinates while preserving aspect
      final snappedW = _bubbleSize.width.roundToDouble();
      final snappedPos = Offset(
        _bubblePos.dx.roundToDouble(),
        _bubblePos.dy.roundToDouble(),
      );
      final snappedSize = _aspectSize(snappedW, snappedPos);
      setState(() {
        _bubblePos = _clampPosition(snappedPos, snappedSize);
        _bubbleSize = snappedSize;
      });
      widget.onBubbleChanged(_bubblePos, _bubbleSize);
    }
    _dragMode = null;
    _dragStart = null;
    _posStart = null;
    _sizeStart = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate scale to fit curtain in available space with aspect ratio
        const aspect = CurtainPreview.curtainWidth / CurtainPreview.curtainHeight;
        double canvasW, canvasH;
        if (constraints.maxWidth / constraints.maxHeight > aspect) {
          canvasH = constraints.maxHeight;
          canvasW = canvasH * aspect;
        } else {
          canvasW = constraints.maxWidth;
          canvasH = canvasW / aspect;
        }
        final scale = canvasW / CurtainPreview.curtainWidth;
        final offsetX = (constraints.maxWidth - canvasW) / 2;
        final offsetY = (constraints.maxHeight - canvasH) / 2;
        final canvasOffset = Offset(offsetX, offsetY);

        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, scale, canvasOffset),
          onPanUpdate: (d) => _onPanUpdate(d, scale),
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _CurtainPainter(
              bubblePos: _bubblePos,
              bubbleSize: _bubbleSize,
              scale: scale,
              canvasOffset: canvasOffset,
              canvasSize: Size(canvasW, canvasH),
              handleSize: _handleSize,
            ),
          ),
        );
      },
    );
  }
}

enum _DragMode { move, resizeBR, resizeBL, resizeTR, resizeTL }

class _CurtainPainter extends CustomPainter {
  final Offset bubblePos;
  final Size bubbleSize;
  final double scale;
  final Offset canvasOffset;
  final Size canvasSize;
  final double handleSize;

  _CurtainPainter({
    required this.bubblePos,
    required this.bubbleSize,
    required this.scale,
    required this.canvasOffset,
    required this.canvasSize,
    required this.handleSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw curtain background
    final curtainRect = Rect.fromLTWH(
      canvasOffset.dx, canvasOffset.dy, canvasSize.width, canvasSize.height,
    );
    canvas.drawRect(
      curtainRect,
      Paint()..color = const Color(0xFF1A1A2E),
    );

    // Draw grid lines
    final gridPaint = Paint()
      ..color = const Color(0xFF2A2A4E)
      ..strokeWidth = 0.5;
    for (int x = 0; x <= CurtainPreview.curtainWidth; x += 10) {
      final px = canvasOffset.dx + x * scale;
      canvas.drawLine(
        Offset(px, canvasOffset.dy),
        Offset(px, canvasOffset.dy + canvasSize.height),
        gridPaint,
      );
    }
    for (int y = 0; y <= CurtainPreview.curtainHeight; y += 10) {
      final py = canvasOffset.dy + y * scale;
      canvas.drawLine(
        Offset(canvasOffset.dx, py),
        Offset(canvasOffset.dx + canvasSize.width, py),
        gridPaint,
      );
    }

    // Draw curtain border
    canvas.drawRect(
      curtainRect,
      Paint()
        ..color = const Color(0xFF4A4A8E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Draw "LED CURTAIN" label
    final labelPainter = TextPainter(
      text: const TextSpan(
        text: '90 × 50 LED Curtain',
        style: TextStyle(color: Color(0xFF6A6AAE), fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    labelPainter.paint(
      canvas,
      Offset(
        canvasOffset.dx + (canvasSize.width - labelPainter.width) / 2,
        canvasOffset.dy + canvasSize.height + 4,
      ),
    );

    // Draw bubble
    final bx = canvasOffset.dx + bubblePos.dx * scale;
    final by = canvasOffset.dy + bubblePos.dy * scale;
    final bw = bubbleSize.width * scale;
    final bh = bubbleSize.height * scale;
    final bubbleRect = Rect.fromLTWH(bx, by, bw, bh);

    // Bubble fill
    canvas.drawRect(
      bubbleRect,
      Paint()..color = const Color.fromRGBO(0, 188, 212, 0.25),
    );

    // Bubble border
    canvas.drawRect(
      bubbleRect,
      Paint()
        ..color = Colors.cyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Diagonal lines to indicate the cast area
    final diagPaint = Paint()
      ..color = const Color.fromRGBO(0, 188, 212, 0.15)
      ..strokeWidth = 1;
    for (double d = -bh; d < bw; d += 8) {
      final x1 = (bx + d).clamp(bx, bx + bw);
      final y1 = by + (x1 - bx - d).clamp(0.0, bh);
      final x2 = (bx + d + bh).clamp(bx, bx + bw);
      final y2 = by + (x2 - bx - d).clamp(0.0, bh);
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), diagPaint);
    }

    // Draw bubble size label
    final sizePainter = TextPainter(
      text: TextSpan(
        text: '${bubbleSize.width.round()}×${bubbleSize.height.round()}',
        style: const TextStyle(color: Colors.cyan, fontSize: 10, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    sizePainter.paint(
      canvas,
      Offset(bx + (bw - sizePainter.width) / 2, by + (bh - sizePainter.height) / 2),
    );

    // Draw L-bracket corner handles (easier to see and grab)
    final bracketPaint = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()..color = Colors.cyan;
    final dotBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final arm = handleSize * 0.6;
    // TL
    canvas.drawLine(Offset(bx, by), Offset(bx + arm, by), bracketPaint);
    canvas.drawLine(Offset(bx, by), Offset(bx, by + arm), bracketPaint);
    // TR
    canvas.drawLine(Offset(bx + bw, by), Offset(bx + bw - arm, by), bracketPaint);
    canvas.drawLine(Offset(bx + bw, by), Offset(bx + bw, by + arm), bracketPaint);
    // BL
    canvas.drawLine(Offset(bx, by + bh), Offset(bx + arm, by + bh), bracketPaint);
    canvas.drawLine(Offset(bx, by + bh), Offset(bx, by + bh - arm), bracketPaint);
    // BR
    canvas.drawLine(Offset(bx + bw, by + bh), Offset(bx + bw - arm, by + bh), bracketPaint);
    canvas.drawLine(Offset(bx + bw, by + bh), Offset(bx + bw, by + bh - arm), bracketPaint);
    // Corner dots
    for (final corner in [Offset(bx, by), Offset(bx + bw, by), Offset(bx, by + bh), Offset(bx + bw, by + bh)]) {
      canvas.drawCircle(corner, 5, dotPaint);
      canvas.drawCircle(corner, 5, dotBorderPaint);
    }
  }

  @override
  bool shouldRepaint(_CurtainPainter oldDelegate) {
    return bubblePos != oldDelegate.bubblePos ||
        bubbleSize != oldDelegate.bubbleSize ||
        scale != oldDelegate.scale;
  }
}

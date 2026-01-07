import 'package:flutter/material.dart';
import 'dart:async';

/// A draggable and resizable overlay window for selecting a screen region
class RegionSelectorOverlay extends StatefulWidget {
  final Function(int x, int y, int width, int height) onRegionChanged;
  final int initialX;
  final int initialY;
  final int initialWidth;
  final int initialHeight;

  const RegionSelectorOverlay({
    Key? key,
    required this.onRegionChanged,
    this.initialX = 100,
    this.initialY = 100,
    this.initialWidth = 800,
    this.initialHeight = 600,
  }) : super(key: key);

  @override
  State<RegionSelectorOverlay> createState() => _RegionSelectorOverlayState();
}

class _RegionSelectorOverlayState extends State<RegionSelectorOverlay> {
  late double _x;
  late double _y;
  late double _width;
  late double _height;
  
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _x = widget.initialX.toDouble();
    _y = widget.initialY.toDouble();
    _width = widget.initialWidth.toDouble();
    _height = widget.initialHeight.toDouble();
  }

  void _notifyChange() {
    // Debounce updates
    _updateTimer?.cancel();
    _updateTimer = Timer(const Duration(milliseconds: 100), () {
      widget.onRegionChanged(
        _x.round(),
        _y.round(),
        _width.round(),
        _height.round(),
      );
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Semi-transparent overlay
            Container(
              color: Colors.black.withOpacity(0.3),
            ),
            
            // Draggable selection rectangle
            Positioned(
              left: _x,
              top: _y,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    _x += details.delta.dx;
                    _y += details.delta.dy;
                    _notifyChange();
                  });
                },
                child: Container(
                  width: _width,
                  height: _height,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.red, width: 3),
                    color: Colors.transparent,
                  ),
                  child: Stack(
                    children: [
                      // Center info overlay
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Region: ${_width.round()}x${_height.round()}\n'
                            'Position: (${_x.round()}, ${_y.round()})\n'
                            'Drag to move, resize from corners',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      
                      // Resize handles (corners)
                      _buildResizeHandle(Alignment.topLeft),
                      _buildResizeHandle(Alignment.topRight),
                      _buildResizeHandle(Alignment.bottomLeft),
                      _buildResizeHandle(Alignment.bottomRight),
                    ],
                  ),
                ),
              ),
            ),
            
            // Close button
            Positioned(
              top: 10,
              right: 10,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  final region = {
                    'x': _x.round(),
                    'y': _y.round(),
                    'width': _width.round(),
                    'height': _height.round(),
                  };
                  widget.onRegionChanged(
                    region['x']!,
                    region['y']!,
                    region['width']!,
                    region['height']!,
                  );
                  // Close the overlay window and return the region
                  Navigator.of(context).pop(region);
                },
                child: const Text('Confirm Region'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResizeHandle(Alignment alignment) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            if (alignment == Alignment.bottomRight) {
              _width += details.delta.dx;
              _height += details.delta.dy;
            } else if (alignment == Alignment.bottomLeft) {
              _x += details.delta.dx;
              _width -= details.delta.dx;
              _height += details.delta.dy;
            } else if (alignment == Alignment.topRight) {
              _y += details.delta.dy;
              _width += details.delta.dx;
              _height -= details.delta.dy;
            } else if (alignment == Alignment.topLeft) {
              _x += details.delta.dx;
              _y += details.delta.dy;
              _width -= details.delta.dx;
              _height -= details.delta.dy;
            }
            
            // Minimum size constraints
            if (_width < 200) _width = 200;
            if (_height < 150) _height = 150;
            
            _notifyChange();
          });
        },
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}

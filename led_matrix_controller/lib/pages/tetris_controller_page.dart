import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../services/command_sender.dart';

class TetrisControllerPage extends ConsumerStatefulWidget {
  const TetrisControllerPage({super.key});

  @override
  ConsumerState<TetrisControllerPage> createState() => _TetrisControllerPageState();
}

class _TetrisControllerPageState extends ConsumerState<TetrisControllerPage> {
  @override
  void initState() {
    super.initState();
    _launchTetris();
  }

  Future<void> _launchTetris() async {
    try {
      final sender = await ref.read(commandSenderProvider.future);
      sender.sendCommand('LAUNCH_TETRIS');
    } catch (e) {
      debugPrint('Failed to launch Tetris: $e');
    }
  }

  Future<void> _sendCommand(String command) async {
    try {
      final sender = await ref.read(commandSenderProvider.future);
      sender.sendCommand(command);
    } catch (e) {
      debugPrint('Command send failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Tetris'),
        centerTitle: true,
        backgroundColor: Colors.purple[900],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final screenHeight = constraints.maxHeight;
          final screenWidth = constraints.maxWidth;
          
          return Stack(
            children: [
              // Center: Fast Drop button
              Positioned(
                left: screenWidth * 0.5 - 60,
                bottom: screenHeight * 0.35,
                child: _TetrisButton(
                  icon: Icons.arrow_downward,
                  color: Colors.orange,
                  size: 120,
                  onPressed: () => _sendCommand('MOVE_DOWN'),
                  onHeld: () => _sendCommand('HARD_DROP'),
                ),
              ),
              
              // Bottom Left: Move Left
              Positioned(
                left: 20,
                bottom: 40,
                child: _TetrisButton(
                  icon: Icons.arrow_back,
                  color: Colors.blue,
                  size: 140,
                  onPressed: () => _sendCommand('MOVE_LEFT'),
                  onHeld: () => _sendCommand('MOVE_LEFT_HELD'),
                ),
              ),
              
              // Above Left: Rotate Left
              Positioned(
                left: 40,
                bottom: 200,
                child: _TetrisButton(
                  icon: Icons.rotate_left,
                  color: Colors.cyan,
                  size: 100,
                  onPressed: () => _sendCommand('ROTATE_LEFT'),
                ),
              ),
              
              // Bottom Right: Move Right
              Positioned(
                right: 20,
                bottom: 40,
                child: _TetrisButton(
                  icon: Icons.arrow_forward,
                  color: Colors.green,
                  size: 140,
                  onPressed: () => _sendCommand('MOVE_RIGHT'),
                  onHeld: () => _sendCommand('MOVE_RIGHT_HELD'),
                ),
              ),
              
              // Above Right: Rotate Right
              Positioned(
                right: 40,
                bottom: 200,
                child: _TetrisButton(
                  icon: Icons.rotate_right,
                  color: Colors.pink,
                  size: 100,
                  onPressed: () => _sendCommand('ROTATE_RIGHT'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TetrisButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback onPressed;
  final VoidCallback? onHeld;

  const _TetrisButton({
    required this.icon,
    required this.color,
    required this.size,
    required this.onPressed,
    this.onHeld,
  });

  @override
  State<_TetrisButton> createState() => _TetrisButtonState();
}

class _TetrisButtonState extends State<_TetrisButton> {
  bool _isPressed = false;
  bool _isActuallyPressed = false; // Track actual press state separately
  Timer? _feedbackTimer;
  Timer? _holdTimer;

  void _handlePressStart() {
    // Cancel any pending timers
    _feedbackTimer?.cancel();
    _holdTimer?.cancel();
    
    // Mark as actually pressed
    _isActuallyPressed = true;
    
    // Show visual feedback immediately
    setState(() => _isPressed = true);
    
    // Send tap command immediately
    widget.onPressed();
    
    // Start hold timer if onHeld callback exists
    if (widget.onHeld != null) {
      _holdTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && _isActuallyPressed) {
          widget.onHeld!();
        }
      });
    }
    
    // Keep button visually pressed for at least 150ms even if touch is 1ms
    _feedbackTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted && !_isActuallyPressed) {
        setState(() => _isPressed = false);
      }
    });
  }

  void _handlePressEnd() {
    // Cancel hold timer on release
    _holdTimer?.cancel();
    
    // Mark as not actually pressed
    _isActuallyPressed = false;
    
    // If feedback timer hasn't fired yet, keep visual feedback until it does
    // The timer will handle resetting the visual state after 150ms
    // If timer already fired, we need to reset immediately
    if (!(_feedbackTimer?.isActive ?? false)) {
      setState(() => _isPressed = false);
    }
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _handlePressStart(),
      onTapUp: (_) => _handlePressEnd(),
      onTapCancel: _handlePressEnd,
      onLongPressStart: (_) => _handlePressStart(),
      onLongPressEnd: (_) => _handlePressEnd(),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: _isPressed
                ? [widget.color.withOpacity(0.6), widget.color.withOpacity(0.9)]
                : [widget.color.withOpacity(0.9), widget.color.withOpacity(0.7)],
          ),
          boxShadow: [
            BoxShadow(
              color: widget.color.withOpacity(_isPressed ? 0.8 : 0.5),
              blurRadius: _isPressed ? 20 : 30,
              spreadRadius: _isPressed ? 2 : 5,
            ),
          ],
          border: Border.all(
            color: Colors.white.withOpacity(0.3),
            width: 3,
          ),
        ),
        child: Center(
          child: Icon(
            widget.icon,
            color: Colors.white,
            size: widget.size * 0.5,
          ),
        ),
      ),
    );
  }
}

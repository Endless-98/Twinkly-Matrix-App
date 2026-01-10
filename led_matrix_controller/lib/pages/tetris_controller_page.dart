import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../providers/app_state.dart';

class TetrisControllerPage extends ConsumerStatefulWidget {
  const TetrisControllerPage({super.key});

  @override
  ConsumerState<TetrisControllerPage> createState() => _TetrisControllerPageState();
}

class _TetrisControllerPageState extends ConsumerState<TetrisControllerPage> {
  String? _playerId;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    // Get or create player ID
    final prefs = await SharedPreferences.getInstance();
    _playerId = prefs.getString('player_id');
    if (_playerId == null) {
      _playerId = const Uuid().v4();
      await prefs.setString('player_id', _playerId!);
    }

    // Join game
    await _joinGame();

    // Start heartbeat timer (send every 10 seconds to prevent timeout)
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _sendHeartbeat();
    });
  }

  Future<void> _joinGame() async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final response = await http.post(
        Uri.parse('http://$fppIp:5000/api/game/join'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'player_id': _playerId,
          'phone_id': 'Phone',
          'game': 'tetris',
        }),
      );
      
      if (response.statusCode == 200) {
        debugPrint('Joined Tetris game: ${response.body}');
      } else {
        debugPrint('Failed to join game: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('Join game error: $e');
    }
  }

  Future<void> _sendHeartbeat() async {
    try {
      final fppIp = ref.read(fppIpProvider);
      await http.post(
        Uri.parse('http://$fppIp:5000/api/game/heartbeat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'player_id': _playerId}),
      );
    } catch (e) {
      debugPrint('Heartbeat error: $e');
    }
  }

  Future<void> _leaveGame() async {
    try {
      final fppIp = ref.read(fppIpProvider);
      debugPrint('🚀 Leaving Tetris game, sending leave request to $fppIp...');
      final response = await http.post(
        Uri.parse('http://$fppIp:5000/api/game/leave'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'player_id': _playerId}),
      ).timeout(const Duration(seconds: 5));
      debugPrint('✅ Leave game response: ${response.statusCode}');
    } catch (e) {
      debugPrint('❌ Leave game error: $e');
    }
  }

  Future<void> _sendCommand(String command) async {
    try {
      final fppIp = ref.read(fppIpProvider);
      await http.post(
        Uri.parse('http://$fppIp:5000/api/game/heartbeat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'player_id': _playerId,
          'cmd': command,
        }),
      );
    } catch (e) {
      debugPrint('Command send failed: $e');
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _leaveGame();
    super.dispose();
  }

  // Synchronous wrapper to ensure leave completes before dispose
  void _leaveGameSync() {
    _leaveGame().then((_) {
      debugPrint('✅ Leave game completed in dispose');
    }).catchError((e) {
      debugPrint('❌ Leave game failed in dispose: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        debugPrint('👈 Back button pressed, leaving game before navigation...');
        await _leaveGame();
        return true;  // Allow pop
      },
      child: Scaffold(
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
              // Store piece button (above/left of controls)
              Positioned(
                left: 30,
                bottom: 430,
                child: _TetrisButton(
                  icon: Icons.inventory_2,
                  color: Colors.amber,
                  size: 150,
                  onPressed: () => _sendCommand('STORE_PIECE'),
                ),
              ),

              // Center: Fast Drop button
              Positioned(
                left: screenWidth * 0.5 - 90,
                bottom: screenHeight * 0.40,
                child: _TetrisButton(
                  icon: Icons.arrow_downward,
                  color: Colors.orange,
                  size: 170,
                  onPressed: () => _sendCommand('MOVE_DOWN'),
                  onHeld: () => _sendCommand('HARD_DROP'),
                ),
              ),
              
              // Bottom Left: Move Left
              Positioned(
                left: 10,
                bottom: 140,
                child: _TetrisButton(
                  icon: Icons.arrow_back,
                  color: Colors.blue,
                  size: 190,
                  onPressed: () => _sendCommand('MOVE_LEFT'),
                  onHeld: () => _sendCommand('MOVE_LEFT_HELD'),
                ),
              ),
              
              // Above Left: Rotate Left
              Positioned(
                left: 20,
                bottom: 330,
                child: _TetrisButton(
                  icon: Icons.rotate_left,
                  color: Colors.cyan,
                  size: 150,
                  onPressed: () => _sendCommand('ROTATE_LEFT'),
                ),
              ),
              
              // Bottom Right: Move Right
              Positioned(
                right: 10,
                bottom: 140,
                child: _TetrisButton(
                  icon: Icons.arrow_forward,
                  color: Colors.green,
                  size: 190,
                  onPressed: () => _sendCommand('MOVE_RIGHT'),
                  onHeld: () => _sendCommand('MOVE_RIGHT_HELD'),
                ),
              ),
              
              // Above Right: Rotate Right
              Positioned(
                right: 20,
                bottom: 330,
                child: _TetrisButton(
                  icon: Icons.rotate_right,
                  color: Colors.pink,
                  size: 150,
                  onPressed: () => _sendCommand('ROTATE_RIGHT'),
                ),
              ),
            ],
          );
        },
      ),
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
    
    // Gentle haptic feedback on tap
    HapticFeedback.selectionClick();

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

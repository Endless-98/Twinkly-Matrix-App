import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/directional_pad.dart';
import '../providers/app_state.dart';

class ControllerPage extends ConsumerWidget {
  const ControllerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Controller'),
        centerTitle: true,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'D-Pad Control',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  DirectionalPad(
                    onUp: () => _sendCommand(ref, 'MOVE_UP'),
                    onDown: () => _sendCommand(ref, 'MOVE_DOWN'),
                    onLeft: () => _sendCommand(ref, 'MOVE_LEFT'),
                    onRight: () => _sendCommand(ref, 'MOVE_RIGHT'),
                  ),
                  const SizedBox(height: 36),
                  const Text(
                    'Action Buttons',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ActionButton(
                          label: 'A',
                          color: Colors.green,
                          onPressed: () => _sendCommand(ref, 'ACTION_A'),
                        ),
                        const SizedBox(width: 20),
                        _ActionButton(
                          label: 'B',
                          color: Colors.red,
                          onPressed: () => _sendCommand(ref, 'ACTION_B'),
                        ),
                        const SizedBox(width: 20),
                        _ActionButton(
                          label: 'X',
                          color: Colors.blue,
                          onPressed: () => _sendCommand(ref, 'ACTION_X'),
                        ),
                        const SizedBox(width: 20),
                        _ActionButton(
                          label: 'Y',
                          color: Colors.yellow,
                          onPressed: () => _sendCommand(ref, 'ACTION_Y'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SmallButton(
                        label: 'START',
                        onPressed: () => _sendCommand(ref, 'START'),
                      ),
                      const SizedBox(width: 24),
                      _SmallButton(
                        label: 'SELECT',
                        onPressed: () => _sendCommand(ref, 'SELECT'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Consumer(
                    builder: (context, ref, child) {
                      final fppIp = ref.watch(fppIpProvider);
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Connected to: $fppIp:5000',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _sendCommand(WidgetRef ref, String command) {
    // Here you would integrate with CommandSender
    // For now, just log the command
  }
}

class _ActionButton extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isPressed = true);
        widget.onPressed();
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
      },
      onTapCancel: () {
        setState(() => _isPressed = false);
      },
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withAlpha(_isPressed ? 200 : 255),
          border: Border.all(
            color: Colors.white,
            width: _isPressed ? 3 : 2,
          ),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;

  const _SmallButton({
    required this.label,
    required this.onPressed,
  });

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isPressed = true);
        widget.onPressed();
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
      },
      onTapCancel: () {
        setState(() => _isPressed = false);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: _isPressed ? Colors.blue : Colors.grey[700],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.white,
            width: _isPressed ? 2 : 1,
          ),
        ),
        child: Text(
          widget.label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

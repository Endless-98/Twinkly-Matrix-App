import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/directional_pad.dart';
import '../providers/app_state.dart';
import '../services/ddp_sender.dart';
import '../services/command_sender.dart';

class ControllerPage extends ConsumerStatefulWidget {
  const ControllerPage({super.key});

  @override
  ConsumerState<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends ConsumerState<ControllerPage> {
  bool _debugMode = false;

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

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
                  // Debug color mode toggle
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Debug color mode',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Each button paints the curtain a different color',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                        Switch(
                          value: _debugMode,
                          onChanged: (value) => setState(() => _debugMode = value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'D-Pad Control',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  DirectionalPad(
                    onUp: () => _sendCommand(ref, 'MOVE_UP', debugColor: Colors.red),
                    onDown: () => _sendCommand(ref, 'MOVE_DOWN', debugColor: Colors.blue),
                    onLeft: () => _sendCommand(ref, 'MOVE_LEFT', debugColor: Colors.green),
                    onRight: () => _sendCommand(ref, 'MOVE_RIGHT', debugColor: Colors.yellow),
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
                          onPressed: () => _sendCommand(ref, 'ACTION_A', debugColor: Colors.pinkAccent),
                        ),
                        const SizedBox(width: 20),
                        _ActionButton(
                          label: 'B',
                          color: Colors.red,
                          onPressed: () => _sendCommand(ref, 'ACTION_B', debugColor: Colors.orange),
                        ),
                        const SizedBox(width: 20),
                        _ActionButton(
                          label: 'X',
                          color: Colors.blue,
                          onPressed: () => _sendCommand(ref, 'ACTION_X', debugColor: Colors.cyan),
                        ),
                        const SizedBox(width: 20),
                        _ActionButton(
                          label: 'Y',
                          color: Colors.yellow,
                          onPressed: () => _sendCommand(ref, 'ACTION_Y', debugColor: Colors.purple),
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
                        onPressed: () => _sendCommand(ref, 'START', debugColor: Colors.white),
                      ),
                      const SizedBox(width: 24),
                      _SmallButton(
                        label: 'SELECT',
                        onPressed: () => _sendCommand(ref, 'SELECT', debugColor: Colors.grey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Container(
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
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _sendCommand(WidgetRef ref, String command, {Color? debugColor}) async {
    if (_debugMode && debugColor != null) {
      await _sendDebugColor(ref, debugColor);
      return;
    }

    // Fall back to sending the command to the backend (non-debug mode)
    try {
      final sender = await ref.read(commandSenderProvider.future);
      sender.sendCommand(command);
    } catch (e) {
      debugPrint('Command send failed: $e');
    }
  }

  Future<void> _sendDebugColor(WidgetRef ref, Color color) async {
    final fppIp = ref.read(fppIpProvider);
    final fppPort = ref.read(fppDdpPortProvider);

    // Build a solid color frame (90x50 RGB => 13,500 bytes)
    final frame = Uint8List(DDPSender.frameSize);
    for (int i = 0; i < frame.length; i += 3) {
      frame[i] = color.red;
      frame[i + 1] = color.green;
      frame[i + 2] = color.blue;
    }

    await DDPSender.sendFrameStatic(fppIp, frame, port: fppPort);
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

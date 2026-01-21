import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'tetris_controller_page.dart';

class GamesPage extends ConsumerWidget {
  const GamesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Select a Game',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),
              _GameButton(
                label: 'Tetris',
                icon: Icons.grid_4x4,
                onPressed: () => _launchTetris(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launchTetris(BuildContext context, WidgetRef ref) async {
    if (!context.mounted) return;

    // Show mode selection dialog
    final selectedMode = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Tetris Mode'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Choose your preferred Tetris mode:'),
              const SizedBox(height: 32),
              SizedBox(
                width: double.maxFinite,
                child: Column(
                  children: [
                    _ModeOption(
                      title: 'Classic',
                      description: 'Original NES-style Tetris',
                      modeIndex: 0,
                      color: Colors.cyan,
                      onTap: () => Navigator.pop(context, 0),
                    ),
                    const SizedBox(height: 16),
                    _ModeOption(
                      title: 'Modern',
                      description: 'Tetris Worlds Marathon rules',
                      modeIndex: 1,
                      color: Colors.lime,
                      onTap: () => Navigator.pop(context, 1),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selectedMode != null && context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => TetrisControllerPage(gamemode: selectedMode),
        ),
      );
    }
  }
}

class _GameButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _GameButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blue,
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeOption extends StatefulWidget {
  final String title;
  final String description;
  final int modeIndex;
  final Color color;
  final VoidCallback onTap;

  const _ModeOption({
    required this.title,
    required this.description,
    required this.modeIndex,
    required this.color,
    required this.onTap,
  });

  @override
  State<_ModeOption> createState() => _ModeOptionState();
}

class _ModeOptionState extends State<_ModeOption> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: widget.color.withOpacity(_isHovered ? 0.15 : 0.08),
            border: Border.all(
              color: widget.color,
              width: _isHovered ? 3 : 2,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: widget.color,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.description,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
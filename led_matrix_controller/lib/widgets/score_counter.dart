import 'package:flutter/material.dart';

class ScoreCounter extends StatelessWidget {
  final int score;
  final int level;
  final int lines;

  const ScoreCounter({
    super.key,
    required this.score,
    this.level = 1,
    this.lines = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.cyan,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.cyan.withOpacity(0.3),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ScoreStat(
            label: 'SCORE',
            value: score.toString(),
            color: Colors.cyan,
          ),
          const SizedBox(width: 24),
          _ScoreStat(
            label: 'LEVEL',
            value: level.toString(),
            color: Colors.amber,
          ),
          const SizedBox(width: 24),
          _ScoreStat(
            label: 'LINES',
            value: lines.toString(),
            color: Colors.lime,
          ),
        ],
      ),
    );
  }
}

class _ScoreStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _ScoreStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: color,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

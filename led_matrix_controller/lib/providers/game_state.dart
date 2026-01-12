import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

class GameScore {
  final int score;
  final int level;
  final int lines;
  final DateTime lastUpdated;

  GameScore({
    required this.score,
    this.level = 1,
    this.lines = 0,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  GameScore copyWith({
    int? score,
    int? level,
    int? lines,
  }) {
    return GameScore(
      score: score ?? this.score,
      level: level ?? this.level,
      lines: lines ?? this.lines,
    );
  }
}

// Simple state notifier for game score
class GameScoreNotifier extends StateNotifier<GameScore> {
  GameScoreNotifier()
      : super(GameScore(
          score: 0,
          level: 1,
          lines: 0,
        ));

  void updateScore(int newScore) {
    state = state.copyWith(score: newScore);
  }

  void updateLevel(int newLevel) {
    state = state.copyWith(level: newLevel);
  }

  void updateLines(int newLines) {
    state = state.copyWith(lines: newLines);
  }

  void updateGameState({
    required int score,
    required int level,
    required int lines,
  }) {
    state = GameScore(
      score: score,
      level: level,
      lines: lines,
    );
  }

  void reset() {
    state = GameScore(score: 0, level: 1, lines: 0);
  }
}

// Provider for game score state
final gameScoreProvider =
    StateNotifierProvider<GameScoreNotifier, GameScore>((ref) {
  return GameScoreNotifier();
});

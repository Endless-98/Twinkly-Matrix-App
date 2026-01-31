import 'dart:collection';
import 'package:flutter/foundation.dart';

/// A visible logging system that works in both debug and release builds.
/// Logs are stored in memory and can be displayed in the UI.
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  // Maximum number of log entries to keep
  static const int maxLogEntries = 200;

  // Log storage
  final Queue<LogEntry> _logs = Queue<LogEntry>();

  // Listeners for real-time updates
  final List<VoidCallback> _listeners = [];

  /// Get all log entries (newest first)
  List<LogEntry> get logs => _logs.toList().reversed.toList();

  /// Get recent logs (last N entries, newest first)
  List<LogEntry> getRecentLogs([int count = 50]) {
    final allLogs = logs;
    return allLogs.take(count).toList();
  }

  /// Add a listener for log updates
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  /// Remove a listener
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Log a message
  void log(String message, {String? module, LogLevel level = LogLevel.info}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      message: message,
      module: module,
      level: level,
    );

    _logs.add(entry);

    // Trim old entries
    while (_logs.length > maxLogEntries) {
      _logs.removeFirst();
    }

    // Also print to console for debug builds
    if (kDebugMode) {
      print('[${entry.levelPrefix}] ${entry.module != null ? "[${entry.module}] " : ""}${entry.message}');
    }

    _notifyListeners();
  }

  /// Log info
  void info(String message, {String? module}) {
    log(message, module: module, level: LogLevel.info);
  }

  /// Log warning
  void warn(String message, {String? module}) {
    log(message, module: module, level: LogLevel.warning);
  }

  /// Log error
  void error(String message, {String? module}) {
    log(message, module: module, level: LogLevel.error);
  }

  /// Log debug (only in debug mode)
  void debug(String message, {String? module}) {
    log(message, module: module, level: LogLevel.debug);
  }

  /// Log success
  void success(String message, {String? module}) {
    log(message, module: module, level: LogLevel.success);
  }

  /// Clear all logs
  void clear() {
    _logs.clear();
    _notifyListeners();
  }

  /// Export logs as string
  String export() {
    final buffer = StringBuffer();
    for (final entry in logs.reversed) {
      buffer.writeln(entry.toString());
    }
    return buffer.toString();
  }
}

enum LogLevel { debug, info, warning, error, success }

class LogEntry {
  final DateTime timestamp;
  final String message;
  final String? module;
  final LogLevel level;

  LogEntry({
    required this.timestamp,
    required this.message,
    this.module,
    required this.level,
  });

  String get levelPrefix {
    switch (level) {
      case LogLevel.debug:
        return '🔍';
      case LogLevel.info:
        return 'ℹ️';
      case LogLevel.warning:
        return '⚠️';
      case LogLevel.error:
        return '❌';
      case LogLevel.success:
        return '✅';
    }
  }

  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
  }

  @override
  String toString() {
    final moduleStr = module != null ? '[$module] ' : '';
    return '[$timeString] $levelPrefix $moduleStr$message';
  }
}

/// Global logger instance
final logger = AppLogger();

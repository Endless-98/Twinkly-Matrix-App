import 'dart:collection';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A visible logging system that works in both debug and release builds.
/// Logs are stored in memory and can be displayed in the UI.
/// Persists session logs to disk so crash reports survive app restarts.
class AppLogger {
  static final AppLogger _instance = AppLogger._internal();
  factory AppLogger() => _instance;
  AppLogger._internal();

  // Maximum number of log entries to keep
  static const int maxLogEntries = 200;
  static const String _crashLogKey = 'twinklywall_crash_log';
  static const String _crashInfoKey = 'twinklywall_crash_info';

  // Log storage
  final Queue<LogEntry> _logs = Queue<LogEntry>();

  // Listeners for real-time updates
  final List<VoidCallback> _listeners = [];

  // Session tracking for crash detection
  String _sessionId = '';
  bool _sessionActive = false;

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

  /// Initialize session tracking. Call at app startup.
  Future<void> startSession() async {
    _sessionId = DateTime.now().toIso8601String();
    _sessionActive = true;
    info('Session started: $_sessionId', module: 'SESSION');
    // Mark session as active (dirty) — will be cleared on clean exit
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('twinklywall_session_active', true);
    await prefs.setString('twinklywall_session_start', _sessionId);
  }

  /// Mark session as cleanly ended. Call on app dispose.
  Future<void> endSession() async {
    _sessionActive = false;
    info('Session ended cleanly', module: 'SESSION');
    await _persistLogs(); // Save final state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('twinklywall_session_active', false);
  }

  /// Check if the previous session crashed (didn't end cleanly).
  /// Returns crash info map or null if no crash.
  static Future<Map<String, String>?> checkForCrash() async {
    final prefs = await SharedPreferences.getInstance();
    final wasActive = prefs.getBool('twinklywall_session_active') ?? false;
    if (!wasActive) return null;

    final sessionStart = prefs.getString('twinklywall_session_start') ?? 'unknown';
    final crashLog = prefs.getString(_crashLogKey) ?? '';
    final crashInfo = prefs.getString(_crashInfoKey) ?? '';

    if (crashLog.isEmpty) return null;

    return {
      'sessionStart': sessionStart,
      'log': crashLog,
      'info': crashInfo,
    };
  }

  /// Clear stored crash data after the user has seen it.
  static Future<void> clearCrashData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_crashLogKey);
    await prefs.remove(_crashInfoKey);
    await prefs.setBool('twinklywall_session_active', false);
  }

  /// Persist current logs to SharedPreferences so they survive a crash.
  Future<void> _persistLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logText = export();
      await prefs.setString(_crashLogKey, logText);

      // Build crash info summary
      final errorLogs = _logs.where((e) => e.level == LogLevel.error).toList();
      final warnLogs = _logs.where((e) => e.level == LogLevel.warning).toList();
      final info = StringBuffer();
      info.writeln('Total logs: ${_logs.length}');
      info.writeln('Errors: ${errorLogs.length}');
      info.writeln('Warnings: ${warnLogs.length}');
      if (errorLogs.isNotEmpty) {
        info.writeln('\nLast errors:');
        for (final e in errorLogs.reversed.take(5)) {
          info.writeln('  ${e.toString()}');
        }
      }
      await prefs.setString(_crashInfoKey, info.toString());
    } catch (e) {
      debugPrint('[LOGGER] Failed to persist logs: $e');
    }
  }

  // Debounce persist calls — save at most every 2 seconds
  DateTime _lastPersist = DateTime(2000);

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

    // Auto-persist on errors, or every 2 seconds for other levels
    if (level == LogLevel.error || DateTime.now().difference(_lastPersist).inSeconds >= 2) {
      _lastPersist = DateTime.now();
      _persistLogs(); // fire-and-forget
    }
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

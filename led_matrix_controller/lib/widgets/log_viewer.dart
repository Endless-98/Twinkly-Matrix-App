import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_logger.dart';

/// A widget that displays live logs from the AppLogger
class LogViewer extends StatefulWidget {
  final bool expanded;
  final VoidCallback? onToggle;

  const LogViewer({
    super.key,
    this.expanded = false,
    this.onToggle,
  });

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  final ScrollController _scrollController = ScrollController();
  List<LogEntry> _logs = [];
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _logs = logger.getRecentLogs(100);
    logger.addListener(_onLogUpdate);
  }

  @override
  void dispose() {
    logger.removeListener(_onLogUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogUpdate() {
    setState(() {
      _logs = logger.getRecentLogs(100);
    });
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Color _getColorForLevel(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
      case LogLevel.success:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[700]!),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 16, color: Colors.green),
                const SizedBox(width: 8),
                const Text(
                  'Live Logs',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                // Copy button
                IconButton(
                  icon: const Icon(Icons.copy, size: 16),
                  color: Colors.grey,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Copy logs',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: logger.export()));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Logs copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                // Clear button
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  color: Colors.grey,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Clear logs',
                  onPressed: () {
                    logger.clear();
                  },
                ),
                const SizedBox(width: 8),
                // Toggle expand
                IconButton(
                  icon: Icon(
                    widget.expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                  ),
                  color: Colors.grey,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: widget.expanded ? 'Collapse' : 'Expand',
                  onPressed: widget.onToggle,
                ),
              ],
            ),
          ),
          // Log list
          if (widget.expanded)
            Expanded(
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs yet...',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final entry = _logs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                              children: [
                                TextSpan(
                                  text: '[${entry.timeString}] ',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                                TextSpan(
                                  text: '${entry.levelPrefix} ',
                                ),
                                if (entry.module != null)
                                  TextSpan(
                                    text: '[${entry.module}] ',
                                    style: TextStyle(
                                      color: Colors.cyan[300],
                                    ),
                                  ),
                                TextSpan(
                                  text: entry.message,
                                  style: TextStyle(
                                    color: _getColorForLevel(entry.level),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            )
          else
            // Collapsed view - show last 3 logs
            Container(
              height: 60,
              padding: const EdgeInsets.all(8),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs yet...',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _logs.take(3).length,
                      itemBuilder: (context, index) {
                        final entry = _logs.take(3).toList()[index];
                        return Text(
                          '${entry.levelPrefix} ${entry.message}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: _getColorForLevel(entry.level),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

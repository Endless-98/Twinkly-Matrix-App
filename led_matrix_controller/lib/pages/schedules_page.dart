import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import '../services/api_service.dart';
import '../providers/app_state.dart';

class SchedulesPage extends ConsumerStatefulWidget {
  const SchedulesPage({super.key});

  @override
  ConsumerState<SchedulesPage> createState() => _SchedulesPageState();
}

class _SchedulesPageState extends ConsumerState<SchedulesPage> {
  List<Map<String, dynamic>> _schedules = [];
  List<String> _videos = [];
  List<Map<String, dynamic>> _playlists = [];
  bool _isLoading = true;
  String? _error;

  static const _dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static const _colorOptions = <String, Color>{
    '#42A5F5': Color(0xFF42A5F5),
    '#66BB6A': Color(0xFF66BB6A),
    '#FFA726': Color(0xFFFFA726),
    '#EF5350': Color(0xFFEF5350),
    '#AB47BC': Color(0xFFAB47BC),
    '#26C6DA': Color(0xFF26C6DA),
    '#EC407A': Color(0xFFEC407A),
    '#FFEE58': Color(0xFFFFEE58),
    '#8D6E63': Color(0xFF8D6E63),
    '#78909C': Color(0xFF78909C),
  };

  Color _colorFromHex(String hex) =>
      _colorOptions[hex] ?? const Color(0xFF42A5F5);

  String _displayName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Convert "HH:MM" (24-hour) → "H:MM AM/PM"
  String _formatTime(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length < 2) return hhmm;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final period = h < 12 ? 'AM' : 'PM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} $period';
  }

  String _daysLabel(List<int> days) {
    if (days.length == 7) return 'Every day';
    if (days.length == 5 && !days.contains(5) && !days.contains(6)) {
      return 'Weekdays';
    }
    if (days.length == 2 && days.contains(5) && days.contains(6)) {
      return 'Weekends';
    }
    return days.map((d) => _dayLabels[d]).join(', ');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final fppIp = ref.read(fppIpProvider);
      final api = ApiService(host: fppIp);
      final results = await Future.wait([
        api.getSchedules(),
        api.getAvailableVideos(),
        api.getPlaylists(),
      ]);
      if (mounted) {
        setState(() {
          _schedules = results[0] as List<Map<String, dynamic>>;
          _videos = results[1] as List<String>;
          _playlists = results[2] as List<Map<String, dynamic>>;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _toggleEnabled(String id, bool enabled) async {
    // Optimistic update
    setState(() {
      final idx = _schedules.indexWhere((s) => s['id'] == id);
      if (idx >= 0) {
        _schedules[idx] = Map<String, dynamic>.from(_schedules[idx])
          ..['enabled'] = enabled;
      }
    });
    try {
      final fppIp = ref.read(fppIpProvider);
      await ApiService(host: fppIp).updateSchedule(id, {'enabled': enabled});
    } catch (e) {
      // Revert on failure
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _delete(String id, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Schedule'),
        content: Text('Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final fppIp = ref.read(fppIpProvider);
      await ApiService(host: fppIp).deleteSchedule(id);
      setState(() => _schedules.removeWhere((s) => s['id'] == id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showEditDialog([Map<String, dynamic>? existing]) async {
    // Capture mutable dialog state in local variables; StatefulBuilder re-renders.
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    String targetType = existing?['target_type'] ?? 'video';
    String target = existing?['target'] ?? '';
    final timeParts = (existing?['time'] ?? '20:00').split(':');
    TimeOfDay selectedTime = TimeOfDay(
      hour: int.tryParse(timeParts[0]) ?? 20,
      minute: int.tryParse(timeParts.length > 1 ? timeParts[1] : '0') ?? 0,
    );
    Set<int> days = Set<int>.from(
      existing?['days'] ?? [0, 1, 2, 3, 4, 5, 6],
    );
    bool loop = existing?['loop'] ?? true;
    bool enabled = existing?['enabled'] ?? true;
    String color = existing?['color'] ?? '#42A5F5';
    final fppIp = ref.read(fppIpProvider);

    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final targetOptions = targetType == 'playlist'
              ? _playlists.map((p) => p['name'] as String).toList()
              : _videos;

          // Reset target if it's no longer valid for the current type
          if (target.isNotEmpty && !targetOptions.contains(target)) {
            target = targetOptions.isNotEmpty ? targetOptions.first : '';
          }

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.calendar_today, size: 20, color: Colors.cyanAccent),
                const SizedBox(width: 8),
                Text(existing == null ? 'New Schedule' : 'Edit Schedule'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name (optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Target type selector
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'video',
                          label: Text('Video'),
                          icon: Icon(Icons.movie),
                        ),
                        ButtonSegment(
                          value: 'playlist',
                          label: Text('Folder'),
                          icon: Icon(Icons.folder),
                        ),
                      ],
                      selected: {targetType},
                      onSelectionChanged: (s) => setDlgState(() {
                        targetType = s.first;
                        target = '';
                      }),
                    ),
                    const SizedBox(height: 12),

                    // Target picker
                    if (targetOptions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No items available',
                            style: TextStyle(color: Colors.grey)),
                      )
                    else if (targetType == 'playlist')
                      DropdownButtonFormField<String>(
                        value: target.isNotEmpty ? target : null,
                        decoration: const InputDecoration(
                          labelText: 'Folder',
                          border: OutlineInputBorder(),
                        ),
                        items: targetOptions
                            .map((t) => DropdownMenuItem(
                                  value: t,
                                  child: Text(
                                    _displayName(t),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: (v) => setDlgState(() => target = v ?? ''),
                      )
                    else ...[
                      // Video thumbnail grid
                      const Text('Select Video',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 210,
                        child: GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
                            childAspectRatio: 1.35,
                          ),
                          itemCount: targetOptions.length,
                          itemBuilder: (_, idx) {
                            final name = targetOptions[idx];
                            final isSelected = name == target;
                            final thumbUrl =
                                ApiService(host: fppIp).getThumbnailUrl(name);
                            return GestureDetector(
                              onTap: () =>
                                  setDlgState(() => target = name),
                              child: AnimatedContainer(
                                duration:
                                    const Duration(milliseconds: 150),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.cyanAccent
                                        : Colors.transparent,
                                    width: 2.5,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: Colors.cyanAccent
                                                .withValues(alpha: 0.45),
                                            blurRadius: 8,
                                          )
                                        ]
                                      : null,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      // Thumbnail
                                      Image.network(
                                        thumbUrl,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, __, ___) =>
                                            Container(
                                          color: Colors.grey[850],
                                          child: Icon(Icons.movie,
                                              size: 24,
                                              color: Colors.grey[600]),
                                        ),
                                      ),
                                      // Bottom gradient + name
                                      Positioned(
                                        bottom: 0,
                                        left: 0,
                                        right: 0,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 4, vertical: 3),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.bottomCenter,
                                              end: Alignment.topCenter,
                                              colors: [
                                                Colors.black
                                                    .withValues(alpha: 0.85),
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                          child: Text(
                                            _displayName(name),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 9,
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                      // Selection checkmark badge
                                      if (isSelected)
                                        Positioned(
                                          top: 4,
                                          right: 4,
                                          child: Container(
                                            padding: const EdgeInsets.all(2),
                                            decoration: const BoxDecoration(
                                              color: Colors.cyanAccent,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(Icons.check,
                                                size: 10,
                                                color: Colors.black),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // Time picker
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: ctx,
                          initialTime: selectedTime,
                        );
                        if (picked != null) {
                          setDlgState(() => selectedTime = picked);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 14),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.access_time,
                                color: Colors.cyanAccent, size: 20),
                            const SizedBox(width: 10),
                            Text(
                              'Time: ${selectedTime.format(ctx)}',
                              style: const TextStyle(fontSize: 16),
                            ),
                            const Spacer(),
                            const Icon(Icons.chevron_right,
                                color: Colors.grey, size: 20),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Days of week
                    const Text('Days',
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(7, (i) {
                        final active = days.contains(i);
                        return GestureDetector(
                          onTap: () => setDlgState(() {
                            if (active) {
                              if (days.length > 1) days.remove(i);
                            } else {
                              days.add(i);
                            }
                          }),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: active
                                  ? Colors.cyanAccent
                                  : Colors.grey[800],
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                _dayLetters[i],
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color:
                                      active ? Colors.black : Colors.grey[400],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 16),

                    // Loop + Enabled
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Loop'),
                      value: loop,
                      onChanged: (v) => setDlgState(() => loop = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enabled'),
                      value: enabled,
                      onChanged: (v) => setDlgState(() => enabled = v),
                    ),

                    // Color
                    const Text('Color',
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _colorOptions.entries.map((e) {
                        final selected = e.key == color;
                        return GestureDetector(
                          onTap: () => setDlgState(() => color = e.key),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: e.value,
                              shape: BoxShape.circle,
                              border: selected
                                  ? Border.all(
                                      color: Colors.white, width: 3)
                                  : null,
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: e.value.withValues(alpha: 0.6),
                                        blurRadius: 8,
                                      )
                                    ]
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: target.isEmpty
                    ? null
                    : () {
                        final h = selectedTime.hour
                            .toString()
                            .padLeft(2, '0');
                        final m = selectedTime.minute
                            .toString()
                            .padLeft(2, '0');
                        final name = nameCtrl.text.trim();
                        Navigator.pop(ctx, {
                          'name': name.isEmpty ? _displayName(target) : name,
                          'enabled': enabled,
                          'target_type': targetType,
                          'target': target,
                          'time': '$h:$m',
                          'days': (days.toList()..sort()),
                          'loop': loop,
                          'color': color,
                        });
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black,
                ),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == null) return;

    try {
      final fppIp = ref.read(fppIpProvider);
      final api = ApiService(host: fppIp);
      if (existing != null) {
        await api.updateSchedule(existing['id'] as String, saved);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Schedule updated'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        await api.createSchedule(saved);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Schedule created'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedules'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showEditDialog(),
        icon: const Icon(Icons.add),
        label: const Text('New Schedule'),
        backgroundColor: Colors.cyanAccent,
        foregroundColor: Colors.black,
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_schedules.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_today,
                  size: 72, color: Colors.grey[700]),
              const SizedBox(height: 20),
              const Text(
                'No schedules yet',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey),
              ),
              const SizedBox(height: 10),
              const Text(
                'Tap + to schedule a video or folder\nto play automatically at a set time.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemCount: _schedules.length,
        itemBuilder: (_, i) => _buildCard(_schedules[i]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> s) {
    final id = s['id'] as String;
    final name = s['name'] as String? ?? '';
    final enabled = s['enabled'] as bool? ?? true;
    final target = s['target'] as String? ?? '';
    final targetType = s['target_type'] as String? ?? 'video';
    final timeStr = s['time'] as String? ?? '00:00';
    final days = List<int>.from(s['days'] ?? List.generate(7, (i) => i));
    final cardColor = _colorFromHex(s['color'] as String? ?? '#42A5F5');
    final isPlaylist = targetType == 'playlist';

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: enabled ? 6 : 2,
      child: InkWell(
        onTap: () => _showEditDialog(s),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: enabled
                  ? [
                      cardColor.withValues(alpha: 0.9),
                      cardColor.withValues(alpha: 0.35),
                      Colors.grey[900]!,
                    ]
                  : [
                      Colors.grey[850]!,
                      Colors.grey[900]!,
                    ],
              stops: enabled ? const [0.0, 0.5, 1.0] : const [0.0, 1.0],
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: enable switch + more menu
              Row(
                children: [
                  Transform.scale(
                    scale: 0.8,
                    alignment: Alignment.centerLeft,
                    child: Switch(
                      value: enabled,
                      onChanged: (v) => _toggleEnabled(id, v),
                      activeColor: Colors.cyanAccent,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert,
                        size: 18, color: Colors.white70),
                    onSelected: (v) {
                      if (v == 'edit') _showEditDialog(s);
                      if (v == 'delete') _delete(id, name);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(children: [
                          Icon(Icons.edit, size: 16),
                          SizedBox(width: 8),
                          Text('Edit'),
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete, size: 16, color: Colors.red),
                          SizedBox(width: 8),
                          Text('Delete',
                              style: TextStyle(color: Colors.red)),
                        ]),
                      ),
                    ],
                  ),
                ],
              ),

              // Big time display
              Text(
                _formatTime(timeStr),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: enabled ? Colors.white : Colors.white38,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 6),

              // Days summary label
              Text(
                _daysLabel(days),
                style: TextStyle(
                  fontSize: 11,
                  color: enabled ? Colors.white70 : Colors.white24,
                ),
              ),
              const SizedBox(height: 6),

              // Day dot indicators
              _buildDayDots(days, enabled),

              const Spacer(),

              // Divider
              Divider(
                color: Colors.white.withValues(alpha: 0.15),
                height: 16,
              ),

              // Target info
              Row(
                children: [
                  Icon(
                    isPlaylist ? Icons.folder : Icons.movie,
                    size: 14,
                    color: Colors.white60,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      name.isNotEmpty ? name : _displayName(target),
                      style: TextStyle(
                        fontSize: 12,
                        color: enabled ? Colors.white : Colors.white38,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDayDots(List<int> activeDays, bool enabled) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(7, (i) {
        final active = activeDays.contains(i);
        return Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: active && enabled
                ? Colors.cyanAccent.withValues(alpha: 0.25)
                : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: active && enabled
                  ? Colors.cyanAccent
                  : Colors.white12,
              width: 1.5,
            ),
          ),
          child: Center(
            child: Text(
              _dayLetters[i],
              style: TextStyle(
                fontSize: 9,
                fontWeight:
                    active ? FontWeight.bold : FontWeight.normal,
                color: active && enabled
                    ? Colors.cyanAccent
                    : Colors.white24,
              ),
            ),
          ),
        );
      }),
    );
  }
}

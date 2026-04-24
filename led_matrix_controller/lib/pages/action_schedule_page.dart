import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../providers/app_state.dart';

// ---------------------------------------------------------------------------
// Action definitions
// ---------------------------------------------------------------------------

const _kActions = [
  {
    'id': 'turn_off',
    'label': 'Turn Off',
    'subtitle': 'Stop playback and turn the curtain dark',
  },
  {
    'id': 'set_brightness',
    'label': 'Set Brightness',
    'subtitle': 'Change brightness without changing what\'s playing',
  },
];

IconData _iconForAction(String id) {
  switch (id) {
    case 'turn_off':
      return Icons.power_settings_new;
    case 'set_brightness':
      return Icons.brightness_6;
    default:
      return Icons.bolt;
  }
}

String _labelForAction(String id) {
  for (final a in _kActions) {
    if (a['id'] == id) return a['label'] as String;
  }
  return id;
}

// ---------------------------------------------------------------------------
// Card color swatches (shared with SchedulesPage)
// ---------------------------------------------------------------------------

const _kColorOptions = <String, Color>{
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

const _kDayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

class ActionSchedulePage extends ConsumerStatefulWidget {
  /// Pass an existing schedule map to open in edit mode.
  final Map<String, dynamic>? existing;

  const ActionSchedulePage({super.key, this.existing});

  @override
  ConsumerState<ActionSchedulePage> createState() => _ActionSchedulePageState();
}

class _ActionSchedulePageState extends ConsumerState<ActionSchedulePage> {
  final _nameCtrl = TextEditingController();

  String _actionId = '';
  double _brightness = 1.0;
  TimeOfDay _time = const TimeOfDay(hour: 20, minute: 0);
  Set<int> _days = {0, 1, 2, 3, 4, 5, 6};
  bool _enabled = true;
  String _color = '#42A5F5';

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text = e['name'] as String? ?? '';
      _actionId = e['target'] as String? ?? '';
      _enabled = e['enabled'] as bool? ?? true;
      _color = e['color'] as String? ?? '#42A5F5';
      final timeParts = ((e['time'] as String?) ?? '20:00').split(':');
      _time = TimeOfDay(
        hour: int.tryParse(timeParts[0]) ?? 20,
        minute: int.tryParse(timeParts.length > 1 ? timeParts[1] : '0') ?? 0,
      );
      _days = Set<int>.from(e['days'] ?? [0, 1, 2, 3, 4, 5, 6]);
      final params = e['action_params'];
      if (params is Map) {
        _brightness = (params['brightness'] as num?)?.toDouble() ?? 1.0;
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    if (_actionId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an action'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _saving = true);

    final Map<String, dynamic> actionParams =
        _actionId == 'set_brightness' ? {'brightness': _brightness} : {};

    final name = _nameCtrl.text.trim();
    final h = _time.hour.toString().padLeft(2, '0');
    final m = _time.minute.toString().padLeft(2, '0');

    final payload = {
      'name': name.isEmpty ? _labelForAction(_actionId) : name,
      'enabled': _enabled,
      'target_type': 'action',
      'target': _actionId,
      'action_params': actionParams,
      'time': '$h:$m',
      'days': (_days.toList()..sort()),
      'loop': false,
      'play_count': 1,
      'random_pick': false,
      'color': _color,
    };

    try {
      final fppIp = ref.read(fppIpProvider);
      final api = ApiService(host: fppIp);
      if (widget.existing != null) {
        await api.updateSchedule(widget.existing!['id'] as String, payload);
      } else {
        await api.createSchedule(payload);
      }
      if (mounted) {
        Navigator.of(context).pop(true); // signal reload
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
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
    final isEdit = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit Action Schedule' : 'Schedule Action'),
        centerTitle: true,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text(
                'Save',
                style: TextStyle(
                  color: Colors.deepPurpleAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          // ── Name ────────────────────────────────────────────────────────
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),

          // ── Action picker ────────────────────────────────────────────────
          const Text(
            'ACTION',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          ..._kActions.map((a) {
            final id = a['id'] as String;
            final label = a['label'] as String;
            final sub = a['subtitle'] as String;
            final selected = _actionId == id;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => setState(() {
                  _actionId = id;
                  _brightness = 1.0;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected
                          ? Colors.deepPurpleAccent
                          : Colors.grey.shade700,
                      width: selected ? 2 : 1,
                    ),
                    color: selected
                        ? Colors.deepPurpleAccent.withValues(alpha: 0.12)
                        : Colors.grey[900],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.deepPurpleAccent.withValues(alpha: 0.25)
                              : Colors.grey[800],
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _iconForAction(id),
                          color: selected
                              ? Colors.deepPurpleAccent
                              : Colors.white54,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color:
                                    selected ? Colors.deepPurpleAccent : Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sub,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      if (selected)
                        const Icon(Icons.check_circle,
                            color: Colors.deepPurpleAccent, size: 20),
                    ],
                  ),
                ),
              ),
            );
          }),

          // ── Brightness slider ────────────────────────────────────────────
          if (_actionId == 'set_brightness') ...[
            const SizedBox(height: 4),
            const Text(
              'BRIGHTNESS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.brightness_low, size: 18, color: Colors.grey),
                Expanded(
                  child: Slider(
                    value: _brightness,
                    min: 0.05,
                    max: 2.0,
                    divisions: 39,
                    activeColor: Colors.deepPurpleAccent,
                    onChanged: (v) => setState(() => _brightness = v),
                  ),
                ),
                const Icon(Icons.brightness_high,
                    size: 18, color: Colors.grey),
              ],
            ),
            Center(
              child: Text(
                '${(_brightness * 100).round()}%',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.deepPurpleAccent,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          const SizedBox(height: 16),

          // ── Time ─────────────────────────────────────────────────────────
          const Text(
            'TIME',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: _time,
              );
              if (picked != null) setState(() => _time = picked);
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade700),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time,
                      color: Colors.deepPurpleAccent, size: 22),
                  const SizedBox(width: 12),
                  Text(
                    _time.format(context),
                    style: const TextStyle(fontSize: 18),
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right,
                      color: Colors.grey, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── Days ──────────────────────────────────────────────────────────
          const Text(
            'DAYS',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (i) {
              final active = _days.contains(i);
              return GestureDetector(
                onTap: () => setState(() {
                  if (active) {
                    if (_days.length > 1) _days.remove(i);
                  } else {
                    _days.add(i);
                  }
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.deepPurpleAccent
                        : Colors.grey[800],
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      _kDayLetters[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: active ? Colors.white : Colors.grey[500],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 24),

          // ── Card color ────────────────────────────────────────────────────
          const Text(
            'CARD COLOR',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _kColorOptions.entries.map((e) {
              final selected = e.key == _color;
              return GestureDetector(
                onTap: () => setState(() => _color = e.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: e.value,
                    shape: BoxShape.circle,
                    border: selected
                        ? Border.all(color: Colors.white, width: 3)
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
          const SizedBox(height: 24),

          // ── Enabled toggle ────────────────────────────────────────────────
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text('Run this action on its scheduled days'),
            value: _enabled,
            activeColor: Colors.deepPurpleAccent,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import '../providers/app_state.dart';

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
  '#1565C0': Color(0xFF1565C0),
};

Color _hexToColor(String hex) =>
    _kColorOptions[hex] ?? const Color(0xFF1565C0);

// ---------------------------------------------------------------------------

class SmartSchedulePage extends ConsumerStatefulWidget {
  const SmartSchedulePage({super.key});

  @override
  ConsumerState<SmartSchedulePage> createState() => _SmartSchedulePageState();
}

class _SmartSchedulePageState extends ConsumerState<SmartSchedulePage> {
  bool _isLoading = true;
  String? _error;
  bool _saving = false;

  // Dodger Time
  bool _dodgerEnabled = false;
  String _dodgerTargetType = 'video';
  String _dodgerTarget = '';
  String _dodgerColor = '#1565C0';
  String? _dodgerNextGame; // ISO UTC string from MLB API cache

  List<String> _videos = [];
  List<Map<String, dynamic>> _playlists = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final fppIp = ref.read(fppIpProvider);
      final api = ApiService(host: fppIp);
      final results = await Future.wait([
        api.getSmartSchedules(),
        api.getAvailableVideos(),
        api.getPlaylists(),
      ]);
      final config = results[0] as Map<String, dynamic>;
      final videos = results[1] as List<String>;
      final playlists = results[2] as List<Map<String, dynamic>>;

      if (mounted) {
        setState(() {
          final dt = config['dodger_time'] as Map<String, dynamic>? ?? {};
          _dodgerEnabled = dt['enabled'] as bool? ?? false;
          _dodgerTargetType = dt['target_type'] as String? ?? 'video';
          _dodgerTarget = dt['target'] as String? ?? '';
          _dodgerColor = dt['color'] as String? ?? '#1565C0';

          final ng = config['next_game'] as Map<String, dynamic>? ?? {};
          _dodgerNextGame = ng['dodger_time'] as String?;

          _videos = videos;
          _playlists = playlists;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _save() async {
    if (_dodgerEnabled && _dodgerTarget.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a sequence or folder'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final fppIp = ref.read(fppIpProvider);
      await ApiService(host: fppIp).updateSmartSchedules({
        'dodger_time': {
          'enabled': _dodgerEnabled,
          'target_type': _dodgerTargetType,
          'target': _dodgerTarget,
          'color': _dodgerColor,
          'name': 'Dodger Time',
        },
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _displayName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String _formatGameTime(String? isoUtc) {
    if (isoUtc == null) return 'No game today';
    try {
      final utc = DateTime.parse(isoUtc.replaceAll('Z', '+00:00'));
      // Mountain Time = UTC-6 (MDT) or UTC-7 (MST); approximate with UTC-6 for summer season
      final mtn = utc.toLocal(); // device will be in local time — server handles Mountain Time
      final h = utc.subtract(const Duration(hours: 6)).hour;
      final m = utc.subtract(const Duration(hours: 6)).minute;
      final period = h < 12 ? 'AM' : 'PM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:${m.toString().padLeft(2, '0')} $period MT';
    } catch (_) {
      return isoUtc;
    }
  }

  List<String> get _targetOptions => _dodgerTargetType == 'playlist'
      ? _playlists.map((p) => p['name'] as String).toList()
      : _videos;

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[950] ?? const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text('Smart Schedule'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _save,
              child: const Text('Save',
                  style: TextStyle(
                      color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildBody(),
    );
  }

  Widget _buildError() {
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

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildDodgerTimeSection(),
      ],
    );
  }

  Widget _buildDodgerTimeSection() {
    final accentColor = _hexToColor(_dodgerColor);
    final targets = _targetOptions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(Icons.sports_baseball,
                color: Colors.white70, size: 22),
            const SizedBox(width: 10),
            const Text(
              'Dodger Time',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const Spacer(),
            Switch(
              value: _dodgerEnabled,
              onChanged: (v) => setState(() => _dodgerEnabled = v),
              activeColor: Colors.cyanAccent,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Automatically plays when a Dodger game starts (Mountain Time). '
          'The curtain checks every minute.',
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),

        // Next game info card
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              Icon(Icons.event, size: 18, color: Colors.white54),
              const SizedBox(width: 10),
              Text(
                _dodgerNextGame != null
                    ? 'Today\'s game: ${_formatGameTime(_dodgerNextGame)}'
                    : 'No Dodger game today',
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),
        const Divider(color: Colors.white12),
        const SizedBox(height: 16),

        // Target type picker
        const Text('Play',
            style: TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'video',
              label: Text('Sequence'),
              icon: Icon(Icons.movie),
            ),
            ButtonSegment(
              value: 'playlist',
              label: Text('Folder'),
              icon: Icon(Icons.folder),
            ),
          ],
          selected: {_dodgerTargetType},
          onSelectionChanged: (s) => setState(() {
            _dodgerTargetType = s.first;
            _dodgerTarget = '';
          }),
        ),
        const SizedBox(height: 16),

        // Target picker
        if (_dodgerTargetType == 'playlist') ...[
          DropdownButtonFormField<String>(
            value: _dodgerTarget.isNotEmpty ? _dodgerTarget : null,
            decoration: const InputDecoration(
              labelText: 'Folder',
              border: OutlineInputBorder(),
            ),
            hint: const Text('Select a folder'),
            items: targets
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) => setState(() => _dodgerTarget = v ?? ''),
          ),
        ] else if (targets.isEmpty)
          const Text('No sequences available',
              style: TextStyle(color: Colors.grey))
        else ...[
          const Text('Select Sequence',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: GridView.builder(
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
                childAspectRatio: 1.35,
              ),
              itemCount: targets.length,
              itemBuilder: (_, idx) {
                final name = targets[idx];
                final isSelected = name == _dodgerTarget;
                final fppIp = ref.read(fppIpProvider);
                final thumbUrl =
                    ApiService(host: fppIp).getThumbnailUrl(name);
                return GestureDetector(
                  onTap: () => setState(() => _dodgerTarget = name),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
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
                          Image.network(
                            thumbUrl,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey[850],
                              child: Icon(Icons.movie,
                                  size: 24, color: Colors.grey[600]),
                            ),
                          ),
                          if (isSelected)
                            Positioned(
                              right: 4,
                              top: 4,
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: Colors.cyanAccent,
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(2),
                                child: const Icon(Icons.check,
                                    size: 10, color: Colors.black),
                              ),
                            ),
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 2),
                              color: Colors.black54,
                              child: Text(
                                _displayName(name),
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.white),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
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

        const SizedBox(height: 24),
        const Divider(color: Colors.white12),
        const SizedBox(height: 16),

        // Card color picker
        const Text('Card Color',
            style: TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _kColorOptions.entries.map((e) {
            final selected = e.key == _dodgerColor;
            return GestureDetector(
              onTap: () => setState(() => _dodgerColor = e.key),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: e.value,
                  shape: BoxShape.circle,
                  border: selected
                      ? Border.all(color: Colors.white, width: 3)
                      : Border.all(color: Colors.transparent, width: 3),
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

        const SizedBox(height: 32),
      ],
    );
  }
}

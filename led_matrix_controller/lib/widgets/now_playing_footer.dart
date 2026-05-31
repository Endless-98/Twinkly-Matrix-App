import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../services/api_service.dart';

/// Global floating "Now Playing" footer.
///
/// Rendered via [MaterialApp.builder] so it floats above every screen
/// in the navigation stack. Only visible when something is playing.
class NowPlayingFooter extends ConsumerWidget {
  const NowPlayingFooter({super.key});

  String _displayName(String filename) {
    final isPlaylist = filename.startsWith('playlist:');
    if (isPlaylist) return '📁 ${filename.substring('playlist:'.length)}';
    final lastDot = filename.lastIndexOf('.');
    if (lastDot > 0) return filename.substring(0, lastDot);
    return filename;
  }

  Future<void> _stop(BuildContext context, WidgetRef ref) async {
    try {
      final fppIp = ref.read(fppIpProvider);
      final api = ApiService(host: fppIp);
      await api.stopPlayback();
      ref.read(nowPlayingProvider.notifier).setPlaying(null);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stop failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(nowPlayingProvider);
    if (!state.isPlaying || state.videoName == null) return const SizedBox.shrink();

    final title = _displayName(state.videoName!);

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.green[900]!.withValues(alpha: 0.97),
          border: Border(
            top: BorderSide(color: Colors.green[700]!, width: 1),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 10,
              offset: const Offset(0, -3),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.play_circle_fill, color: Colors.greenAccent, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NOW PLAYING',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => _stop(context, ref),
              icon: const Icon(Icons.stop_circle_outlined, size: 20),
              label: const Text('Stop'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red[300],
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

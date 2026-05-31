import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ddp_sender.dart';
import '../services/command_sender.dart';
import '../services/api_service.dart';

enum ActiveMode { games, mirroring, scenes }
enum CaptureMode { desktop, appWindow, region }
enum CastMode { fullScreen, bubble }

// FPP IP Address Provider
final fppIpProvider = StateProvider<String>((ref) {
  return '192.168.1.68';
});

// FPP DDP Port Provider (default to debug bridge port 4049; app also falls back to 4048 where needed)
final fppDdpPortProvider = StateProvider<int>((ref) {
  return 4049;
});

// Active Mode Provider
final activeModeProvider = StateProvider<ActiveMode>((ref) {
  return ActiveMode.games;
});

// Cast Mode Provider (full screen or bubble overlay)
final castModeProvider = StateProvider<CastMode>((ref) {
  return CastMode.fullScreen;
});

// Capture Mode Provider (for screen mirroring)
final captureModeProvider = StateProvider<CaptureMode>((ref) {
  return CaptureMode.desktop;
});

// Selected Window Title Provider (for app window capture)
final selectedWindowProvider = StateProvider<String?>((ref) {
  return null;
});

// Capture Region Provider (for region capture: x, y, width, height)
final captureRegionProvider = StateProvider<Map<String, int>>((ref) {
  return {'x': 0, 'y': 0, 'width': 800, 'height': 600};
});

// Bubble position on the LED curtain (in LED pixel coordinates, 0-89 x, 0-49 y)
final bubblePositionProvider = StateProvider<Offset>((ref) {
  return const Offset(0.0, 0.0); // default: top-left (full curtain)
});

// Bubble size on the LED curtain (width x height in LED pixels)
// Default: full curtain 90×50
final bubbleSizeProvider = StateProvider<Size>((ref) {
  return const Size(90.0, 50.0);
});

// Screen crop region for bubble mode (portion of phone screen to capture)
// Values are 0.0-1.0 normalized fractions of screen dimensions
final screenCropProvider = StateProvider<Rect>((ref) {
  return const Rect.fromLTWH(0.0, 0.0, 1.0, 1.0); // default: full screen
});

// DDP Sender Provider
final ddpSenderProvider = FutureProvider<DdpSender>((ref) async {
  final fppIp = ref.watch(fppIpProvider);
  final fppPort = ref.watch(fppDdpPortProvider);
  final ddpSender = DdpSender(host: fppIp, port: fppPort);
  await ddpSender.initialize();
  return ddpSender;
});

// Command Sender Provider
final commandSenderProvider = FutureProvider<CommandSender>((ref) async {
  final fppIp = ref.watch(fppIpProvider);
  final commandSender = CommandSender(host: fppIp, port: 5000);
  await commandSender.initialize();
  return commandSender;
});

// ---------------------------------------------------------------------------
// Now Playing — global state polled from /api/status every 3 seconds
// ---------------------------------------------------------------------------

class NowPlayingState {
  final String? videoName;
  final bool isPlaying;
  const NowPlayingState({this.videoName, this.isPlaying = false});
}

class NowPlayingNotifier extends StateNotifier<NowPlayingState> {
  final Ref _ref;
  Timer? _timer;

  NowPlayingNotifier(this._ref) : super(const NowPlayingState()) {
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final fppIp = _ref.read(fppIpProvider);
      final api = ApiService(host: fppIp);
      final status = await api.getStatus();
      final playing = status['playing'] == true;
      final video = status['video'] as String?;
      if (mounted) {
        state = NowPlayingState(
          videoName: playing ? video : null,
          isPlaying: playing,
        );
      }
    } catch (_) {
      // Keep old state on network error
    }
  }

  /// Force-update state immediately (called after a play/stop action in the UI).
  void setPlaying(String? videoName) {
    state = NowPlayingState(videoName: videoName, isPlaying: videoName != null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final nowPlayingProvider =
    StateNotifierProvider<NowPlayingNotifier, NowPlayingState>(
  (ref) => NowPlayingNotifier(ref),
);

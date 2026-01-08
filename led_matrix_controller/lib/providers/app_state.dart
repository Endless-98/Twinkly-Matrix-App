import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ddp_sender.dart';
import '../services/command_sender.dart';

enum ActiveMode { controller, mirroring, video }
enum CaptureMode { desktop, appWindow, region }

// FPP IP Address Provider
final fppIpProvider = StateProvider<String>((ref) {
  return '192.168.1.68';
});

// FPP DDP Port Provider (default to native FPP DDP port 4048)
final fppDdpPortProvider = StateProvider<int>((ref) {
  return 4048;
});

// Active Mode Provider
final activeModeProvider = StateProvider<ActiveMode>((ref) {
  return ActiveMode.controller;
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

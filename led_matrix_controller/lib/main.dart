import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/games_page.dart';
import 'pages/cast_bubble_page.dart';
import 'pages/scenes_selector_page.dart';
import 'pages/schedules_page.dart';
import 'providers/app_state.dart';
import 'services/api_service.dart';
import 'services/app_logger.dart';
import 'widgets/now_playing_footer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch unhandled Flutter errors
  FlutterError.onError = (details) {
    logger.error('Flutter error: ${details.exceptionAsString()}', module: 'CRASH');
    if (details.stack != null) {
      logger.error('Stack: ${details.stack.toString().split('\n').take(10).join('\n')}', module: 'CRASH');
    }
  };

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LED Matrix Controller',
      theme: ThemeData.dark(),
      home: const HomePage(),
      builder: (context, child) {
        // Wraps every screen with the global Now Playing footer overlay.
        return Stack(
          children: [
            child ?? const SizedBox.shrink(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: const NowPlayingFooter(),
            ),
          ],
        );
      },
    );
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSession();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    logger.endSession();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      logger.endSession();
    } else if (state == AppLifecycleState.resumed) {
      logger.startSession();
    }
  }

  Future<void> _initSession() async {
    // Check for previous crash
    final crashData = await AppLogger.checkForCrash();
    if (crashData != null && mounted) {
      // Show crash report dialog
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showCrashReport(crashData);
      });
    }
    await AppLogger.clearCrashData();
    await logger.startSession();
  }

  void _showCrashReport(Map<String, String> crashData) {
    showDialog(
      context: context,
      builder: (context) {
        final logText = crashData['log'] ?? '';
        final infoText = crashData['info'] ?? '';
        final sessionStart = crashData['sessionStart'] ?? 'unknown';

        final fullReport = StringBuffer();
        fullReport.writeln('=== TwinklyWall Crash Report ===');
        fullReport.writeln('Session started: $sessionStart');
        fullReport.writeln('App did not exit cleanly (likely crashed or was killed).');
        fullReport.writeln('');
        fullReport.writeln('--- Summary ---');
        fullReport.writeln(infoText);
        fullReport.writeln('');
        fullReport.writeln('--- Full Log ---');
        fullReport.writeln(logText);

        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
              SizedBox(width: 12),
              Expanded(child: Text('Previous Session Crashed')),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The app did not exit cleanly last time. '
                  'Here is the log from that session.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                ),
                const SizedBox(height: 8),
                if (infoText.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      infoText,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const Text('Full Log:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        logText,
                        style: const TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: fullReport.toString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Crash report copied to clipboard')),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy to Clipboard'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Dismiss'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('LED Matrix Controller'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.settings),
            onSelected: (value) async {
              if (value == 'restart_device') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Row(
                      children: [
                        Icon(Icons.restart_alt, color: Colors.orange),
                        SizedBox(width: 8),
                        Text('Restart FPP Device'),
                      ],
                    ),
                    content: const Text(
                      'This will reboot the FPP device. Playback will stop and '
                      'the wall will be unavailable for ~30 seconds.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                        child: const Text('Restart'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                try {
                  final api = ApiService(host: ref.read(fppIpProvider));
                  await api.restartDevice();
                  ref.read(nowPlayingProvider.notifier).setPlaying(null);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('FPP device is rebooting…'),
                        backgroundColor: Colors.orange,
                        duration: Duration(seconds: 5),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Restart failed: $e'), backgroundColor: Colors.red),
                    );
                  }
                }
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'FPP IP Address',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: 200,
                      child: TextField(
                        controller: TextEditingController(text: fppIp),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '192.168.1.100',
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          isDense: true,
                        ),
                        onChanged: (value) {
                          if (value.isNotEmpty) {
                            ref.read(fppIpProvider.notifier).state = value;
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'restart_device',
                child: Row(
                  children: [
                    Icon(Icons.restart_alt, color: Colors.orange, size: 20),
                    SizedBox(width: 10),
                    Text('Restart FPP Device', style: TextStyle(color: Colors.orange)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 60),
            const Text(
              'LED Wall Control',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 80),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    'Select Mode',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  Column(
                    children: [
                      _ModeButton(
                        label: 'Games',
                        icon: Icons.videogame_asset,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const GamesPage(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      _ModeButton(
                        label: 'Scenes',
                        icon: Icons.movie,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const ScenesSelectorPage(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      _ModeButton(
                        label: 'Cast',
                        icon: Icons.cast,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const CastBubblePage(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      _ModeButton(
                        label: 'Schedules',
                        icon: Icons.calendar_today,
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const SchedulesPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final double iconSize;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.iconSize = 28,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blue,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: iconSize),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:typed_data';
import '../services/platform_screen_capture.dart';
import '../services/ddp_sender.dart';
import '../services/app_logger.dart';
import '../providers/app_state.dart';
import '../widgets/region_selector_overlay.dart';
import '../widgets/log_viewer.dart';
import '../widgets/network_test_dialog.dart';

/// Fold a 90×100 RGB frame to 90×50 by averaging adjacent row pairs.
/// Input: 27000 bytes (90×100×3)
/// Output: 13500 bytes (90×50×3)
Uint8List _fold90x100To90x50(Uint8List frame90x100) {
  const srcW = 90, dstW = 90, dstH = 50;
  final result = Uint8List(dstW * dstH * 3);
  
  for (int outRow = 0; outRow < dstH; outRow++) {
    final srcRow1 = outRow * 2;
    final srcRow2 = srcRow1 + 1;
    
    for (int col = 0; col < dstW; col++) {
      // Get pixel from row1 and row2
      final idx1 = (srcRow1 * srcW + col) * 3;
      final idx2 = (srcRow2 * srcW + col) * 3;
      final outIdx = (outRow * dstW + col) * 3;
      
      // Average the two rows
      result[outIdx] = ((frame90x100[idx1] + frame90x100[idx2]) ~/ 2).clamp(0, 255);
      result[outIdx + 1] = ((frame90x100[idx1 + 1] + frame90x100[idx2 + 1]) ~/ 2).clamp(0, 255);
      result[outIdx + 2] = ((frame90x100[idx1 + 2] + frame90x100[idx2 + 2]) ~/ 2).clamp(0, 255);
    }
  }
  
  return result;
}

class MirroringPage extends ConsumerStatefulWidget {
  const MirroringPage({super.key});

  @override
  ConsumerState<MirroringPage> createState() => _MirroringPageState();
}

class _MirroringPageState extends ConsumerState<MirroringPage> with WidgetsBindingObserver {
  bool isCapturing = false;
  String statusMessage = "Ready";
  int frameCount = 0;
  double currentFps = 0.0;
  List<String> availableWindows = [];
  bool isLoadingWindows = false;
  bool isInitializing = false;
  late ScreenCaptureCapabilities capabilities;
  bool _logsExpanded = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    capabilities = PlatformScreenCaptureService.getCapabilities();
    _initializeStatus();
    logger.info('Mirroring page initialized', module: 'UI');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Log lifecycle changes but DO NOT stop capturing
    // This allows screen mirroring to continue when app is in background/unfocused
    logger.info('App lifecycle changed to: $state', module: 'UI');
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      logger.info('App backgrounded/unfocused - capture continues', module: 'UI');
    } else if (state == AppLifecycleState.resumed) {
      logger.info('App resumed/focused - capture continues', module: 'UI');
    }
  }

  Future<void> _initializeStatus() async {
    if (Platform.isAndroid) {
      final capturing = await PlatformScreenCaptureService.isCapturing();
      setState(() {
        isCapturing = capturing;
        statusMessage = capturing ? "Capturing screen" : "Ready to capture";
      });
    } else {
      setState(() {
        statusMessage = "Ready - ${capabilities.captureMethod}";
      });
    }
  }

  Future<void> _startMirroringLoop() async {
    final captureMode = ref.read(captureModeProvider);
    final selectedWindow = ref.read(selectedWindowProvider);
    final captureRegion = ref.read(captureRegionProvider);

    // Validate mode-specific requirements
    if (captureMode == CaptureMode.appWindow && selectedWindow == null) {
      setState(() {
        statusMessage = "⚠️ Please select a window first";
      });
      return;
    }

    // Configure capture mode
    switch (captureMode) {
      case CaptureMode.desktop:
        PlatformScreenCaptureService.setCaptureMode(CaptureMode.desktop);
        break;
      case CaptureMode.appWindow:
        PlatformScreenCaptureService.setCaptureMode(
          CaptureMode.appWindow,
          windowTitle: selectedWindow,
        );
        break;
      case CaptureMode.region:
        PlatformScreenCaptureService.setCaptureMode(
          CaptureMode.region,
          x: captureRegion['x'],
          y: captureRegion['y'],
          width: captureRegion['width'],
          height: captureRegion['height'],
        );
        break;
    }

    final fppIp = ref.read(fppIpProvider);
    final fppPort = ref.read(fppDdpPortProvider);
    final fallbackPort = fppPort == 4048 ? null : 4048;

    setState(() {
      isCapturing = true;
      statusMessage = "🔄 Initializing capture...";
      frameCount = 0;
      currentFps = 0.0;
    });

    DDPSender.setDebugLevel(1);

    // Timing tracking
    int totalMsAcc = 0;
    int captureMsAcc = 0;
    int sendMsAcc = 0;

    const targetIntervalMs = 50; // 20 FPS
    final stopwatch = Stopwatch()..start();
    int nextFrameTargetMs = targetIntervalMs;
    
    // Local frame counter to avoid race conditions with widget state
    int localFrameCount = 0;

    while (isCapturing) {
      try {
        final frameStart = stopwatch.elapsedMilliseconds;

        final screenshotStart = DateTime.now();
        final screenshotData = await PlatformScreenCaptureService.captureFrame();
        final captureMs = DateTime.now().difference(screenshotStart).inMilliseconds;

        if (screenshotData != null) {
          final sendStart = DateTime.now();
          
          // captureFrame() already returns folded 90×50 (13500 bytes)
          // via _processFrame — no additional folding needed.
          final sentPrimary = await DDPSender.sendFrameStatic(
            fppIp,
            screenshotData,
            port: fppPort,
          );
          if (fallbackPort != null) {
            await DDPSender.sendFrameStatic(
              fppIp,
              screenshotData,
              port: fallbackPort,
            );
          }
          final sendMs = DateTime.now().difference(sendStart).inMilliseconds;

          if (!sentPrimary) {
            debugPrint("[MIRRORING] Failed to send frame $localFrameCount");
            break;
          }

          localFrameCount++;
          captureMsAcc += captureMs;
          sendMsAcc += sendMs;

          final waitMs = nextFrameTargetMs - stopwatch.elapsedMilliseconds;
          if (waitMs > 0) {
            await Future.delayed(Duration(milliseconds: waitMs));
          }

          nextFrameTargetMs += targetIntervalMs;
          if (stopwatch.elapsedMilliseconds > nextFrameTargetMs) {
            nextFrameTargetMs = stopwatch.elapsedMilliseconds + targetIntervalMs;
          }

          final totalMs = stopwatch.elapsedMilliseconds - frameStart;
          totalMsAcc += totalMs;

          // Update UI less frequently (every 20 frames) to avoid throttling when app is backgrounded
          if (localFrameCount % 20 == 0) {
            final avgFps = 20000 / totalMsAcc;
            final avgCaptureMs = (captureMsAcc / 20).toStringAsFixed(1);
            final avgSendMs = (sendMsAcc / 20).toStringAsFixed(1);
            totalMsAcc = 0;
            captureMsAcc = 0;
            sendMsAcc = 0;

            // Only update widget state if still mounted (app hasn't been disposed)
            if (mounted) {
              setState(() {
                frameCount = localFrameCount;
                currentFps = avgFps;
                statusMessage = "📺 ${avgFps.toStringAsFixed(1)} FPS | Capture: ${avgCaptureMs}ms | Send: ${avgSendMs}ms";
              });
            }
          }
        } else {
          if (mounted) {
            setState(() {
              statusMessage = "⚠️ No frame data - check FFmpeg";
            });
          }
          break;
        }
      } catch (e) {
        debugPrint("[MIRRORING] Error: $e");
        if (mounted) {
          setState(() {
            statusMessage = "❌ Error: $e";
          });
        }
        break;
      }
    }
    
    // Final sync of frame count when loop exits
    if (mounted) {
      setState(() {
        frameCount = localFrameCount;
      });
    }
  }

  Future<void> _toggleCapture() async {
    try {
      setState(() {
        isInitializing = true;
      });

      if (isCapturing) {
        final success = await PlatformScreenCaptureService.stopCapture();
        DDPSender.disposeStatic();
        setState(() {
          isCapturing = false;
          isInitializing = false;
          statusMessage = success
              ? "✅ Stopped ($frameCount frames sent)"
              : "⚠️ Stop may have failed";
        });
      } else {
        final success = await PlatformScreenCaptureService.startCapture();
        setState(() {
          isInitializing = false;
        });

        if (success) {
          setState(() {
            isCapturing = true;
            statusMessage = "✅ Capture started";
          });
          _startMirroringLoop();
        } else {
          setState(() {
            statusMessage = capabilities.requiresPermission
                ? "❌ Permission denied or capture failed"
                : "❌ Failed to initialize - check FFmpeg";
          });
        }
      }
    } catch (e) {
      setState(() {
        isInitializing = false;
        statusMessage = "❌ Error: $e";
      });
    }
  }

  Future<void> _sendTestFrame() async {
    final fppIp = ref.read(fppIpProvider);
    final fppPort = ref.read(fppDdpPortProvider);

    setState(() {
      statusMessage = "🧪 Testing capture + connection...";
    });

    logger.info('=== Starting Test Connection ===', module: 'TEST');
    logger.info('Target: $fppIp:$fppPort', module: 'TEST');

    try {
      // Test 1: Check if we can capture at all
      logger.info('Step 1: Starting screen capture...', module: 'TEST');
      final captureSuccess = await PlatformScreenCaptureService.startCapture();
      if (!captureSuccess) {
        logger.error('Screen capture failed to start!', module: 'TEST');
        setState(() {
          statusMessage = "❌ Screen capture failed to start";
        });
        return;
      }
      logger.success('Screen capture started', module: 'TEST');

      // Test 2: Capture a real frame
      logger.info('Step 2: Capturing test frame...', module: 'TEST');
      final testCapture = await PlatformScreenCaptureService.captureFrame();
      if (testCapture == null) {
        logger.error('Screen capture returned no frame!', module: 'TEST');
        setState(() {
          statusMessage = "❌ Screen capture returned no frame";
        });
        await PlatformScreenCaptureService.stopCapture();
        return;
      }

      logger.success('Captured frame: ${testCapture.length} bytes', module: 'TEST');
      await PlatformScreenCaptureService.stopCapture();

      // Test 3: Send a red test frame to FPP
      logger.info('Step 3: Sending RED test frame to FPP...', module: 'TEST');
      final testFrame = Uint8List(13500);
      for (int i = 0; i < 13500; i += 3) {
        testFrame[i] = 255; // R
        testFrame[i + 1] = 0; // G
        testFrame[i + 2] = 0; // B
      }

      DDPSender.setDebugLevel(2);
      final sent = await DDPSender.sendFrameStatic(fppIp, testFrame, port: fppPort);

      if (sent) {
        logger.success('Test frame sent! FPP should show RED', module: 'TEST');
      } else {
        logger.error('Failed to send test frame', module: 'TEST');
      }

      setState(() {
        statusMessage = sent
            ? "✅ Test RED frame sent to $fppIp:$fppPort"
            : "❌ Failed to send test frame";
      });
    } catch (e) {
      logger.error('Test failed: $e', module: 'TEST');
      setState(() {
        statusMessage = "❌ Test failed: $e";
      });
    }
  }

  Future<void> _loadAvailableWindows() async {
    setState(() {
      isLoadingWindows = true;
      statusMessage = "🔍 Scanning for windows...";
    });

    final windows = await PlatformScreenCaptureService.getAvailableWindows();

    setState(() {
      availableWindows = windows;
      isLoadingWindows = false;
      statusMessage = windows.isEmpty
          ? "⚠️ No capturable windows found"
          : "✅ Found ${windows.length} windows";
    });
  }

  Future<void> _openRegionSelector() async {
    final captureRegion = ref.read(captureRegionProvider);

    final result = await Navigator.of(context).push<Map<String, int>?>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black.withOpacity(0.35),
        pageBuilder: (_, __, ___) {
          return RegionSelectorOverlay(
            initialX: captureRegion['x'] ?? 0,
            initialY: captureRegion['y'] ?? 0,
            initialWidth: captureRegion['width'] ?? 800,
            initialHeight: captureRegion['height'] ?? 600,
            onRegionChanged: (x, y, width, height) {
              ref.read(captureRegionProvider.notifier).state = {
                'x': x,
                'y': y,
                'width': width,
                'height': height,
              };
              PlatformScreenCaptureService.setCaptureMode(
                CaptureMode.region,
                x: x,
                y: y,
                width: width,
                height: height,
              );
            },
          );
        },
      ),
    );

    if (result != null) {
      ref.read(captureRegionProvider.notifier).state = result;
      setState(() {
        statusMessage = "📐 Region: ${result['width']}x${result['height']}";
      });
    }
  }

  void _showPlatformInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(_getPlatformIcon(), size: 28),
            const SizedBox(width: 12),
            Text(capabilities.platformName),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoSection('Capture Method', capabilities.captureMethod),
              const SizedBox(height: 16),
              _buildInfoSection('Features', null, children: [
                _buildCapabilityRow('Desktop Capture', capabilities.supportsDesktopCapture),
                _buildCapabilityRow('Window Capture', capabilities.supportsWindowCapture),
                _buildCapabilityRow('Region Capture', capabilities.supportsRegionCapture),
              ]),
              const SizedBox(height: 16),
              _buildInfoSection('Requirements', null, children: [
                _buildRequirementRow('Permission Required', capabilities.requiresPermission),
              ]),
              if (capabilities.limitations.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildInfoSection('Limitations', null, children: [
                  for (final limit in capabilities.limitations)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('• ', style: TextStyle(color: Colors.orange)),
                          Expanded(child: Text(limit, style: const TextStyle(fontSize: 13))),
                        ],
                      ),
                    ),
                ]),
              ],
              if (capabilities.setupInstructions.isNotEmpty) ...[
                const SizedBox(height: 16),
                _buildInfoSection('Setup Instructions', null, children: [
                  for (int i = 0; i < capabilities.setupInstructions.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${i + 1}. ', style: const TextStyle(color: Colors.blue)),
                          Expanded(child: Text(capabilities.setupInstructions[i], style: const TextStyle(fontSize: 13))),
                        ],
                      ),
                    ),
                ]),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(String title, String? value, {List<Widget>? children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 4),
        if (value != null)
          Text(value, style: TextStyle(color: Colors.grey[400])),
        if (children != null) ...children,
      ],
    );
  }

  Widget _buildCapabilityRow(String name, bool supported) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            supported ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: supported ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 8),
          Text(name, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildRequirementRow(String name, bool required) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            required ? Icons.warning : Icons.check_circle,
            size: 16,
            color: required ? Colors.orange : Colors.green,
          ),
          const SizedBox(width: 8),
          Text(
            required ? name : 'No permission needed',
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  IconData _getPlatformIcon() {
    if (Platform.isAndroid) return Icons.android;
    if (Platform.isIOS) return Icons.apple;
    if (Platform.isWindows) return Icons.window;
    if (Platform.isLinux) return Icons.computer;
    if (Platform.isMacOS) return Icons.laptop_mac;
    return Icons.devices;
  }

  Color _getStatusColor() {
    if (isCapturing) return Colors.green;
    if (statusMessage.contains('❌')) return Colors.red;
    if (statusMessage.contains('⚠️')) return Colors.orange;
    return Colors.blue;
  }

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);
    final fppPort = ref.watch(fppDdpPortProvider);
    final captureMode = ref.watch(captureModeProvider);
    final selectedWindow = ref.watch(selectedWindowProvider);
    final captureRegion = ref.watch(captureRegionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen Mirroring'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Platform Info',
            onPressed: _showPlatformInfo,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            children: [
              // Scrollable content area
              Expanded(
                flex: _logsExpanded ? 2 : 4,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Status Card
                      _buildStatusCard(),
                      const SizedBox(height: 20),

                      // Platform Badge
                      _buildPlatformBadge(),
                      const SizedBox(height: 20),

                      // Capture Mode Selection (only show supported modes)
                      if (capabilities.supportsDesktopCapture)
                        _buildCaptureModeCard(captureMode, selectedWindow, captureRegion),
                      const SizedBox(height: 24),

                      // Main Action Buttons
                      _buildActionButtons(),
                      const SizedBox(height: 16),

                      // Connection Info
                      _buildConnectionInfo(fppIp, fppPort),
                    ],
                  ),
                ),
              ),
              // Log Viewer Panel
              Expanded(
                flex: _logsExpanded ? 2 : 1,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: LogViewer(
                    expanded: _logsExpanded,
                    onToggle: () {
                      setState(() {
                        _logsExpanded = !_logsExpanded;
                      });
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isCapturing
              ? [Colors.green.withOpacity(0.2), Colors.green.withOpacity(0.1)]
              : [Colors.grey.withOpacity(0.2), Colors.grey.withOpacity(0.1)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCapturing ? Colors.green.withOpacity(0.5) : Colors.grey.withOpacity(0.3),
          width: 2,
        ),
      ),
      child: Column(
        children: [
          // Animated Status Icon
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCapturing ? Colors.green.withOpacity(0.2) : Colors.grey.withOpacity(0.2),
              border: Border.all(
                color: isCapturing ? Colors.green : Colors.grey,
                width: 3,
              ),
            ),
            child: Center(
              child: isInitializing
                  ? const CircularProgressIndicator()
                  : Icon(
                      isCapturing ? Icons.cast_connected : Icons.cast,
                      size: 50,
                      color: isCapturing ? Colors.green : Colors.grey,
                    ),
            ),
          ),
          const SizedBox(height: 16),

          // Status Text
          Text(
            isCapturing ? 'STREAMING' : 'IDLE',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: isCapturing ? Colors.green : Colors.grey,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),

          // FPS Counter (when active)
          if (isCapturing && currentFps > 0)
            Text(
              '${currentFps.toStringAsFixed(1)} FPS • $frameCount frames',
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
            ),

          const SizedBox(height: 12),

          // Status Message
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _getStatusColor(),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(_getPlatformIcon(), color: Colors.blue, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  capabilities.platformName,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  capabilities.captureMethod,
                  style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                ),
              ],
            ),
          ),
          if (!PlatformScreenCaptureService.isPlatformSupported())
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Not Supported',
                style: TextStyle(color: Colors.red, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCaptureModeCard(CaptureMode captureMode, String? selectedWindow, Map<String, int> captureRegion) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.settings_input_component, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Capture Mode',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Desktop Mode
          _buildModeOption(
            icon: Icons.desktop_windows,
            title: 'Full Desktop',
            subtitle: 'Capture your entire screen',
            value: CaptureMode.desktop,
            groupValue: captureMode,
            enabled: capabilities.supportsDesktopCapture && !isCapturing,
          ),

          // Window Mode
          if (capabilities.supportsWindowCapture) ...[
            const SizedBox(height: 8),
            _buildModeOption(
              icon: Icons.web_asset,
              title: 'Application Window',
              subtitle: selectedWindow ?? 'Select a window to capture',
              value: CaptureMode.appWindow,
              groupValue: captureMode,
              enabled: !isCapturing,
              trailing: captureMode == CaptureMode.appWindow && !isCapturing
                  ? _buildWindowSelector()
                  : null,
            ),
          ],

          // Region Mode
          if (capabilities.supportsRegionCapture) ...[
            const SizedBox(height: 8),
            _buildModeOption(
              icon: Icons.crop,
              title: 'Screen Region',
              subtitle: '${captureRegion['width']}×${captureRegion['height']} at (${captureRegion['x']}, ${captureRegion['y']})',
              value: CaptureMode.region,
              groupValue: captureMode,
              enabled: !isCapturing,
              trailing: captureMode == CaptureMode.region && !isCapturing
                  ? TextButton.icon(
                      onPressed: _openRegionSelector,
                      icon: const Icon(Icons.edit, size: 16),
                      label: const Text('Configure'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.orange,
                      ),
                    )
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required CaptureMode value,
    required CaptureMode groupValue,
    required bool enabled,
    Widget? trailing,
  }) {
    final isSelected = value == groupValue;

    return InkWell(
      onTap: enabled
          ? () {
              ref.read(captureModeProvider.notifier).state = value;
              PlatformScreenCaptureService.setCaptureMode(value);
              if (value == CaptureMode.appWindow) {
                _loadAvailableWindows();
              }
            }
          : null,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Colors.blue.withOpacity(0.5) : Colors.transparent,
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(icon, size: 24, color: isSelected ? Colors.blue : Colors.grey),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: enabled ? Colors.white : Colors.grey,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: enabled ? Colors.grey[400] : Colors.grey[600],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Radio<CaptureMode>(
                  value: value,
                  groupValue: groupValue,
                  onChanged: enabled ? (v) {
                    ref.read(captureModeProvider.notifier).state = v!;
                    PlatformScreenCaptureService.setCaptureMode(v);
                  } : null,
                ),
              ],
            ),
            if (trailing != null) ...[
              const SizedBox(height: 8),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWindowSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: isLoadingWindows ? null : _loadAvailableWindows,
          icon: isLoadingWindows
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 18),
          label: Text(isLoadingWindows ? 'Scanning...' : 'Refresh Window List'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.blue,
          ),
        ),
        if (availableWindows.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 150),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: availableWindows.length,
              itemBuilder: (context, index) {
                final window = availableWindows[index];
                final isSelected = window == ref.watch(selectedWindowProvider);
                return ListTile(
                  dense: true,
                  selected: isSelected,
                  selectedTileColor: Colors.blue.withOpacity(0.2),
                  leading: const Icon(Icons.window, size: 18),
                  title: Text(
                    window,
                    style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    ref.read(selectedWindowProvider.notifier).state = window;
                    PlatformScreenCaptureService.setCaptureMode(
                      CaptureMode.appWindow,
                      windowTitle: window,
                    );
                    setState(() {
                      statusMessage = "✅ Selected: $window";
                    });
                  },
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildActionButtons() {
    final isSupported = PlatformScreenCaptureService.isPlatformSupported();

    return Column(
      children: [
        // Main Start/Stop Button
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: isSupported && !isInitializing ? _toggleCapture : null,
            icon: isInitializing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(isCapturing ? Icons.stop : Icons.play_arrow, size: 28),
            label: Text(
              isCapturing ? 'Stop Mirroring' : 'Start Mirroring',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: isCapturing ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Secondary Actions Row
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isCapturing ? null : _sendTestFrame,
                icon: const Icon(Icons.bug_report, size: 20),
                label: const Text('Test Connection'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange,
                  side: const BorderSide(color: Colors.orange),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  final fppIp = ref.read(fppIpProvider);
                  final fppPort = ref.read(fppDdpPortProvider);
                  showDialog(
                    context: context,
                    builder: (context) => NetworkTestDialog(
                      targetIp: fppIp,
                      targetPort: fppPort,
                    ),
                  );
                },
                icon: const Icon(Icons.network_check, size: 20),
                label: const Text('Network Test'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.purple,
                  side: const BorderSide(color: Colors.purple),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showPlatformInfo,
                icon: const Icon(Icons.help_outline, size: 20),
                label: const Text('Setup Help'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue,
                  side: const BorderSide(color: Colors.blue),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConnectionInfo(String fppIp, int fppPort) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.router, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Text(
                'FPP: $fppIp:$fppPort',
                style: TextStyle(color: Colors.grey[400], fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Output: ${PlatformScreenCaptureService.targetWidth}×${PlatformScreenCaptureService.targetHeight} @ 20 FPS',
            style: TextStyle(color: Colors.grey[500], fontSize: 12),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:typed_data';
import '../services/screen_capture.dart';
import '../services/ddp_sender.dart';
import '../providers/app_state.dart';
import '../widgets/region_selector_overlay.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';

class MirroringPage extends ConsumerStatefulWidget {
  const MirroringPage({super.key});

  @override
  ConsumerState<MirroringPage> createState() => _MirroringPageState();
}

class _MirroringPageState extends ConsumerState<MirroringPage> {
  bool isCapturing = false;
  String statusMessage = "Ready to capture screen";
  int frameCount = 0;
  List<String> availableWindows = [];
  bool isLoadingWindows = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _checkCaptureStatus();
    } else {
      setState(() {
        statusMessage = "Click Start to begin desktop screen mirroring";
      });
    }
  }

  Future<void> _checkCaptureStatus() async {
    final capturing = await ScreenCaptureService.isCapturing();
    setState(() {
      isCapturing = capturing;
    });
  }

  Future<void> _startDesktopCapture() async {
    // Apply capture mode configuration before starting
    final captureMode = ref.read(captureModeProvider);
    final selectedWindow = ref.read(selectedWindowProvider);
    final captureRegion = ref.read(captureRegionProvider);

    // Configure the capture mode
    switch (captureMode) {
      case CaptureMode.desktop:
        ScreenCaptureService.setCaptureMode(CaptureMode.desktop);
        break;
      case CaptureMode.appWindow:
        if (selectedWindow == null) {
          setState(() {
            statusMessage = "Please select a window first";
          });
          return;
        }
        ScreenCaptureService.setCaptureMode(
          CaptureMode.appWindow,
          windowTitle: selectedWindow,
        );
        break;
      case CaptureMode.region:
        ScreenCaptureService.setCaptureMode(
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

    setState(() {
      isCapturing = true;
      statusMessage = "Initializing capture...";
      frameCount = 0;
    });

    debugPrint(
      "[MIRRORING] Starting capture: $fppIp:$fppPort",
    );
    DDPSender.setDebugLevel(0); // Disable verbose logging for speed

    // Capture at ~20 FPS (50ms per frame)
    while (isCapturing) {
      try {
        final captureStart = DateTime.now();
        final screenshotData = await ScreenCaptureService.captureScreenshot();
        final captureDuration = DateTime.now().difference(captureStart);

        if (screenshotData != null) {
          // Send to FPP via DDP
          final sent = await DDPSender.sendFrameStatic(
            fppIp,
            screenshotData,
            port: fppPort,
          );
          final sendDuration = DateTime.now().difference(captureStart);

          if (!sent) {
            debugPrint("[MIRRORING] ERROR: Failed to send frame $frameCount");
            break;
          }

          setState(() {
            frameCount++;
            if (frameCount % 20 == 0) {
              final fps = (1000 / sendDuration.inMilliseconds).toStringAsFixed(1);
              statusMessage = "Streaming @ $fps FPS ($frameCount frames)";
              debugPrint("[MIRRORING] $frameCount frames @ $fps FPS (${sendDuration.inMilliseconds}ms/frame)");
            }
          });
        } else {
          debugPrint("[MIRRORING] ERROR: Capture returned null");
          setState(() {
            statusMessage = "Capture failed - check FFmpeg";
          });
          break;
        }
      } catch (e) {
        debugPrint("[MIRRORING] Error: $e");
        setState(() {
          statusMessage = "Capture error: $e";
        });
        break;
      }
    }
  }

  Future<void> _toggleCapture() async {
    try {
      if (isCapturing) {
        final success = await ScreenCaptureService.stopCapture();
        if (success) {
          setState(() {
            isCapturing = false;
            statusMessage = "Screen capture stopped ($frameCount frames sent)";
          });
        } else {
          setState(() {
            statusMessage = "Failed to stop capture";
          });
        }
      } else {
        if (Platform.isAndroid) {
          // Android native capture
          final success = await ScreenCaptureService.startCapture();
          if (success) {
            setState(() {
              isCapturing = true;
              statusMessage = "Screen capture started (20 FPS)";
            });
          } else {
            setState(() {
              statusMessage = "Failed to start capture - check permissions";
            });
          }
        } else if (Platform.isLinux || Platform.isWindows) {
          // Desktop capture
          final success = await ScreenCaptureService.startCapture();
          if (success) {
            _startDesktopCapture();
          } else {
            setState(() {
              statusMessage = "Failed to initialize capture";
            });
          }
        }
      }
    } catch (e) {
      setState(() {
        statusMessage = "Error: $e";
      });
    }
  }

  /// Send a solid red test frame to verify DDP connectivity
  Future<void> _sendTestFrame() async {
    final fppIp = ref.read(fppIpProvider);
    final fppPort = ref.read(fppDdpPortProvider);
    setState(() {
      statusMessage = "Sending test frame (red)...";
    });

    // Create a pure red frame: all pixels R=255, G=0, B=0
    final testFrame = Uint8List(13500);
    for (int i = 0; i < 13500; i += 3) {
      testFrame[i] = 255; // R
      testFrame[i + 1] = 0; // G
      testFrame[i + 2] = 0; // B
    }

    DDPSender.setDebug(true);
    final sent = await DDPSender.sendFrameStatic(
      fppIp,
      testFrame,
      port: fppPort,
    );

    setState(() {
      if (sent) {
        statusMessage = "✓ Test frame sent! Check FPP for red color";
      } else {
        statusMessage = "✗ Failed to send test frame";
      }
    });

    debugPrint("[TEST] Red frame sent to $fppIp");
  }

  Future<void> _loadAvailableWindows() async {
    setState(() {
      isLoadingWindows = true;
      statusMessage = "Loading windows...";
    });

    final windows = await ScreenCaptureService.enumerateWindows();

    setState(() {
      availableWindows = windows;
      isLoadingWindows = false;
      statusMessage = windows.isEmpty
          ? "No windows found"
          : "Found ${windows.length} windows";
    });
  }

  Future<void> _openRegionSelector() async {
    final captureRegion = ref.read(captureRegionProvider);

    setState(() {
      statusMessage = "Opening region selector...";
    });

    // Full-screen draggable overlay (no manual typing)
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
              // Live update while dragging/resizing
              ref.read(captureRegionProvider.notifier).state = {
                'x': x,
                'y': y,
                'width': width,
                'height': height,
              };
              ScreenCaptureService.setCaptureMode(
                CaptureMode.region,
                x: x,
                y: y,
                width: width,
                height: height,
              );
              setState(() {
                statusMessage = "Region: ${width}x${height} at ($x,$y)";
              });
            },
          );
        },
      ),
    );

    // Persist the final region after overlay closes
    if (result != null) {
      ref.read(captureRegionProvider.notifier).state = result;
      ScreenCaptureService.setCaptureMode(
        CaptureMode.region,
        x: result['x'],
        y: result['y'],
        width: result['width'],
        height: result['height'],
      );
      setState(() {
        statusMessage =
            "Region set: ${result['width']}x${result['height']} at (${result['x']},${result['y']})";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);
    final fppPort = ref.watch(fppDdpPortProvider);
    final captureMode = ref.watch(captureModeProvider);
    final selectedWindow = ref.watch(selectedWindowProvider);
    final captureRegion = ref.watch(captureRegionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Screen Mirroring'), centerTitle: true),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 200,
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isCapturing ? Colors.green : Colors.grey,
                          width: 3,
                        ),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isCapturing ? Icons.videocam : Icons.videocam_off,
                              size: 80,
                              color: isCapturing ? Colors.green : Colors.grey,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              isCapturing ? 'CAPTURING' : 'IDLE',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isCapturing ? Colors.green : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Status',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          statusMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'FPP: $fppIp:$fppPort',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Platform: ${Platform.operatingSystem}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Capture Mode',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        RadioListTile<CaptureMode>(
                          title: const Text('Full Desktop'),
                          subtitle: const Text('Capture entire screen'),
                          value: CaptureMode.desktop,
                          groupValue: captureMode,
                          onChanged: isCapturing
                              ? null
                              : (value) {
                                  ref.read(captureModeProvider.notifier).state =
                                      value!;
                                  ScreenCaptureService.setCaptureMode(value);
                                },
                        ),
                        RadioListTile<CaptureMode>(
                          title: const Text('App Window'),
                          subtitle: selectedWindow == null
                              ? const Text('Select a window to capture')
                              : Text(
                                  'Capturing: $selectedWindow',
                                  style: const TextStyle(color: Colors.green),
                                ),
                          value: CaptureMode.appWindow,
                          groupValue: captureMode,
                          onChanged: isCapturing
                              ? null
                              : (value) {
                                  ref.read(captureModeProvider.notifier).state =
                                      value!;
                                  _loadAvailableWindows();
                                },
                        ),
                        if (captureMode == CaptureMode.appWindow &&
                            !isCapturing)
                          Padding(
                            padding: const EdgeInsets.only(left: 32, top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: isLoadingWindows
                                      ? null
                                      : _loadAvailableWindows,
                                  icon: Icon(
                                    isLoadingWindows
                                        ? Icons.refresh
                                        : Icons.window,
                                  ),
                                  label: Text(
                                    isLoadingWindows
                                        ? 'Loading...'
                                        : 'Refresh Windows',
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                  ),
                                ),
                                if (availableWindows.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    constraints: const BoxConstraints(
                                      maxHeight: 150,
                                    ),
                                    child: ListView.builder(
                                      shrinkWrap: true,
                                      itemCount: availableWindows.length,
                                      itemBuilder: (context, index) {
                                        final window = availableWindows[index];
                                        return ListTile(
                                          dense: true,
                                          title: Text(
                                            window,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          selected: window == selectedWindow,
                                          selectedTileColor: Colors.blue
                                              .withOpacity(0.2),
                                          onTap: () {
                                            ref
                                                    .read(
                                                      selectedWindowProvider
                                                          .notifier,
                                                    )
                                                    .state =
                                                window;
                                            ScreenCaptureService.setCaptureMode(
                                              CaptureMode.appWindow,
                                              windowTitle: window,
                                            );
                                            setState(() {
                                              statusMessage =
                                                  "Window selected: $window";
                                            });
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        RadioListTile<CaptureMode>(
                          title: const Text('Region'),
                          subtitle: Text(
                            'Capture area: ${captureRegion['width']}x${captureRegion['height']} at (${captureRegion['x']},${captureRegion['y']})',
                            style: const TextStyle(fontSize: 11),
                          ),
                          value: CaptureMode.region,
                          groupValue: captureMode,
                          onChanged: isCapturing
                              ? null
                              : (value) {
                                  ref.read(captureModeProvider.notifier).state =
                                      value!;
                                  ScreenCaptureService.setCaptureMode(
                                    value,
                                    x: captureRegion['x'],
                                    y: captureRegion['y'],
                                    width: captureRegion['width'],
                                    height: captureRegion['height'],
                                  );
                                },
                        ),
                        if (captureMode == CaptureMode.region && !isCapturing)
                          Padding(
                            padding: const EdgeInsets.only(left: 32, top: 8),
                            child: ElevatedButton.icon(
                              onPressed: _openRegionSelector,
                              icon: const Icon(Icons.crop),
                              label: const Text('Configure Region'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  ElevatedButton(
                    onPressed: _toggleCapture,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isCapturing ? Colors.red : Colors.green,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 16,
                      ),
                    ),
                    child: Text(
                      isCapturing ? 'Stop Mirroring' : 'Start Mirroring',
                      style: const TextStyle(fontSize: 18, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _sendTestFrame,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 30,
                        vertical: 12,
                      ),
                    ),
                    child: const Text(
                      'Test: Send Red Frame',
                      style: TextStyle(fontSize: 14, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      'Captures screen at 90x50 resolution (20 FPS) and sends to FPP via DDP',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

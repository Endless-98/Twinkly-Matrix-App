import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:typed_data';
import '../services/screen_capture.dart';
import '../services/ddp_sender.dart';
import '../providers/app_state.dart';
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
        ScreenCaptureService.setCaptureMode(CaptureMode.appWindow, windowTitle: selectedWindow);
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

    debugPrint("[MIRRORING] Starting desktop capture, target FPP: $fppIp:$fppPort");
    DDPSender.setDebugLevel(2); // Verbose per-chunk logging for diagnostics

    // Capture at ~20 FPS (50ms per frame)
    while (isCapturing) {
      try {
        final captureStart = DateTime.now();
        final screenshotData = await ScreenCaptureService.captureScreenshot();
        final captureDuration = DateTime.now().difference(captureStart);
        
        if (screenshotData != null) {
          if (screenshotData.length != 13500) {
            debugPrint("[MIRRORING] WARNING: Frame size ${screenshotData.length} != 13500");
          }
          
          debugPrint("[MIRRORING] Sending frame $frameCount (${screenshotData.length} bytes) to $fppIp:$fppPort");
          
          // Send to FPP via DDP
          final sendStart = DateTime.now();
          final sent = await DDPSender.sendFrameStatic(fppIp, screenshotData, port: fppPort);
          final sendDuration = DateTime.now().difference(sendStart);
          
          if (sent) {
            debugPrint("[MIRRORING] ✓ Frame $frameCount sent in ${sendDuration.inMilliseconds}ms (capture: ${captureDuration.inMilliseconds}ms)");
          } else {
            debugPrint("[MIRRORING] ✗ Failed to send frame $frameCount");
          }
          
          setState(() {
            frameCount++;
            if (frameCount % 5 == 0) {
              final fps = (1000 / (captureDuration.inMilliseconds + sendDuration.inMilliseconds)).toStringAsFixed(1);
              statusMessage = "Streaming... ($frameCount frames @ ~$fps FPS)";
            }
          });
        } else {
          debugPrint("[MIRRORING] Screenshot capture returned null");
          setState(() {
            statusMessage = "Failed to capture screenshot - check logs";
          });
          break;
        }
        
        // Wait ~50ms for ~20 FPS (adjust based on capture + send time)
        final totalTime = captureDuration.inMilliseconds;
        final remainingWait = (50 - totalTime).clamp(0, 50);
        if (remainingWait > 0) {
          await Future.delayed(Duration(milliseconds: remainingWait));
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
      testFrame[i] = 255;     // R
      testFrame[i + 1] = 0;   // G
      testFrame[i + 2] = 0;   // B
    }

    DDPSender.setDebug(true);
    final sent = await DDPSender.sendFrameStatic(fppIp, testFrame, port: fppPort);
    
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

    // Note: Region overlay would need desktop_multi_window package
    // For now, show a dialog with manual input
    await _showRegionDialog();
  }

  Future<void> _showRegionDialog() async {
    final captureRegion = ref.read(captureRegionProvider);
    final xController = TextEditingController(text: captureRegion['x'].toString());
    final yController = TextEditingController(text: captureRegion['y'].toString());
    final widthController = TextEditingController(text: captureRegion['width'].toString());
    final heightController = TextEditingController(text: captureRegion['height'].toString());

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set Capture Region'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: xController,
              decoration: const InputDecoration(labelText: 'X Position'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: yController,
              decoration: const InputDecoration(labelText: 'Y Position'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: widthController,
              decoration: const InputDecoration(labelText: 'Width'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: heightController,
              decoration: const InputDecoration(labelText: 'Height'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final region = {
                'x': int.tryParse(xController.text) ?? 0,
                'y': int.tryParse(yController.text) ?? 0,
                'width': int.tryParse(widthController.text) ?? 800,
                'height': int.tryParse(heightController.text) ?? 600,
              };
              ref.read(captureRegionProvider.notifier).state = region;
              Navigator.pop(context);
              setState(() {
                statusMessage = "Region set: ${region['width']}x${region['height']} at (${region['x']},${region['y']})";
              });
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
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
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 40),
            Container(
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
            const SizedBox(height: 60),
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
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Platform: ${Platform.operatingSystem}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            // Capture Mode Selection
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
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  
                  // Desktop mode
                  RadioListTile<CaptureMode>(
                    title: const Text('Full Desktop'),
                    subtitle: const Text('Capture entire screen'),
                    value: CaptureMode.desktop,
                    groupValue: captureMode,
                    onChanged: isCapturing ? null : (value) {
                      ref.read(captureModeProvider.notifier).state = value!;
                      ScreenCaptureService.setCaptureMode(value);
                    },
                  ),
                  
                  // App Window mode
                  RadioListTile<CaptureMode>(
                    title: const Text('App Window'),
                    subtitle: selectedWindow == null 
                        ? const Text('Select a window to capture')
                        : Text('Capturing: $selectedWindow', style: const TextStyle(color: Colors.green)),
                    value: CaptureMode.appWindow,
                    groupValue: captureMode,
                    onChanged: isCapturing ? null : (value) {
                      ref.read(captureModeProvider.notifier).state = value!;
                      _loadAvailableWindows();
                    },
                  ),
                  
                  // Show window selector if app window mode
                  if (captureMode == CaptureMode.appWindow && !isCapturing)
                    Padding(
                      padding: const EdgeInsets.only(left: 32, top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ElevatedButton.icon(
                            onPressed: isLoadingWindows ? null : _loadAvailableWindows,
                            icon: Icon(isLoadingWindows ? Icons.refresh : Icons.window),
                            label: Text(isLoadingWindows ? 'Loading...' : 'Refresh Windows'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                            ),
                          ),
                          if (availableWindows.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(
                              constraints: const BoxConstraints(maxHeight: 150),
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: availableWindows.length,
                                itemBuilder: (context, index) {
                                  final window = availableWindows[index];
                                  return ListTile(
                                    dense: true,
                                    title: Text(window, style: const TextStyle(fontSize: 12)),
                                    selected: window == selectedWindow,
                                    selectedTileColor: Colors.blue.withOpacity(0.2),
                                    onTap: () {
                                      ref.read(selectedWindowProvider.notifier).state = window;
                                      ScreenCaptureService.setCaptureMode(CaptureMode.appWindow, windowTitle: window);
                                      setState(() {
                                        statusMessage = "Window selected: $window";
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
                  
                  // Region mode
                  RadioListTile<CaptureMode>(
                    title: const Text('Region'),
                    subtitle: Text(
                      'Capture area: ${captureRegion['width']}x${captureRegion['height']} at (${captureRegion['x']},${captureRegion['y']})',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: CaptureMode.region,
                    groupValue: captureMode,
                    onChanged: isCapturing ? null : (value) {
                      ref.read(captureModeProvider.notifier).state = value!;
                      ScreenCaptureService.setCaptureMode(
                        value,
                        x: captureRegion['x'],
                        y: captureRegion['y'],
                        width: captureRegion['width'],
                        height: captureRegion['height'],
                      );
                    },
                  ),
                  
                  // Show region config button if region mode
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
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _toggleCapture,
              style: ElevatedButton.styleFrom(
                backgroundColor: isCapturing ? Colors.red : Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              ),
              child: Text(
                isCapturing ? 'Stop Mirroring' : 'Start Mirroring',
                style: const TextStyle(fontSize: 18, color: Colors.white),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _sendTestFrame,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
              ),
              child: const Text(
                'Test: Send Red Frame',
                style: TextStyle(fontSize: 14, color: Colors.white),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16.0),
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
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:typed_data';
import '../services/screen_capture.dart';
import '../services/ddp_sender.dart';
import '../providers/app_state.dart';

class MirroringPage extends ConsumerStatefulWidget {
  const MirroringPage({super.key});

  @override
  ConsumerState<MirroringPage> createState() => _MirroringPageState();
}

class _MirroringPageState extends ConsumerState<MirroringPage> {
  bool isCapturing = false;
  String statusMessage = "Ready to capture screen";
  int frameCount = 0;

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
    final fppIp = ref.read(fppIpProvider);
    
    setState(() {
      isCapturing = true;
      statusMessage = "Initializing capture...";
      frameCount = 0;
    });

    debugPrint("[MIRRORING] Starting desktop capture, target FPP: $fppIp:4048");
    DDPSender.setDebug(true); // Enable DDP packet debugging

    // Capture at ~20 FPS (50ms per frame)
    while (isCapturing) {
      try {
        final captureStart = DateTime.now();
        final screenshotData = await ScreenCaptureService.captureScreenshot();
        final captureDuration = DateTime.now().difference(captureStart);
        
        if (screenshotData != null) {
          if (screenshotData.length != 27000) {
            debugPrint("[MIRRORING] WARNING: Frame size ${screenshotData.length} != 27000");
          }
          
          debugPrint("[MIRRORING] Sending frame $frameCount (${screenshotData.length} bytes) to $fppIp");
          
          // Send to FPP via DDP
          final sendStart = DateTime.now();
          final sent = await DDPSender.sendFrameStatic(fppIp, screenshotData);
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
    setState(() {
      statusMessage = "Sending test frame (red)...";
    });

    // Create a pure red frame: all pixels R=255, G=0, B=0
    final testFrame = Uint8List(27000);
    for (int i = 0; i < 27000; i += 3) {
      testFrame[i] = 255;     // R
      testFrame[i + 1] = 0;   // G
      testFrame[i + 2] = 0;   // B
    }

    DDPSender.setDebug(true);
    final sent = await DDPSender.sendFrameStatic(fppIp, testFrame);
    
    setState(() {
      if (sent) {
        statusMessage = "✓ Test frame sent! Check FPP for red color";
      } else {
        statusMessage = "✗ Failed to send test frame";
      }
    });

    debugPrint("[TEST] Red frame sent to $fppIp");
  }

  @override
  Widget build(BuildContext context) {
    final fppIp = ref.watch(fppIpProvider);

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
                    'FPP: $fppIp:4048',
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
                'Captures screen at 90x100 resolution (20 FPS) and sends to FPP via DDP',
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

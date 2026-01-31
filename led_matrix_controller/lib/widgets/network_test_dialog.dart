import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter/services.dart';

class NetworkTestDialog extends StatefulWidget {
  final String targetIp;
  final int targetPort;

  const NetworkTestDialog({
    super.key,
    required this.targetIp,
    required this.targetPort,
  });

  @override
  State<NetworkTestDialog> createState() => _NetworkTestDialogState();
}

class _NetworkTestDialogState extends State<NetworkTestDialog> {
  String _results = 'Running network diagnostics...\n\n';
  bool _isRunning = true;

  @override
  void initState() {
    super.initState();
    _runTests();
  }

  Future<void> _runTests() async {
    await _testDnsResolution();
    await _testPing();
    await _testUdpSocket();
    setState(() {
      _isRunning = false;
    });
  }

  Future<void> _testDnsResolution() async {
    try {
      _addResult('1️⃣ DNS Resolution Test');
      final addresses = await InternetAddress.lookup(widget.targetIp);
      if (addresses.isNotEmpty) {
        _addResult('✅ Resolved ${widget.targetIp} to:');
        for (var addr in addresses) {
          _addResult('   ${addr.address}');
        }
      }
    } catch (e) {
      _addResult('❌ DNS lookup failed: $e');
    }
    _addResult('');
  }

  Future<void> _testPing() async {
    try {
      _addResult('2️⃣ Network Connectivity Test');
      if (Platform.isWindows) {
        final result = await Process.run('ping', ['-n', '1', '-w', '1000', widget.targetIp]);
        if (result.exitCode == 0) {
          _addResult('✅ Ping successful');
          _addResult(result.stdout.toString().split('\n').take(3).join('\n'));
        } else {
          _addResult('❌ Ping failed');
          _addResult(result.stderr.toString());
        }
      } else {
        _addResult('⚠️ Ping test skipped (Windows only)');
      }
    } catch (e) {
      _addResult('❌ Ping test error: $e');
    }
    _addResult('');
  }

  Future<void> _testUdpSocket() async {
    try {
      _addResult('3️⃣ UDP Socket Test');
      
      // Create socket
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _addResult('✅ Socket created on local port ${socket.port}');
      
      // Prepare test packet
      final testData = Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04]);
      final addr = InternetAddress(widget.targetIp);
      
      _addResult('📤 Attempting to send ${testData.length} bytes to ${widget.targetIp}:${widget.targetPort}');
      
      // Try to send
      final bytesSent = socket.send(testData, addr, widget.targetPort);
      
      if (bytesSent > 0) {
        _addResult('✅ Socket.send() returned $bytesSent bytes');
        _addResult('✅ UDP packet appears to be sent');
      } else {
        _addResult('❌ Socket.send() returned 0');
        _addResult('❌ This means Windows is blocking the UDP send!');
        _addResult('');
        _addResult('💡 Possible causes:');
        _addResult('   • Windows Firewall is blocking the app');
        _addResult('   • Network adapter is disabled');
        _addResult('   • Invalid target IP address');
      }
      
      socket.close();
      _addResult('');
      _addResult('🔥 Firewall Status:');
      if (Platform.isWindows) {
        final fwResult = await Process.run('netsh', ['advfirewall', 'show', 'currentprofile']);
        final lines = fwResult.stdout.toString().split('\n');
        for (var line in lines.take(10)) {
          if (line.trim().isNotEmpty) {
            _addResult('   $line');
          }
        }
      }
    } catch (e) {
      _addResult('❌ UDP socket test failed: $e');
    }
    _addResult('');
  }

  void _addResult(String text) {
    setState(() {
      _results += '$text\n';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Network Diagnostics'),
      content: SizedBox(
        width: 600,
        height: 500,
        child: SingleChildScrollView(
          child: SelectableText(
            _results,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      actions: [
        if (!_isRunning)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _results));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            child: const Text('Copy'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class DDPSender {
  late RawDatagramSocket _socket;
  final String _host;
  final int _port;
  static const int frameSize = 13500; // 90*50*3 RGB bytes
  static RawDatagramSocket? _staticSocket;
  static bool _debugPackets = false;
  static int _debugLevel = 1; // 1: per-frame summary, 2: chunk details
  static int _sequenceNumber = 0;
  // Keep UDP payloads below typical MTU to avoid fragmentation
  // DDP header is 10 bytes, keep data <= 1200 bytes for safety
  static const int _maxChunkData = 1200;
  static File? _logFile;

  /// Initialize log file
  static Future<void> _initLogFile() async {
    if (_logFile != null) return;
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${docDir.path}/TwinklyWall');
      if (!logDir.existsSync()) {
        logDir.createSync(recursive: true);
      }
      _logFile = File('${logDir.path}/ddp_debug.log');
      _log('=== DDP Log Started ===');
    } catch (e) {
      print('Failed to init log file: $e');
    }
  }

  /// Log helper that writes to file
  static void _log(String message) {
    final timestamp = DateTime.now().toIso8601String();
    final logMsg = '[$timestamp] $message';
    
    // Print to console if possible
    print(logMsg);
    
    // Write to file
    if (_logFile != null) {
      try {
        _logFile!.writeAsStringSync('$logMsg\n', mode: FileMode.append);
      } catch (e) {
        print('Failed to write to log: $e');
      }
    }
  }

  DDPSender({required String host, int port = 4048})
      : _host = host,
        _port = port;

  /// Initialize the socket connection
  Future<bool> initialize() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _log('[DDPSender] Initialized for $_host:$_port');
      return true;
    } catch (e) {
      _log('[DDPSender] Failed to initialize: $e');
      return false;
    }
  }

  /// Send a frame to the LED display
  /// Send a frame to the LED display (chunked DDP datagrams)
  void sendFrame(Uint8List rgbData) {
    if (rgbData.length != frameSize) {
      _log('Invalid frame size: ${rgbData.length}, expected $frameSize');
      return;
    }

    try {
      final addr = InternetAddress(_host);
      int sent = 0;
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast);
        _socket.send(packet, addr, _port);
        sent += dataLen;
      }
    } catch (e) {
      _log('Failed to send frame: $e');
    }
  }

  /// Static method to send a frame directly (for desktop screen mirroring)
  static Future<bool> sendFrameStatic(String host, Uint8List rgbData, {int port = 4048}) async {
    // Initialize log file on first call
    if (_logFile == null) {
      await _initLogFile();
    }
    
    if (rgbData.length != frameSize) {
      _log('[DDP] Invalid frame size: ${rgbData.length}, expected $frameSize');
      return false;
    }

    try {
      // Initialize socket if needed
      if (_staticSocket == null) {
        _staticSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _staticSocket!.broadcastEnabled = true; // Enable broadcast just in case
        _log('[DDP] Socket initialized on local port ${_staticSocket!.port}');
      }

      final addr = InternetAddress(host);
      
      int sent = 0;
      int packets = 0;
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast);
        
        // Fire-and-forget UDP, no retries (UDP is unreliable by design)
        final bytesSent = _staticSocket!.send(packet, addr, port);
        
        if (bytesSent == 0 && packets == 0) {
          // Only log on first packet failure
          _log('[DDP] ERROR: Socket send failed. Check firewall settings.');
          return false;
        }
        
        sent += dataLen;
        packets++;
      }

      return true;
    } catch (e) {
      _log('[DDP] Failed to send frame: $e');
      return false;
    }
  }

  // Deprecated: single-packet builder removed in favor of chunked sender

  /// Static packet builder
  /// Build a single DDP v1 packet for a chunk
  /// DDP v1 10-byte header layout (big-endian):
  /// 0: 0x41 ('A')
  /// 1: flags (bit6 set for v1 => 0x40). Set bit0 (0x01) on last chunk to 'push' frame
  /// 2: sequence (0-255, rolls over)
  /// 3-5: data offset (24-bit) in channels (bytes)
  /// 6-7: data length (16-bit)
  /// 8-9: data ID (0x0000 for default)
  static Uint8List _buildDdpPacketStaticChunk(Uint8List rgbData, int startByte, int dataLen, bool endOfFrame) {
    final packet = BytesBuilder();

    // Header
    packet.addByte(0x41); // 'A'
    final flags = 0x40 | (endOfFrame ? 0x01 : 0x00); // v1 + push on last chunk
    packet.addByte(flags);
    packet.addByte(_sequenceNumber & 0xFF); // 1-byte sequence

    // Data offset is in channels (bytes). Use 24-bit offset as per spec
    final offset = startByte & 0xFFFFFF;
    packet.addByte((offset >> 16) & 0xFF);
    packet.addByte((offset >> 8) & 0xFF);
    packet.addByte(offset & 0xFF);

    // Length (2 bytes)
    packet.addByte((dataLen >> 8) & 0xFF);
    packet.addByte(dataLen & 0xFF);

    // Data ID (2 bytes) - default channel space
    packet.addByte(0x00);
    packet.addByte(0x00);

    // Payload
    packet.add(Uint8List.sublistView(rgbData, startByte, startByte + dataLen));

    _sequenceNumber = (_sequenceNumber + 1) & 0xFF;
    return packet.toBytes();
  }

  /// Enable/disable packet debugging
  static void setDebug(bool enabled) {
    _debugPackets = enabled;
  }

  static void setDebugLevel(int level) {
    _debugLevel = level.clamp(0, 2);
    _debugPackets = _debugLevel > 0;
  }

  /// Clean up resources
  void dispose() {
    _socket.close();
  }

  /// Static cleanup
  static void disposeStatic() {
    _staticSocket?.close();
    _staticSocket = null;
  }
}

// Keep DdpSender as alias for backward compatibility
class DdpSender {
  late RawDatagramSocket _socket;
  final String _host;
  final int _port;
  static const int frameSize = 13500; // 90*50*3 RGB bytes

  DdpSender({required String host, int port = 4048})
      : _host = host,
        _port = port;

  /// Initialize the socket connection
  Future<bool> initialize() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      debugPrint('DdpSender initialized for $_host:$_port');
      return true;
    } catch (e) {
      debugPrint('Failed to initialize DdpSender: $e');
      return false;
    }
  }

  /// Send a frame to the LED display
  void sendFrame(Uint8List rgbData) {
    if (rgbData.length != frameSize) {
      debugPrint('Invalid frame size: ${rgbData.length}, expected $frameSize');
      return;
    }

    try {
      final addr = InternetAddress(_host);
      int sent = 0;
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > DDPSender._maxChunkData ? DDPSender._maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = DDPSender._buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast);
        _socket.send(packet, addr, _port);
        sent += dataLen;
      }
    } catch (e) {
      debugPrint('Failed to send frame: $e');
    }
  }

  /// Clean up resources
  void dispose() {
    _socket.close();
  }
}

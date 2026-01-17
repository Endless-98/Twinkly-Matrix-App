import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class DDPSender {
  late RawDatagramSocket _socket;
  final String _host;
  final int _port;
  static const int frameSize = 13500; // 90*50*3 RGB bytes
  static RawDatagramSocket? _staticSocket;
  static int _debugLevel = 1; // 1: per-frame summary, 2: chunk details
  // Frame sequence number (applied per frame across all chunks to allow reassembly)
  static int _frameSequence = 0;
  static final Stopwatch _secondStopwatch = Stopwatch()..start();
  static int _framesThisSecond = 0;
  // Keep UDP payloads below typical MTU to avoid fragmentation
  // DDP header is 10 bytes, keep data <= 1050 bytes for 1060 total packet size (safe for 1500-byte MTU with headroom)
  static const int _maxChunkData = 1050;
  // Optionally send whole frame in a single UDP datagram (fastest; relies on local LAN handling fragmentation)
  // Safer default: use chunked packets to avoid MTU-related drops; can re-enable if LAN path supports it
  static const bool _useSinglePacket = false;
  static File? _logFile;
  static int _framesSinceSocketRecreate = 0;
  static const int _socketRecreateInterval = 10000; // Recreate socket every 10000 frames to prevent buffer buildup (~8 min at 20fps)


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
  static void _log(String message, {int level = 1}) {
    if (_debugLevel < level) return; // Skip if debug level is lower than message level
    
    final timestamp = DateTime.now().toIso8601String();
    final logMsg = '[$timestamp] $message';
    
    // Print to console using debugPrint (respects production mode)
    debugPrint(logMsg);
    
    // Write to file
    if (_logFile != null) {
      try {
        _logFile!.writeAsStringSync('$logMsg\n', mode: FileMode.append);
      } catch (e) {
        debugPrint('Failed to write to log: $e');
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
      final frameSeq = DDPSender._frameSequence;
      int sent = 0;
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast, frameSeq);
        _socket.send(packet, addr, _port);
        sent += dataLen;
      }
      DDPSender._frameSequence = (DDPSender._frameSequence + 1) & 0xFF; // advance once per frame
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
      final frameSeq = DDPSender._frameSequence;

      // Fast-path: single UDP packet for the entire frame (13500B + 10B header)
      if (_useSinglePacket && rgbData.length <= 60000) {
        if (_staticSocket == null || _framesSinceSocketRecreate >= _socketRecreateInterval) {
          if (_staticSocket != null) {
            _staticSocket!.close();
            _log('[DDP] Socket recreated after $_framesSinceSocketRecreate frames');
          }
          _staticSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
          _staticSocket!.broadcastEnabled = true;
          _staticSocket!.writeEventsEnabled = false;
          _staticSocket!.readEventsEnabled = false;
          _framesSinceSocketRecreate = 0;
          _log('[DDP] Socket initialized on local port ${_staticSocket!.port}');
        }

        _framesSinceSocketRecreate++;
        final addr = InternetAddress(host);
        final packet = _buildDdpPacketStaticChunk(rgbData, 0, rgbData.length, true, frameSeq);
        final bytesSent = _staticSocket!.send(packet, addr, port);
        if (bytesSent == 0) {
          _log('[DDP] ERROR: Socket send failed. Check firewall settings.');
          return false;
        }

        _frameSequence = (_frameSequence + 1) & 0xFF; // advance once per frame
        _updateFpsMetrics();
        _lastSendMetrics();
        return true;
      }

      // Initialize socket if needed or recreate periodically to prevent buffer buildup
      if (_staticSocket == null || _framesSinceSocketRecreate >= _socketRecreateInterval) {
        if (_staticSocket != null) {
          _staticSocket!.close();
          _log('[DDP] Socket recreated after $_framesSinceSocketRecreate frames');
        }
        
        _staticSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _staticSocket!.broadcastEnabled = true;
        _staticSocket!.writeEventsEnabled = false;
        _staticSocket!.readEventsEnabled = false;  
        
        _framesSinceSocketRecreate = 0;
        _log('[DDP] Socket initialized on local port ${_staticSocket!.port}');
      }
      
      _framesSinceSocketRecreate++;

      final addr = InternetAddress(host);
      
      int sent = 0;
      int packets = 0;
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast, frameSeq);
        
        final bytesSent = _staticSocket!.send(packet, addr, port);
        
        if (bytesSent == 0 && packets == 0) {
          _log('[DDP] ERROR: Socket send failed. Check firewall settings.');
          return false;
        }
        
        sent += dataLen;
        packets++;
      }

      DDPSender._frameSequence = (DDPSender._frameSequence + 1) & 0xFF; // advance once per frame
      _updateFpsMetrics();
      _lastSendMetrics();
      return true;
    } catch (e) {
      _log('[DDP] Failed to send frame: $e');
      return false;
    }
  }

  // Helper: update FPS metrics using precomputed stopwatch
  static void _updateFpsMetrics() {
    _framesThisSecond++;
    if (_secondStopwatch.elapsedMilliseconds >= 1000) {
      final fps = (_framesThisSecond * 1000.0 / _secondStopwatch.elapsedMilliseconds).toStringAsFixed(1);
      _log('[DDP] Send rate last second: ${_framesThisSecond} frames (${fps} FPS)');
      _framesThisSecond = 0;
      _secondStopwatch.reset();
    }
  }

  // Helper: log last send (placeholder for symmetry)
  static void _lastSendMetrics() {
    // No-op; retained for compatibility
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
  static Uint8List _buildDdpPacketStaticChunk(Uint8List rgbData, int startByte, int dataLen, bool endOfFrame, int frameSeq) {
    final packet = BytesBuilder();

    // Header
    packet.addByte(0x41); // 'A'
    final flags = 0x40 | (endOfFrame ? 0x01 : 0x00); // v1 + push on last chunk
    packet.addByte(flags);
    packet.addByte(frameSeq & 0xFF); // 1-byte sequence (constant per frame)

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

    return packet.toBytes();
  }

  /// Enable/disable packet debugging
  static void setDebug(bool enabled) {
    _debugLevel = enabled ? 1 : 0;
  }

  static void setDebugLevel(int level) {
    _debugLevel = level.clamp(0, 2);
  }

  /// Clean up resources
  void dispose() {
    _socket.close();
  }

  /// Static cleanup
  static void disposeStatic() {
    _staticSocket?.close();
    _staticSocket = null;
    _framesSinceSocketRecreate = 0;
  }
}

/// Alias for backward compatibility
typedef DdpSender = DDPSender;

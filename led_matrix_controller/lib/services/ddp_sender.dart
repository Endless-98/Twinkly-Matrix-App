import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'app_logger.dart';

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
  static final Map<String, InternetAddress> _hostCache = {};
  static int _lastSendFailureMs = 0;
  static int _consecutiveSendZeros = 0;  // Track consecutive zero returns
  static const int _maxConsecutiveZerosBeforeRecreate = 100;  // Only recreate after many consecutive zeros


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
      logger.error('Failed to init log file: $e', module: 'DDP');
    }
  }

  /// Log helper that writes to file AND the visible logger
  static void _log(String message, {int level = 1}) {
    if (_debugLevel < level) return; // Skip if debug level is lower than message level
    
    // Log to visible UI logger
    logger.info(message, module: 'DDP');
    
    // Also write to file
    if (_logFile != null) {
      try {
        final timestamp = DateTime.now().toIso8601String();
        _logFile!.writeAsStringSync('[$timestamp] $message\n', mode: FileMode.append);
      } catch (e) {
        // Silently fail file writes
      }
    }
  }

  static Future<InternetAddress?> _resolveHost(String host) async {
    if (host.trim().isEmpty) {
      _log('[DDP] ERROR: Host is empty');
      return null;
    }

    final cached = _hostCache[host];
    if (cached != null) return cached;

    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      _hostCache[host] = parsed;
      return parsed;
    }

    try {
      final results = await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
      if (results.isNotEmpty) {
        _hostCache[host] = results.first;
        return results.first;
      }
    } catch (e) {
      _log('[DDP] ERROR: Failed to resolve host "$host": $e');
    }

    _log('[DDP] ERROR: Host "$host" could not be resolved');
    return null;
  }

  static void _logSendFailure(String host, int port, int packetSize, int? localPort, {int? chunkSize}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSendFailureMs < 1000) return; // prevent log spam
    _lastSendFailureMs = nowMs;

    final chunkInfo = chunkSize != null ? ', ChunkSize: $chunkSize' : '';
    _log('[DDP] ERROR: Socket send failed. Target: $host:$port, PacketSize: $packetSize$chunkInfo, LocalPort: $localPort');
    _log('[DDP] HINT: Verify target IP/port and Windows Firewall allows outbound UDP for this app');
  }

  static Future<bool> _recreateStaticSocket(String reason) async {
    try {
      if (_staticSocket != null) {
        _staticSocket!.close();
        _log('[DDP] Socket recreated ($reason)');
      }
      _staticSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _staticSocket!.broadcastEnabled = true;
      _staticSocket!.writeEventsEnabled = false;
      _staticSocket!.readEventsEnabled = false;
      _framesSinceSocketRecreate = 0;
      _log('[DDP] Socket initialized on local port ${_staticSocket!.port}');
      return true;
    } catch (e) {
      _log('[DDP] ERROR: Failed to recreate socket: $e');
      return false;
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

  // Track first frame for debugging
  static bool _firstFrameSent = false;
  
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
    
    // Check if frame has any content
    if (!_firstFrameSent) {
      int nonZero = 0;
      for (int i = 0; i < rgbData.length && nonZero < 10; i++) {
        if (rgbData[i] > 0) nonZero++;
      }
      debugPrint('[DDP] First frame analysis: size=${rgbData.length}, hasContent=${nonZero > 0}, sending to $host:$port');
    }

    try {
      final addr = await _resolveHost(host);
      if (addr == null) return false;

      final frameSeq = DDPSender._frameSequence;

      // Fast-path: single UDP packet for the entire frame (13500B + 10B header)
      if (_useSinglePacket && rgbData.length <= 60000) {
        if (_staticSocket == null || _framesSinceSocketRecreate >= _socketRecreateInterval) {
          final ok = await _recreateStaticSocket('interval');
          if (!ok) return false;
        }

        _framesSinceSocketRecreate++;
        final packet = _buildDdpPacketStaticChunk(rgbData, 0, rgbData.length, true, frameSeq);
        
        // Note: On Windows, send() may return 0 even when data is queued.
        // UDP doesn't confirm delivery - just send and continue.
        final bytesSent = _staticSocket!.send(packet, addr, port);
        if (bytesSent > 0) {
          _consecutiveSendZeros = 0;
        } else {
          _consecutiveSendZeros++;
          if (_consecutiveSendZeros >= _maxConsecutiveZerosBeforeRecreate) {
            _log('[DDP] Too many zero-byte sends, recreating socket');
            await _recreateStaticSocket('consecutive zeros');
            _consecutiveSendZeros = 0;
          }
        }
        
        if (!_firstFrameSent) {
          _log('[DDP] First frame sent! ${packet.length} bytes to $host:$port');
          _firstFrameSent = true;
        }

        _frameSequence = (_frameSequence + 1) & 0xFF; // advance once per frame
        _updateFpsMetrics();
        _lastSendMetrics();
        return true;
      }

      // Initialize socket if needed or recreate periodically to prevent buffer buildup
      if (_staticSocket == null || _framesSinceSocketRecreate >= _socketRecreateInterval) {
        final ok = await _recreateStaticSocket('interval');
        if (!ok) return false;
      }
      
      _framesSinceSocketRecreate++;
      
      int sent = 0;
      int packets = 0;
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast, frameSeq);
        
        // Send this chunk in a tight burst — no delays between chunks.
        // 13 packets × 1060 bytes = ~14KB fits easily in the 65KB default
        // Windows UDP send buffer.  NEVER use sleep() or await between
        // chunks: sleep() blocks the Win32 message pump (same thread on
        // Windows) causing hard crashes, and await depends on event-loop
        // speed which drops to 200ms/tick when throttled.
        int bytesSent = _staticSocket!.send(packet, addr, port);
        if (bytesSent == 0) {
          // Buffer full — single immediate retry (kernel already draining)
          bytesSent = _staticSocket!.send(packet, addr, port);
        }

        if (bytesSent > 0) {
          _consecutiveSendZeros = 0;
        } else {
          _consecutiveSendZeros++;
          if (_consecutiveSendZeros >= _maxConsecutiveZerosBeforeRecreate) {
            _log('[DDP] Too many zero-byte sends ($_consecutiveSendZeros), recreating socket');
            await _recreateStaticSocket('consecutive zeros');
            _consecutiveSendZeros = 0;
          }
        }
        
        sent += dataLen;
        packets++;
      }

      DDPSender._frameSequence = (DDPSender._frameSequence + 1) & 0xFF; // advance once per frame
      _updateFpsMetrics();
      _lastSendMetrics();
      
      if (!_firstFrameSent) {
        _firstFrameSent = true;
        debugPrint('[DDP] First frame sent! $packets packets, $sent bytes to $host:$port');
      }
      
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

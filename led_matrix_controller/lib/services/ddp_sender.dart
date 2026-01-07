import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

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

  DDPSender({required String host, int port = 4048})
      : _host = host,
        _port = port;

  /// Initialize the socket connection
  Future<bool> initialize() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      debugPrint('[DDPSender] Initialized for $_host:$_port');
      return true;
    } catch (e) {
      debugPrint('[DDPSender] Failed to initialize: $e');
      return false;
    }
  }

  /// Send a frame to the LED display
  /// Send a frame to the LED display (chunked DDP datagrams)
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
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast);
        _socket.send(packet, addr, _port);
        sent += dataLen;
      }
    } catch (e) {
      debugPrint('Failed to send frame: $e');
    }
  }

  /// Static method to send a frame directly (for desktop screen mirroring)
  static Future<bool> sendFrameStatic(String host, Uint8List rgbData) async {
    if (rgbData.length != frameSize) {
      debugPrint('[DDP] Invalid frame size: ${rgbData.length}, expected $frameSize');
      return false;
    }

    try {
      // Initialize socket if needed
      if (_staticSocket == null) {
        _staticSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        debugPrint('[DDP] Socket initialized on local port ${_staticSocket!.port}');
      }

      final addr = InternetAddress(host);
      int sent = 0;
      int packets = 0;
      int checksum = 0;
      for (int i = 0; i < rgbData.length; i++) {
        checksum = (checksum + rgbData[i]) & 0xFFFFFFFF;
      }
      if (_debugPackets) {
        final p0 = rgbData.length >= 3 ? '${rgbData[0]},${rgbData[1]},${rgbData[2]}' : 'n/a';
        debugPrint('[DDP] Frame bytes=${rgbData.length} checksum(sum32)=$checksum firstRGB=[$p0]');
      }
      while (sent < rgbData.length) {
        final remaining = rgbData.length - sent;
        final dataLen = remaining > _maxChunkData ? _maxChunkData : remaining;
        final isLast = sent + dataLen >= rgbData.length;
        final packet = _buildDdpPacketStaticChunk(rgbData, sent, dataLen, isLast);
        _staticSocket!.send(packet, addr, 4048);
        if (_debugPackets && _debugLevel >= 2) {
          final r = rgbData[sent];
          final g = rgbData[sent + 1];
          final b = rgbData[sent + 2];
          debugPrint('[DDP] Chunk off=$sent len=$dataLen rgb0=[$r,$g,$b] last=$isLast');
        }
        sent += dataLen;
        packets++;
      }

      if (_debugPackets) {
        debugPrint('[DDP] Sent ${rgbData.length} bytes in $packets packets to $host:4048');
      }

      return true;
    } catch (e) {
      debugPrint('[DDP] Failed to send frame: $e');
      return false;
    }
  }

  // Deprecated: single-packet builder removed in favor of chunked sender

  /// Static packet builder
  /// Build a single DDP packet for a chunk
  /// DDP 10-byte header:
  /// 0: 0x41 ('A'), 1: flags, 2-3: seq, 4-7: data offset (start channel, BE), 8-9: data length (BE)
  static Uint8List _buildDdpPacketStaticChunk(Uint8List rgbData, int startByte, int dataLen, bool endOfFrame) {
    final packet = BytesBuilder();

    // Header
    packet.addByte(0x41); // 'A'
    final flags = endOfFrame ? 0x01 : 0x00;
    packet.addByte(flags);
    packet.addByte((_sequenceNumber >> 8) & 0xFF);
    packet.addByte(_sequenceNumber & 0xFF);

    // Data offset is in channels (3 bytes per pixel). Our buffer is RGB bytes, so offset == startByte
    final offset = startByte; // channel offset in bytes
    packet.addByte((offset >> 24) & 0xFF);
    packet.addByte((offset >> 16) & 0xFF);
    packet.addByte((offset >> 8) & 0xFF);
    packet.addByte(offset & 0xFF);

    // Length (2 bytes)
    packet.addByte((dataLen >> 8) & 0xFF);
    packet.addByte(dataLen & 0xFF);

    // Payload
    packet.add(Uint8List.sublistView(rgbData, startByte, startByte + dataLen));

    if (_debugPackets && (_sequenceNumber % 30 == 0)) {
      final r = rgbData[startByte];
      final g = rgbData[startByte + 1];
      final b = rgbData[startByte + 2];
      debugPrint('[DDP] Seq ${_sequenceNumber}: off=$startByte len=$dataLen p0 R$r G$g B$b eof=$endOfFrame');
    }

    _sequenceNumber = (_sequenceNumber + 1) & 0xFFFF;
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

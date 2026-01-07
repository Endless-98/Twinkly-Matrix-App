import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as developer;

class DDPSender {
  late RawDatagramSocket _socket;
  final String _host;
  final int _port;
  static const int frameSize = 27000; // 90*100*3 RGB bytes
  static RawDatagramSocket? _staticSocket;
  static bool _debugPackets = false;
  static int _sequenceNumber = 0;

  DDPSender({required String host, int port = 4048})
      : _host = host,
        _port = port;

  /// Initialize the socket connection
  Future<bool> initialize() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      developer.log('DDPSender initialized for $_host:$_port');
      return true;
    } catch (e) {
      developer.log('Failed to initialize DDPSender: $e');
      return false;
    }
  }

  /// Send a frame to the LED display
  void sendFrame(Uint8List rgbData) {
    if (rgbData.length != frameSize) {
      developer.log('Invalid frame size: ${rgbData.length}, expected $frameSize');
      return;
    }

    try {
      final packet = _buildDdpPacket(rgbData);
      _socket.send(packet, InternetAddress(_host), _port);
    } catch (e) {
      developer.log('Failed to send frame: $e');
    }
  }

  /// Static method to send a frame directly (for desktop screen mirroring)
  static Future<bool> sendFrameStatic(String host, Uint8List rgbData) async {
    if (rgbData.length != frameSize) {
      developer.log('Invalid frame size: ${rgbData.length}, expected $frameSize');
      return false;
    }

    try {
      // Initialize socket if needed
      if (_staticSocket == null) {
        _staticSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }

      final packet = _buildDdpPacketStatic(rgbData);
      _staticSocket!.send(packet, InternetAddress(host), 4048);
      return true;
    } catch (e) {
      developer.log('Failed to send frame: $e');
      return false;
    }
  }

  /// Build a DDP protocol packet
  /// Format: 10-byte header + RGB data
  Uint8List _buildDdpPacket(Uint8List rgbData) {
    return _buildDdpPacketStatic(rgbData);
  }

  /// Static packet builder
  static Uint8List _buildDdpPacketStatic(Uint8List rgbData) {
    final packet = BytesBuilder();

    // DDP Header (10 bytes) - CORRECTED for FPP compatibility
    packet.addByte(0x41); // Protocol identifier (0x41 for DDP)
    packet.addByte(0x01); // Flags (0x01 for end-of-frame)
    packet.addByte((_sequenceNumber >> 8) & 0xFF); // Sequence number high
    packet.addByte(_sequenceNumber & 0xFF); // Sequence number low
    packet.addByte(0x00); // Data type (0x00 for RGB pixel data)
    packet.addByte(0x00); // Reserved
    packet.addByte(0x00); // Reserved

    // Data length (big-endian, 3 bytes for < 16MB)
    final dataLength = rgbData.length;
    packet.addByte((dataLength >> 16) & 0xFF);
    packet.addByte((dataLength >> 8) & 0xFF);
    packet.addByte(dataLength & 0xFF);

    // RGB data
    packet.add(rgbData);

    if (_debugPackets && (_sequenceNumber % 30 == 0)) {
      developer.log('[DDP] Seq ${_sequenceNumber}: R${rgbData[0]} G${rgbData[1]} B${rgbData[2]} @ pixel 0');
    }
    _sequenceNumber = (_sequenceNumber + 1) & 0xFFFF;

    return packet.toBytes();
  }

  /// Enable/disable packet debugging
  static void setDebug(bool enabled) {
    _debugPackets = enabled;
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
  static const int frameSize = 27000; // 90*100*3 RGB bytes

  DdpSender({required String host, int port = 4048})
      : _host = host,
        _port = port;

  /// Initialize the socket connection
  Future<bool> initialize() async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      developer.log('DdpSender initialized for $_host:$_port');
      return true;
    } catch (e) {
      developer.log('Failed to initialize DdpSender: $e');
      return false;
    }
  }

  /// Send a frame to the LED display
  void sendFrame(Uint8List rgbData) {
    if (rgbData.length != frameSize) {
      developer.log('Invalid frame size: ${rgbData.length}, expected $frameSize');
      return;
    }

    try {
      final packet = DDPSender._buildDdpPacketStatic(rgbData);
      _socket.send(packet, InternetAddress(_host), _port);
    } catch (e) {
      developer.log('Failed to send frame: $e');
    }
  }

  /// Clean up resources
  void dispose() {
    _socket.close();
  }
}

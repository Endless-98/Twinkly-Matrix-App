import 'dart:convert';
import 'dart:ui';
import 'package:http/http.dart' as http;

class ApiService {
  final String host;
  final int port;

  ApiService({required this.host, this.port = 5000});

  String get _baseUrl => 'http://$host:$port';

  /// Get list of available videos from the server
  Future<List<String>> getAvailableVideos() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/videos'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<String>.from(data['videos']);
      } else {
        throw Exception('Failed to load videos: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  /// Play a specific video
  Future<void> playVideo(
    String videoName, {
    bool loop = true,
    double? brightness,
    double? playbackFps,
  }) async {
    try {
      final body = {
        'video': videoName,
        'loop': loop,
        if (brightness != null) 'brightness': brightness,
        if (playbackFps != null) 'playback_fps': playbackFps,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/play'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception('Failed to play video: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  /// Stop current playback
  Future<void> stopPlayback() async {
    try {
      final response = await http
          .post(Uri.parse('$_baseUrl/api/stop'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception('Failed to stop playback: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  /// Get current playback status
  Future<Map<String, dynamic>> getStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/status'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to get status: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  /// Upload a video file
  Future<Map<String, dynamic>> uploadVideo(
    List<int> fileBytes,
    String fileName, {
    int renderFps = 20,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/upload'),
      );

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          fileBytes,
          filename: fileName,
        ),
      );

      request.fields['render_fps'] = renderFps.toString();

      final streamResponse = await request.send().timeout(const Duration(minutes: 5));
      final response = await http.Response.fromStream(streamResponse);

      if (response.statusCode == 201) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Upload failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Upload error: $e');
    }
  }

  /// Render an uploaded video
  Future<Map<String, dynamic>> renderVideo(
    String fileName, {
    int renderFps = 20,
  }) async {
    try {
      final body = {
        'filename': fileName,
        'render_fps': renderFps,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/render'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 10));

      if (response.statusCode == 202) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Render request failed: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Render error: $e');
    }
  }

  /// Delete a video file
  Future<void> deleteVideo(String videoName) async {
    try {
      final response = await http
          .delete(Uri.parse('$_baseUrl/api/videos/$videoName'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception('Failed to delete video: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Delete error: $e');
    }
  }

  /// Upload a video file with trim and crop parameters
  Future<Map<String, dynamic>> uploadVideoWithParams(
    List<int> fileBytes,
    String fileName, {
    int renderFps = 20,
    double? startTime,
    double? endTime,
    Rect? cropRect,
  }) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/api/upload'),
      );

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          fileBytes,
          filename: fileName,
        ),
      );

      request.fields['render_fps'] = renderFps.toString();
      if (startTime != null) request.fields['start_time'] = startTime.toString();
      if (endTime != null) request.fields['end_time'] = endTime.toString();
      if (cropRect != null) {
        request.fields['crop_left'] = cropRect.left.toString();
        request.fields['crop_top'] = cropRect.top.toString();
        request.fields['crop_right'] = cropRect.right.toString();
        request.fields['crop_bottom'] = cropRect.bottom.toString();
      }

      final streamResponse = await request.send().timeout(const Duration(minutes: 5));
      final response = await http.Response.fromStream(streamResponse);

      if (response.statusCode == 201) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Upload failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Upload error: $e');
    }
  }

  /// Render an uploaded video with trim and crop parameters
  Future<Map<String, dynamic>> renderVideoWithParams(
    String fileName, {
    int renderFps = 20,
    double? startTime,
    double? endTime,
    Rect? cropRect,
  }) async {
    try {
      final body = {
        'filename': fileName,
        'render_fps': renderFps,
        if (startTime != null) 'start_time': startTime,
        if (endTime != null) 'end_time': endTime,
        if (cropRect != null) ...{
          'crop_left': cropRect.left,
          'crop_top': cropRect.top,
          'crop_right': cropRect.right,
          'crop_bottom': cropRect.bottom,
        },
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/render'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 10));

      if (response.statusCode == 202) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Render request failed: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Render error: $e');
    }
  }
}

import 'dart:convert';
import 'dart:ui';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
        final videos = data['videos'];
        
        // Handle both old format (list of strings) and new format (list of maps)
        if (videos.isEmpty) {
          return [];
        }
        
        if (videos.first is String) {
          // Old format: list of filenames
          return List<String>.from(videos);
        } else if (videos.first is Map) {
          // New format: list of video metadata objects
          return (videos as List).map((v) => v['filename'] as String).toList();
        } else {
          throw Exception('Unexpected video list format');
        }
      } else {
        throw Exception('Failed to load videos: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Connection error: $e');
    }
  }

  /// Get list of available videos from the server with metadata
  Future<List<Map<String, dynamic>>> getAvailableVideosWithMeta() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/videos'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final videos = data['videos'];
        
        // Handle both old format and new format
        if (videos.isEmpty) {
          return [];
        }
        
        if (videos.first is String) {
          // Old format: convert strings to metadata objects
          return (videos as List<String>)
              .map((filename) => {
                'filename': filename,
                'has_thumbnail': false,
                'thumbnail': null,
              })
              .toList();
        } else {
          // New format: already metadata objects
          return List<Map<String, dynamic>>.from(videos);
        }
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

  /// Get render progress for a specific file
  Future<Map<String, dynamic>> getRenderProgress(String fileName) async {
    try {
      final encodedFileName = Uri.encodeComponent(fileName);
      final response = await http
          .get(Uri.parse('$_baseUrl/api/render/progress/$encodedFileName'))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else if (response.statusCode == 404) {
        return {'progress': 0.0, 'status': 'not_found'};
      } else {
        throw Exception('Failed to get render progress: ${response.statusCode}');
      }
    } catch (e) {
      // Return default on error to prevent crashes
      return {'progress': 0.0, 'status': 'error'};
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
    String? outputName,
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
        if (outputName != null) 'output_name': outputName,
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

  /// Get metadata for a rendered video (.npz)
  Future<Map<String, dynamic>> getRenderedVideoMeta(String fileName) async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/videos/$fileName/meta'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to load metadata: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Metadata error: $e');
    }
  }

  /// Trim an already rendered video (.npz) and save as a new file
  Future<Map<String, dynamic>> trimRenderedVideo(
    String fileName, {
    required double startTime,
    required double endTime,
    String? outputName,
  }) async {
    try {
      final body = {
        'start_time': startTime,
        'end_time': endTime,
        if (outputName != null) 'output_name': outputName,
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/videos/$fileName/trim'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 2));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Trim failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Trim error: $e');
    }
  }

  /// Rename an already rendered video (.npz)
  Future<void> renameVideo(String fileName, String newName) async {
    try {
      final body = {'new_name': newName};

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/videos/$fileName/rename'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception('Rename failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Rename error: $e');
    }
  }

  /// Download a video from YouTube to the device
  Future<Map<String, dynamic>> downloadYouTubeVideo(String youtubeUrl) async {
    try {
      final body = {'url': youtubeUrl};

      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/youtube/download'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Download failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('YouTube download error: $e');
    }
  }

  /// Get thumbnail URL for a video
  String getThumbnailUrl(String videoName) {
    // Remove .npz extension if present
    final stem = videoName.endsWith('.npz') ? videoName.substring(0, videoName.length - 4) : videoName;
    return '$_baseUrl/api/video/$stem/thumbnail';
  }

  /// Download a video file from the server to local device storage with progress tracking
  Future<String> downloadVideoLocally(String filename, {Function(int, int)? onProgress}) async {
    try {
      final encodedFileName = Uri.encodeComponent(filename);
      final url = '$_baseUrl/api/video/$encodedFileName';
      
      // Get temporary directory on device
      final tempDir = await getTemporaryDirectory();
      final localFile = File('${tempDir.path}/$filename');
      
      // Download the file with progress tracking using standard GET request
      final response = await http.get(
        Uri.parse(url),
      ).timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw Exception('Download timeout - file may be too large or network is slow');
        },
      );
      
      if (response.statusCode == 200) {
        // Get total file size
        final contentLength = response.bodyBytes.length;
        
        // Write to file in chunks with progress updates
        final sink = localFile.openWrite();
        const chunkSize = 8192; // 8KB chunks for smooth progress
        int written = 0;
        
        for (int i = 0; i < contentLength; i += chunkSize) {
          final end = (i + chunkSize < contentLength) ? i + chunkSize : contentLength;
          final chunk = response.bodyBytes.sublist(i, end);
          sink.add(chunk);
          written = end;
          onProgress?.call(written, contentLength);
          
          // Small delay to allow UI to update
          if (i % (chunkSize * 10) == 0) {
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }
        
        await sink.flush();
        await sink.close();
        
        return localFile.path;
      } else {
        throw Exception('Failed to download video: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Video download error: $e');
    }
  }
}

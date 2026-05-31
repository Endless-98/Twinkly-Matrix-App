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
          return List<String>.from(videos)
              .map((filename) => <String, dynamic>{
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

  /// Set brightness dynamically during playback (0.05 to 2.0 = 5% to 200%)
  Future<void> setBrightness(double brightness) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/brightness'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'brightness': brightness}),
          )
          .timeout(const Duration(seconds: 2));

      if (response.statusCode != 200) {
        // Silently fail if no active playback - not an error
        final data = jsonDecode(response.body);
        if (data['error'] != 'No active playback') {
          throw Exception('Failed to set brightness: ${response.statusCode}');
        }
      }
    } catch (e) {
      // Silently ignore brightness errors during scrubbing
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

  /// Get system health diagnostics
  Future<Map<String, dynamic>> getHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/health'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to get health: ${response.statusCode}');
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

  /// Reboot the FPP device. Returns immediately — device will be offline ~30s.
  Future<void> restartDevice() async {
    try {
      final response = await http
          .post(Uri.parse('$_baseUrl/api/restart_device'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Restart failed: ${response.statusCode}');
      }
    } catch (e) {
      // A connection-reset error is expected because the device reboots
      // before the HTTP response fully arrives. Treat it as success.
      final msg = e.toString();
      if (msg.contains('Connection reset') ||
          msg.contains('Connection closed') ||
          msg.contains('SocketException')) {
        return;
      }
      throw Exception('Restart error: $e');
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
    double brightness = 0.0,
    double contrast = 1.0,
    double hue = 0.0,
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
        if (brightness != 0.0) 'brightness': brightness,
        if (contrast != 1.0) 'contrast': contrast,
        if (hue != 0.0) 'hue': hue,
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

  /// Apply color adjustments to a rendered video (recolor in-place, preserving original)
  Future<void> recolorVideo(
    String fileName, {
    double brightness = 0.0,
    double contrast = 1.0,
    double hue = 0.0,
    double saturation = 1.0,
  }) async {
    try {
      final encoded = Uri.encodeComponent(fileName);
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/videos/$encoded/recolor'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'brightness': brightness,
              'contrast': contrast,
              'hue': hue,
              'saturation': saturation,
            }),
          )
          .timeout(const Duration(minutes: 5));
      if (response.statusCode != 200) {
        throw Exception('Recolor failed: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Recolor error: $e');
    }
  }

  /// Push a single-frame color-adjusted preview to the LED wall (fire-and-forget, no file save)
  Future<void> previewRecolorVideo(
    String fileName, {
    double brightness = 0.0,
    double contrast = 1.0,
    double hue = 0.0,
    double saturation = 1.0,
  }) async {
    try {
      final encoded = Uri.encodeComponent(fileName);
      await http
          .post(
            Uri.parse('$_baseUrl/api/videos/$encoded/recolor_preview'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'brightness': brightness,
              'contrast': contrast,
              'hue': hue,
              'saturation': saturation,
            }),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Silently swallow — this is best-effort live preview
    }
  }

  /// Clear any active live color preview for [fileName].
  /// Call this when the color-adjust dialog is dismissed (Cancel or Apply).
  Future<void> clearRecolorPreview(String fileName) async {
    try {
      final encoded = Uri.encodeComponent(fileName);
      await http
          .post(
            Uri.parse('$_baseUrl/api/videos/$encoded/recolor_preview'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'clear': true}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best-effort
    }
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

  // ---------------------------------------------------------------------------
  // Playlists
  // ---------------------------------------------------------------------------

  /// Safely extract an error message from an HTTP response body.
  /// Returns a status-code-based message if the body is not valid JSON.
  String _parseError(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map) return data['error']?.toString() ?? 'Unknown error';
    } catch (_) {}
    // HTML or non-JSON body — show a helpful message instead of a stack trace
    if (response.body.trimLeft().startsWith('<')) {
      return 'Backend returned HTML (status ${response.statusCode}). '
          'Run setup_fpp.sh on FPP to deploy the latest code.';
    }
    return 'Server error ${response.statusCode}';
  }

  /// Get all saved playlists
  Future<List<Map<String, dynamic>>> getPlaylists() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/playlists'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['playlists'] ?? []);
      }
      throw Exception(_parseError(response));
    } catch (e) {
      throw Exception('Playlist fetch error: $e');
    }
  }

  /// Create a new playlist
  Future<void> createPlaylist(String name, List<Map<String, dynamic>> entries,
      {double transitionDuration = 1.0, String color = '#42A5F5'}) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/playlists'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'entries': entries,
              'transition_duration': transitionDuration,
              'color': color,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 201) {
        throw Exception(_parseError(response));
      }
    } catch (e) {
      throw Exception('Playlist create error: $e');
    }
  }

  /// Update an existing playlist
  Future<void> updatePlaylist(String name, List<Map<String, dynamic>> entries,
      {double? transitionDuration, String? color, double? playDuration, bool? shuffle}) async {
    try {
      final body = <String, dynamic>{'entries': entries};
      if (transitionDuration != null) {
        body['transition_duration'] = transitionDuration;
      }
      if (color != null) {
        body['color'] = color;
      }
      if (playDuration != null) {
        body['play_duration'] = playDuration;
      }
      if (shuffle != null) {
        body['shuffle'] = shuffle;
      }
      final response = await http
          .put(
            Uri.parse('$_baseUrl/api/playlists/${Uri.encodeComponent(name)}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception(_parseError(response));
      }
    } catch (e) {
      throw Exception('Playlist update error: $e');
    }
  }

  /// Delete a playlist
  Future<void> deletePlaylist(String name) async {
    try {
      final response = await http
          .delete(Uri.parse('$_baseUrl/api/playlists/${Uri.encodeComponent(name)}'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception(_parseError(response));
      }
    } catch (e) {
      throw Exception('Playlist delete error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Schedules
  // ---------------------------------------------------------------------------

  /// Fetch all schedules
  Future<List<Map<String, dynamic>>> getSchedules() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/schedules'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['schedules'] ?? []);
      }
      throw Exception(_parseError(response));
    } catch (e) {
      throw Exception('Schedule fetch error: $e');
    }
  }

  /// Create a new schedule; returns the created schedule including its id
  Future<Map<String, dynamic>> createSchedule(Map<String, dynamic> schedule) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/schedules'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(schedule),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 201) {
        return Map<String, dynamic>.from(jsonDecode(response.body));
      }
      throw Exception(_parseError(response));
    } catch (e) {
      throw Exception('Schedule create error: $e');
    }
  }

  /// Update fields on an existing schedule
  Future<void> updateSchedule(String id, Map<String, dynamic> updates) async {
    try {
      final response = await http
          .put(
            Uri.parse('$_baseUrl/api/schedules/${Uri.encodeComponent(id)}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(updates),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception(_parseError(response));
      }
    } catch (e) {
      throw Exception('Schedule update error: $e');
    }
  }

  /// Delete a schedule by id
  Future<void> deleteSchedule(String id) async {
    try {
      final response = await http
          .delete(Uri.parse('$_baseUrl/api/schedules/${Uri.encodeComponent(id)}'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception(_parseError(response));
      }
    } catch (e) {
      throw Exception('Schedule delete error: $e');
    }
  }

  /// Get smart schedule configuration (Dodger Time, etc.)
  Future<Map<String, dynamic>> getSmartSchedules() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/smart-schedules'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_parseError(response));
    } catch (e) {
      throw Exception('Smart schedule fetch error: $e');
    }
  }

  /// Update smart schedule configuration
  Future<Map<String, dynamic>> updateSmartSchedules(
      Map<String, dynamic> data) async {
    try {
      final response = await http
          .put(
            Uri.parse('$_baseUrl/api/smart-schedules'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(data),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      throw Exception(_parseError(response));
    } catch (e) {
      throw Exception('Smart schedule update error: $e');
    }
  }

  /// Play a playlist
  Future<void> playPlaylist(String name,
      {bool loop = false, double? brightness, double playbackFps = 20.0}) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/playlist/play'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'name': name,
              'loop': loop,
              if (brightness != null) 'brightness': brightness,
              'playback_fps': playbackFps,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception(_parseError(response));
      }
    } catch (e) {
      throw Exception('Playlist play error: $e');
    }
  }

  /// Get available transition types
  Future<List<String>> getTransitions() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/transitions'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<String>.from(data['transitions'] ?? []);
      }
      return ['none', 'fade', 'slide', 'fisheye_swirl'];
    } catch (e) {
      return ['none', 'fade', 'slide', 'fisheye_swirl'];
    }
  }
}

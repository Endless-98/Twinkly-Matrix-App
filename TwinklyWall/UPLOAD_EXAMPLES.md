# Video Upload Examples

## cURL Examples

### Upload and render a video (20 FPS)
```bash
# Step 1: Upload
RESPONSE=$(curl -X POST \
  -F "file=@video.mp4" \
  -F "render_fps=20" \
  http://localhost:5000/api/upload)

# Extract filename from response
FILENAME=$(echo $RESPONSE | python3 -c "import sys, json; print(json.load(sys.stdin)['filename'])")

# Step 2: Render
curl -X POST \
  -H "Content-Type: application/json" \
  -d "{\"filename\": \"$FILENAME\", \"render_fps\": 20}" \
  http://localhost:5000/api/render

# Step 3: Check available videos
curl http://localhost:5000/api/videos

# Step 4: Play (once rendering is complete)
curl -X POST \
  -H "Content-Type: application/json" \
  -d "{\"video\": \"<rendered_filename>.npz\"}" \
  http://localhost:5000/api/play
```

### Upload at 40 FPS
```bash
curl -X POST \
  -F "file=@video.mp4" \
  -F "render_fps=40" \
  http://localhost:5000/api/upload | jq .
```

## Python Example

```python
import requests
import json
import time

API_URL = "http://localhost:5000"

def upload_and_render_video(video_path, render_fps=20):
    """Upload a video and queue it for rendering."""
    
    # Step 1: Upload
    with open(video_path, 'rb') as f:
        files = {'file': f}
        data = {'render_fps': render_fps}
        response = requests.post(f"{API_URL}/api/upload", files=files, data=data)
    
    if response.status_code != 201:
        print(f"Upload failed: {response.json()}")
        return None
    
    upload_data = response.json()
    filename = upload_data['filename']
    print(f"✓ Uploaded: {filename} ({upload_data['size_mb']} MB)")
    
    # Step 2: Render
    render_data = {
        'filename': filename,
        'render_fps': render_fps
    }
    response = requests.post(f"{API_URL}/api/render", json=render_data)
    
    if response.status_code != 202:
        print(f"Render request failed: {response.json()}")
        return None
    
    print(f"✓ Rendering queued at {render_fps} FPS")
    print(f"  Message: {response.json()['message']}")
    
    # Step 3: Poll for completion
    print("\nWaiting for rendering to complete...")
    while True:
        response = requests.get(f"{API_URL}/api/videos")
        videos = response.json()['videos']
        
        # Check if a recently-rendered file appears
        # (In production, you'd match more carefully by timestamp)
        print(f"  Available videos: {len(videos)}")
        
        time.sleep(5)  # Poll every 5 seconds

def play_video(video_filename, fps=20):
    """Play a rendered video."""
    data = {
        'video': video_filename,
        'loop': True,
        'playback_fps': fps
    }
    response = requests.post(f"{API_URL}/api/play", json=data)
    
    if response.status_code == 200:
        print(f"✓ Playing: {video_filename}")
        return True
    else:
        print(f"✗ Play failed: {response.json()}")
        return False

# Usage
if __name__ == "__main__":
    # Upload and render a video
    upload_and_render_video("my_video.mp4", render_fps=20)
    
    # Play it (after rendering completes)
    # play_video("my_video_90x50_20fps.npz")
```

## Flutter/Dart Example

```dart
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';

class VideoUploadService {
  final String apiUrl = "http://192.168.1.100:5000"; // FPP device IP
  
  Future<String?> uploadVideo(String videoPath, {int renderFps = 20}) async {
    try {
      // Step 1: Upload
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$apiUrl/api/upload'),
      );
      
      request.files.add(
        await http.MultipartFile.fromPath('file', videoPath),
      );
      request.fields['render_fps'] = renderFps.toString();
      
      var response = await request.send();
      var responseBody = await response.stream.bytesToString();
      
      if (response.statusCode != 201) {
        print('Upload failed: $responseBody');
        return null;
      }
      
      var uploadData = jsonDecode(responseBody);
      String filename = uploadData['filename'];
      print('✓ Uploaded: $filename');
      
      // Step 2: Queue rendering
      var renderResponse = await http.post(
        Uri.parse('$apiUrl/api/render'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'filename': filename,
          'render_fps': renderFps,
        }),
      );
      
      if (renderResponse.statusCode != 202) {
        print('Render request failed: ${renderResponse.body}');
        return null;
      }
      
      print('✓ Rendering queued at $renderFps FPS');
      return filename;
      
    } catch (e) {
      print('Error: $e');
      return null;
    }
  }
  
  Future<List<String>> getAvailableVideos() async {
    try {
      var response = await http.get(Uri.parse('$apiUrl/api/videos'));
      
      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        return List<String>.from(data['videos']);
      }
    } catch (e) {
      print('Error fetching videos: $e');
    }
    return [];
  }
  
  Future<bool> playVideo(String videoFilename) async {
    try {
      var response = await http.post(
        Uri.parse('$apiUrl/api/play'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'video': videoFilename,
          'loop': true,
          'playback_fps': 20,
        }),
      );
      
      return response.statusCode == 200;
    } catch (e) {
      print('Error playing video: $e');
      return false;
    }
  }
}

// Usage in Flutter
void main() async {
  final service = VideoUploadService();
  
  // Pick video from device
  String videoPath = '/path/to/video.mp4';
  
  // Upload and queue rendering
  String? filename = await service.uploadVideo(videoPath, renderFps: 20);
  
  if (filename != null) {
    print('Video queued for rendering: $filename');
    
    // Poll for available videos
    for (int i = 0; i < 60; i++) {
      await Future.delayed(Duration(seconds: 5));
      var videos = await service.getAvailableVideos();
      print('Available videos: $videos');
      
      // Check if our video was rendered (you'd implement better matching)
      if (videos.isNotEmpty) {
        // Play the first one
        bool played = await service.playVideo(videos.first);
        if (played) break;
      }
    }
  }
}
```

## JavaScript/Node.js Example

```javascript
const axios = require('axios');
const FormData = require('form-data');
const fs = require('fs');

const API_URL = 'http://localhost:5000';

async function uploadAndRenderVideo(videoPath, renderFps = 20) {
  try {
    // Step 1: Upload
    const form = new FormData();
    form.append('file', fs.createReadStream(videoPath));
    form.append('render_fps', renderFps);
    
    const uploadResponse = await axios.post(
      `${API_URL}/api/upload`,
      form,
      { headers: form.getHeaders() }
    );
    
    if (uploadResponse.status !== 201) {
      throw new Error(`Upload failed: ${uploadResponse.data}`);
    }
    
    const filename = uploadResponse.data.filename;
    console.log(`✓ Uploaded: ${filename}`);
    
    // Step 2: Queue rendering
    const renderResponse = await axios.post(
      `${API_URL}/api/render`,
      {
        filename: filename,
        render_fps: renderFps
      }
    );
    
    console.log(`✓ Rendering queued at ${renderFps} FPS`);
    return filename;
    
  } catch (error) {
    console.error('Error:', error.message);
    return null;
  }
}

async function getAvailableVideos() {
  try {
    const response = await axios.get(`${API_URL}/api/videos`);
    return response.data.videos;
  } catch (error) {
    console.error('Error fetching videos:', error.message);
    return [];
  }
}

// Usage
(async () => {
  const videoPath = './my_video.mp4';
  const filename = await uploadAndRenderVideo(videoPath, 20);
  
  if (filename) {
    console.log('Waiting for rendering...');
    
    // Poll every 10 seconds
    const pollInterval = setInterval(async () => {
      const videos = await getAvailableVideos();
      console.log(`Available videos: ${videos.length}`);
      
      if (videos.length > 0) {
        console.log('Rendering complete!');
        clearInterval(pollInterval);
      }
    }, 10000);
  }
})();
```

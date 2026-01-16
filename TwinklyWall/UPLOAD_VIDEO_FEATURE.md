# Video Upload & Rendering Feature

## Overview
This feature allows mobile app users to upload videos from their local files, which are then rendered on the FPP device at either 20 or 40 FPS. After rendering, the original video file is deleted and the rendered video becomes available for playback.

## API Endpoints

### 1. Upload Video
**POST `/api/upload`**

Upload a video file from the mobile app.

**Form Data:**
- `file` (required): Video file (mp4, avi, mov, mkv, flv, wmv)
- `render_fps` (optional): Target rendering FPS - `20` or `40` (default: 20)

**Max File Size:** 500 MB

**Response (201 Created):**
```json
{
  "status": "uploaded",
  "filename": "my_video.mp4",
  "size_mb": 45.23,
  "render_fps": 20,
  "next_step": "Call /api/render to process the video"
}
```

**Example:**
```bash
curl -X POST -F "file=@my_video.mp4" -F "render_fps=20" http://localhost:5000/api/upload
```

### 2. Render Video
**POST `/api/render`**

Start rendering an uploaded video. Rendering happens asynchronously in the background.

**JSON Body:**
```json
{
  "filename": "my_video.mp4",
  "render_fps": 20
}
```

**Response (202 Accepted):**
```json
{
  "status": "rendering",
  "filename": "my_video.mp4",
  "render_fps": 20,
  "message": "Video is being rendered in the background. It will appear in /api/videos once complete."
}
```

### 3. Get Videos (Updated)
**GET `/api/videos`**

Returns list of all available rendered videos. Includes both pre-rendered and user-uploaded videos.

**Response:**
```json
{
  "videos": [
    "my_video_90x50_20fps.npz",
    "demo_90x50_40fps.npz",
    "custom_upload_90x50_20fps.npz"
  ]
}
```

## Directory Structure

```
TwinklyWall/
├── uploaded_videos/              # Temporary storage for uploaded files (git-ignored)
│   ├── my_video.mp4             # Uploaded by user
│   └── another_video.mov        # Gets deleted after rendering
├── dotmatrix/
│   └── rendered_videos/         # Final rendered videos
│       ├── my_video_90x50_20fps.npz      # Pre-rendered
│       ├── user_video_90x50_20fps.npz    # User-uploaded & rendered
│       └── .gitkeep                      # Git-tracked placeholder
└── assets/
    └── source_videos/           # Source videos (git-tracked)
```

## Git Ignore Configuration

The `.gitignore` has been updated to:
- **Ignore:** `uploaded_videos/` - temporary uploads
- **Ignore:** `dotmatrix/rendered_videos/*.npz` - rendered video files
- **Keep:** `.gitkeep` files to preserve directory structure

This ensures that:
- User-uploaded videos are not stored in version control
- Pre-rendered video files are not bloated in git
- The directory structure is preserved for cloning

## Workflow

### Mobile App User Flow

1. **Upload a video:**
   ```
   POST /api/upload with video file
   → Returns filename and render_fps
   ```

2. **Render the video:**
   ```
   POST /api/render with filename and render_fps
   → Returns 202 (rendering in background)
   ```

3. **Wait for rendering to complete:**
   - Rendering happens asynchronously
   - Check `/api/videos` periodically for the new rendered video
   - Once it appears, the original upload is deleted

4. **Play the rendered video:**
   ```
   POST /api/play with the rendered filename
   → Video plays on the LED matrix
   ```

## Rendering Process

When `/api/render` is called:

1. ✅ Original video is read from `uploaded_videos/`
2. ✅ VideoRenderer processes it at the specified FPS (20 or 40)
3. ✅ Output is saved as `.npz` file in `dotmatrix/rendered_videos/`
4. ✅ Original uploaded video file is automatically deleted
5. ✅ Rendered video is immediately available for playback

## Configuration

**In `api_server.py`:**
```python
ALLOWED_EXTENSIONS = {'mp4', 'avi', 'mov', 'mkv', 'flv', 'wmv'}
MAX_UPLOAD_SIZE = 500 * 1024 * 1024  # 500 MB
```

**Rendering options:**
- `render_fps`: 20 or 40 (controls playback speed)
- Resolution and quantization are inherited from VideoRenderer defaults (90x50, 8-bit per channel)

## Error Handling

**Upload errors:**
- 400: No file provided
- 400: Unsupported file type
- 413: File too large (>500 MB)

**Render errors:**
- 404: Uploaded video not found
- 202: Rendering queued (check logs for actual errors)

## Notes

- Rendering is asynchronous and happens in a background thread
- Large videos may take several minutes to render
- Users should poll `/api/videos` to check when rendering is complete
- Original uploaded files are cleaned up automatically after successful rendering

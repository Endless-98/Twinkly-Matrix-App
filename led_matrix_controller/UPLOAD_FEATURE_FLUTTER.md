# Video Upload Feature - Flutter App

## Overview
Added a complete video upload system to the Flutter app's Scenes section. Users can now:
1. Tap the **+** button in the Scenes section
2. Select a video from their phone
3. Choose render quality (20 or 40 FPS)
4. Upload and render the video on the FPP device
5. Original file is deleted after rendering

## Changes Made

### 1. Dependencies Added (`pubspec.yaml`)
- **`file_picker: ^6.0.0`** - For selecting video files from device storage

### 2. API Service Updates (`lib/services/api_service.dart`)

#### New Method: `uploadVideo()`
```dart
Future<Map<String, dynamic>> uploadVideo(
  List<int> fileBytes,
  String fileName, {
  int renderFps = 20,
}) 
```
- Uploads video file to FPP device
- Returns upload metadata including filename
- Supports 500 MB file limit

#### New Method: `renderVideo()`
```dart
Future<Map<String, dynamic>> renderVideo(
  String fileName, {
  int renderFps = 20,
})
```
- Queues uploaded video for rendering
- Supports 20 or 40 FPS output
- Returns rendering job status

### 3. Scenes Page Updates (`lib/pages/scenes_selector_page.dart`)

#### UI Changes:
- **Plus (+) button** in AppBar for uploading new videos
- Opens file picker for video selection

#### New Methods:
- `_uploadAndRenderVideo()` - Handles file selection
- `_showUploadDialog()` - Shows upload options dialog

#### New Widget: `_UploadDialogContent`
A stateful widget that displays:
- Selected filename and file size
- **FPS selection toggle** (20 or 40 FPS)
- Upload progress indicator
- Real-time status messages
- Upload/cancel buttons

## User Flow

### Step 1: Select Video
1. Tap **+** button in Scenes section
2. File picker opens
3. User selects a video file from their phone
4. Supported formats: mp4, avi, mov, mkv, flv, wmv
5. Maximum file size: 500 MB

### Step 2: Choose Quality
Dialog appears with options:
- **20 FPS** (default) - Lower bandwidth, smaller file
- **40 FPS** - Higher quality, smoother playback

### Step 3: Upload & Render
1. Tap **"Upload & Render"** button
2. Progress indicators show:
   - "Uploading to device..." (0-30%)
   - "Queuing render job..." (30-60%)
   - "Rendering in progress!" (60-100%)
3. Dialog closes automatically when complete
4. User sees confirmation snackbar

### Step 4: Automatic Refresh
- Scenes list automatically refreshes
- Newly rendered video appears once rendering completes
- Original file is deleted from FPP device

## Implementation Details

### File Selection
Uses Flutter's `file_picker` package for native file selection:
- Works on iOS and Android
- Filters to video files only
- Returns file bytes in memory

### Upload Process
```
User selects video
    ↓
File picker returns file bytes
    ↓
Show upload dialog with FPS options
    ↓
User taps "Upload & Render"
    ↓
API: uploadVideo() → uploads to FPP
    ↓
API: renderVideo() → queues rendering
    ↓
Original file deleted on FPP
    ↓
List refreshes, rendered video appears
```

### Progress Tracking
Real-time status updates during upload:
- 0-30%: Uploading file
- 30-60%: Processing on FPP
- 60-100%: Rendering video (may take time)

## Error Handling
- File selection cancellation handled gracefully
- Upload errors show snackbar with error message
- Dialog remains open on error for retry
- File size validation (max 500 MB)

## Integration with Backend
The feature integrates with the existing API endpoints:
- `POST /api/upload` - File upload
- `POST /api/render` - Render job queue
- `GET /api/videos` - List videos (auto-refresh)
- `POST /api/play` - Play rendered video (existing)

## Testing on Device

### ADB Connection
Device is paired and ready:
```bash
adb connect 192.168.1.36:37965
```

### Building and Running
```bash
flutter pub get
flutter run
```

### Testing Upload
1. Open app and navigate to Scenes
2. Tap + button
3. Select a video from device
4. Choose FPS (20 or 40)
5. Tap "Upload & Render"
6. Watch progress indicators
7. See confirmation when complete
8. Verify video appears in list

## Notes
- Rendering happens asynchronously on FPP device
- Large videos may take several minutes to render
- Users can close the app - rendering continues in background
- Rendered video is ready to play immediately after completion
- Original uploaded files are automatically cleaned up

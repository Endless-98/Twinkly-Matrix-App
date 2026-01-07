# Quick Test Guide - Multi-Mode Capture

## Prerequisites
✅ Windows machine with admin access
✅ FFmpeg installed (`choco install ffmpeg -y`)
✅ FPP running at 192.168.1.68:4049
✅ LED wall connected and configured

## Test Sequence

### 1. Desktop Mode (Baseline Test)
**Goal**: Verify full screen capture works

1. Launch app: `.\led_matrix_controller.exe`
2. Navigate to "Mirroring" page
3. Verify "Full Desktop" is selected
4. Click "Toggle Desktop Mirror"
5. **Expected**: See screen mirrored on LED wall within 1-2 seconds
6. Move mouse, open windows - should see on wall
7. Check logs: `C:\Users\mohog\Documents\TwinklyWall\ddp_debug.log`
8. Stop capture

**Success Criteria**:
- ✓ Real-time mirroring (15-20 FPS)
- ✓ Colors accurate
- ✓ Text readable (90×50 limits, but should be discernible)

---

### 2. App Window Mode (Advanced Test)
**Goal**: Capture specific window

#### 2A: Chrome Browser
1. Open Google Chrome (not minimized)
2. In app, select "App Window" mode
3. Click "Refresh Windows" button
4. Scroll through list, find "Google Chrome" (or similar)
5. Click to select window
6. Status should show: "Window selected: Google Chrome"
7. Click "Toggle Desktop Mirror"
8. **Expected**: Only Chrome window appears on LED wall
9. Switch to other app - LED should NOT change
10. Return to Chrome, move content - LED updates

**Success Criteria**:
- ✓ Window list populates (10+ windows)
- ✓ Chrome isolates correctly
- ✓ No other windows visible on LED
- ✓ Performance same as desktop mode

#### 2B: VS Code Editor
1. Stop capture
2. Click "Refresh Windows"
3. Select "Visual Studio Code" or "VS Code"
4. Start capture
5. **Expected**: Only VS Code on LED wall
6. Type code, scroll - should update

---

### 3. Region Mode (Precision Test)
**Goal**: Capture custom area

#### 3A: Center Square (800×600)
1. Stop capture
2. Select "Region" mode
3. Note current region: "Capture area: 800×600 at (0,0)"
4. Click "Configure Region"
5. Enter:
   - X: `560` (centered horizontally: (1920-800)/2)
   - Y: `240` (centered vertically: (1080-600)/2)
   - Width: `800`
   - Height: `600`
6. Click OK
7. Status should update: "Region configured: 800×600 at (560,240)"
8. Start capture
9. **Expected**: Center portion of screen on LED wall

**Test**:
- Move window into region - appears
- Move window out - disappears
- Mouse cursor in region - visible

#### 3B: Bottom-Right Quadrant
1. Stop capture
2. Click "Configure Region"
3. Enter:
   - X: `960`
   - Y: `540`
   - Width: `960`
   - Height: `540`
4. Start capture
5. **Expected**: Bottom-right quarter of screen

---

## Quality Evaluation

### Text Readability Test
1. Desktop mode
2. Open Notepad, maximize
3. Type large text (72pt font): "HELLO WALL"
4. Check LED wall

**Expected**: Letters distinguishable (H, E, L, O visible as shapes)

### Color Accuracy Test
1. Open Paint/browser
2. Show pure colors:
   - Red (255,0,0)
   - Green (0,255,0)
   - Blue (0,0,255)
   - White (255,255,255)
   - Black (0,0,0)
3. Verify LED wall matches

### Motion Test
1. Desktop mode
2. Play YouTube video (720p or higher)
3. Check smoothness

**Expected**: 15-20 FPS, slight delay acceptable

---

## Performance Benchmarks

### Check FPS
Monitor console output:
```
[MIRRORING] ✓ Frame 50 sent in 5ms (capture: 12ms)
...
Streaming... (50 frames @ ~18.5 FPS)
```

**Target**: 15-20 FPS sustained

### Check Latency
1. Desktop mode
2. Move mouse quickly in circles
3. Watch LED wall

**Expected**: <100ms lag (feels responsive)

---

## Troubleshooting

### Issue: "No windows found"
**Fix**:
1. Ensure apps not minimized
2. Run as administrator: Right-click exe → "Run as administrator"
3. Check PowerShell works: `powershell -Command "Get-Process"`

### Issue: App window shows black
**Cause**: Hardware acceleration (DirectX)
**Fix**: 
1. Disable in app (Chrome: Settings → System → Use hardware acceleration)
2. OR use Desktop mode + manual region

### Issue: Region capture off-center
**Cause**: Multi-monitor setup
**Fix**: Check total desktop resolution
```powershell
[System.Windows.Forms.Screen]::AllScreens | Select DeviceName, Bounds
```

### Issue: Low FPS (<10)
**Checks**:
1. CPU usage (Task Manager)
2. FFmpeg running: `tasklist | findstr ffmpeg`
3. Network: `ping 192.168.1.68`
4. Reduce region size (smaller = faster)

---

## Expected Log Output

### Successful Desktop Capture
```
[CONFIG] Capture mode set to: CaptureMode.desktop
[DETECT] Windows screen size: 1920x1080
[FFMPEG] Using Windows gdigrab input
[FFMPEG] Capturing desktop at 1920x1080
[MIRRORING] Starting desktop capture, target FPP: 192.168.1.68:4049
[MIRRORING] ✓ Frame 0 sent in 5ms (capture: 15ms)
[MIRRORING] ✓ Frame 1 sent in 4ms (capture: 12ms)
```

### Successful App Window Capture
```
[CONFIG] Capture mode set to: CaptureMode.appWindow
[WINDOWS] Found 23 windows
[FFMPEG] Capturing window: Google Chrome
[MIRRORING] Starting desktop capture, target FPP: 192.168.1.68:4049
```

### Successful Region Capture
```
[CONFIG] Capture mode set to: CaptureMode.region
[FFMPEG] Capturing region: x=560, y=240, 800x600
[MIRRORING] Starting desktop capture, target FPP: 192.168.1.68:4049
```

---

## Next Steps After Testing

### If Desktop Works ✅
→ Test App Window mode

### If App Window Works ✅
→ Test Region mode

### If All Work ✅
→ Stress test (long duration, 30+ minutes)
→ Document any crashes/issues
→ Prepare for quality improvements phase

### If Issues Found ❌
→ Check logs in `C:\Users\mohog\Documents\TwinklyWall\`
→ Run FFmpeg manually to isolate issue
→ Report specific error messages

---

## Manual FFmpeg Test (Debug)

If app fails, test FFmpeg directly:

### Desktop
```powershell
ffmpeg -f gdigrab -framerate 60 -i desktop -vf scale=90:50:flags=lanczos -pix_fmt rgb24 -f rawvideo test.raw
```

### App Window
```powershell
ffmpeg -f gdigrab -i title="Google Chrome" -vf scale=90:50:flags=lanczos -pix_fmt rgb24 -f rawvideo test.raw
```

### Region
```powershell
ffmpeg -f gdigrab -offset_x 560 -offset_y 240 -video_size 800x600 -i desktop -vf scale=90:50:flags=lanczos -pix_fmt rgb24 -f rawvideo test.raw
```

Press Ctrl+C after 5 seconds, check file size:
- **Expected**: ~67,500 bytes (90×50×3 × 5 frames)

---

## Contact
Issues? Contact Moses (Number One Engineer) with:
1. Mode being tested
2. Error message (exact text)
3. Log file contents
4. Screenshot if applicable

Happy testing! 🎉

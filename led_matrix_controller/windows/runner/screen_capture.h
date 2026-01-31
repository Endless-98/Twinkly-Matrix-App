#ifndef RUNNER_SCREEN_CAPTURE_H_
#define RUNNER_SCREEN_CAPTURE_H_

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <vector>
#include <string>
#include <memory>
#include <mutex>
#include <atomic>
#include <thread>

// Screen capture implementation using Windows Desktop Duplication API
// Falls back to GDI BitBlt if Desktop Duplication is not available
class ScreenCapture {
public:
    ScreenCapture();
    ~ScreenCapture();

    // Initialize the capture system
    bool Initialize();
    
    // Start continuous capture with specified target dimensions
    bool StartCapture(int targetWidth, int targetHeight);
    
    // Stop capturing
    void StopCapture();
    
    // Get the latest frame as RGB data (resized to target dimensions)
    // Returns empty vector if no frame is available
    std::vector<uint8_t> GetLatestFrame();
    
    // Get screen dimensions
    int GetScreenWidth() const { return screenWidth_; }
    int GetScreenHeight() const { return screenHeight_; }
    
    // Check if capturing is active
    bool IsCapturing() const { return isCapturing_.load(); }
    
    // Check if using hardware acceleration (Desktop Duplication)
    bool IsHardwareAccelerated() const { return useDesktopDuplication_; }
    
    // Get list of available windows for capture
    static std::vector<std::wstring> GetAvailableWindows();

private:
    // Desktop Duplication API objects
    ID3D11Device* d3dDevice_ = nullptr;
    ID3D11DeviceContext* d3dContext_ = nullptr;
    IDXGIOutputDuplication* deskDupl_ = nullptr;
    ID3D11Texture2D* stagingTexture_ = nullptr;
    
    // GDI fallback objects
    HDC screenDC_ = nullptr;
    HDC memDC_ = nullptr;
    HBITMAP memBitmap_ = nullptr;
    HGDIOBJ oldBitmap_ = nullptr;
    
    // Frame buffer
    std::vector<uint8_t> frameBuffer_;
    std::vector<uint8_t> resizedBuffer_;
    std::mutex frameMutex_;
    
    // Capture thread
    std::thread captureThread_;
    std::atomic<bool> isCapturing_{false};
    std::atomic<bool> shouldStop_{false};
    
    // Screen dimensions
    int screenWidth_ = 0;
    int screenHeight_ = 0;
    int targetWidth_ = 90;
    int targetHeight_ = 50;
    
    // Mode flags
    bool useDesktopDuplication_ = false;
    bool isInitialized_ = false;
    
    // Private methods
    bool InitializeDesktopDuplication();
    bool InitializeGDI();
    void CleanupDesktopDuplication();
    void CleanupGDI();
    void CaptureLoop();
    bool CaptureFrameDesktopDuplication();
    bool CaptureFrameGDI();
    void ResizeFrame(const uint8_t* src, int srcWidth, int srcHeight,
                     uint8_t* dst, int dstWidth, int dstHeight);
    
    // RAII helper for HBITMAP
    struct BitmapDeleter {
        void operator()(HBITMAP bmp) { if (bmp) DeleteObject(bmp); }
    };
};

#endif  // RUNNER_SCREEN_CAPTURE_H_

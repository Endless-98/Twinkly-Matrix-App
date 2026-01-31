#include "screen_capture.h"
#include <algorithm>
#include <cstring>

// Link required libraries (handled by CMakeLists.txt)

ScreenCapture::ScreenCapture() {}

ScreenCapture::~ScreenCapture() {
    StopCapture();
    CleanupDesktopDuplication();
    CleanupGDI();
}

bool ScreenCapture::Initialize() {
    if (isInitialized_) {
        return true;
    }
    
    // Get screen dimensions
    screenWidth_ = GetSystemMetrics(SM_CXSCREEN);
    screenHeight_ = GetSystemMetrics(SM_CYSCREEN);
    
    // Try Desktop Duplication API first (Windows 8+, better performance)
    if (InitializeDesktopDuplication()) {
        useDesktopDuplication_ = true;
        isInitialized_ = true;
        OutputDebugStringA("[CAPTURE] Using Desktop Duplication API\n");
        return true;
    }
    
    // Fall back to GDI (works on all Windows versions)
    if (InitializeGDI()) {
        useDesktopDuplication_ = false;
        isInitialized_ = true;
        OutputDebugStringA("[CAPTURE] Using GDI BitBlt (fallback)\n");
        return true;
    }
    
    OutputDebugStringA("[CAPTURE] Failed to initialize any capture method\n");
    return false;
}

bool ScreenCapture::InitializeDesktopDuplication() {
    HRESULT hr;
    
    // Create D3D11 device
    D3D_FEATURE_LEVEL featureLevels[] = { D3D_FEATURE_LEVEL_11_0 };
    D3D_FEATURE_LEVEL featureLevel;
    
    hr = D3D11CreateDevice(
        nullptr,                    // Use default adapter
        D3D_DRIVER_TYPE_HARDWARE,   // Hardware acceleration
        nullptr,                    // No software rasterizer
        0,                          // Flags
        featureLevels,              // Feature levels
        1,                          // Number of feature levels
        D3D11_SDK_VERSION,
        &d3dDevice_,
        &featureLevel,
        &d3dContext_
    );
    
    if (FAILED(hr)) {
        OutputDebugStringA("[CAPTURE] Failed to create D3D11 device\n");
        return false;
    }
    
    // Get DXGI device
    IDXGIDevice* dxgiDevice = nullptr;
    hr = d3dDevice_->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxgiDevice);
    if (FAILED(hr)) {
        CleanupDesktopDuplication();
        return false;
    }
    
    // Get DXGI adapter
    IDXGIAdapter* dxgiAdapter = nullptr;
    hr = dxgiDevice->GetParent(__uuidof(IDXGIAdapter), (void**)&dxgiAdapter);
    dxgiDevice->Release();
    if (FAILED(hr)) {
        CleanupDesktopDuplication();
        return false;
    }
    
    // Get primary output
    IDXGIOutput* dxgiOutput = nullptr;
    hr = dxgiAdapter->EnumOutputs(0, &dxgiOutput);
    dxgiAdapter->Release();
    if (FAILED(hr)) {
        CleanupDesktopDuplication();
        return false;
    }
    
    // Get output1 for duplication
    IDXGIOutput1* dxgiOutput1 = nullptr;
    hr = dxgiOutput->QueryInterface(__uuidof(IDXGIOutput1), (void**)&dxgiOutput1);
    dxgiOutput->Release();
    if (FAILED(hr)) {
        CleanupDesktopDuplication();
        return false;
    }
    
    // Create desktop duplication
    hr = dxgiOutput1->DuplicateOutput(d3dDevice_, &deskDupl_);
    dxgiOutput1->Release();
    if (FAILED(hr)) {
        OutputDebugStringA("[CAPTURE] Failed to create desktop duplication\n");
        CleanupDesktopDuplication();
        return false;
    }
    
    // Create staging texture for CPU access
    D3D11_TEXTURE2D_DESC texDesc = {};
    texDesc.Width = screenWidth_;
    texDesc.Height = screenHeight_;
    texDesc.MipLevels = 1;
    texDesc.ArraySize = 1;
    texDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texDesc.SampleDesc.Count = 1;
    texDesc.Usage = D3D11_USAGE_STAGING;
    texDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    
    hr = d3dDevice_->CreateTexture2D(&texDesc, nullptr, &stagingTexture_);
    if (FAILED(hr)) {
        CleanupDesktopDuplication();
        return false;
    }
    
    return true;
}

bool ScreenCapture::InitializeGDI() {
    screenDC_ = GetDC(nullptr);
    if (!screenDC_) {
        return false;
    }
    
    memDC_ = CreateCompatibleDC(screenDC_);
    if (!memDC_) {
        CleanupGDI();
        return false;
    }
    
    memBitmap_ = CreateCompatibleBitmap(screenDC_, screenWidth_, screenHeight_);
    if (!memBitmap_) {
        CleanupGDI();
        return false;
    }
    
    oldBitmap_ = SelectObject(memDC_, memBitmap_);
    return true;
}

void ScreenCapture::CleanupDesktopDuplication() {
    if (stagingTexture_) {
        stagingTexture_->Release();
        stagingTexture_ = nullptr;
    }
    if (deskDupl_) {
        deskDupl_->Release();
        deskDupl_ = nullptr;
    }
    if (d3dContext_) {
        d3dContext_->Release();
        d3dContext_ = nullptr;
    }
    if (d3dDevice_) {
        d3dDevice_->Release();
        d3dDevice_ = nullptr;
    }
}

void ScreenCapture::CleanupGDI() {
    if (memDC_ && oldBitmap_) {
        SelectObject(memDC_, oldBitmap_);
        oldBitmap_ = nullptr;
    }
    if (memBitmap_) {
        DeleteObject(memBitmap_);
        memBitmap_ = nullptr;
    }
    if (memDC_) {
        DeleteDC(memDC_);
        memDC_ = nullptr;
    }
    if (screenDC_) {
        ReleaseDC(nullptr, screenDC_);
        screenDC_ = nullptr;
    }
}

bool ScreenCapture::StartCapture(int targetWidth, int targetHeight) {
    if (isCapturing_.load()) {
        return true;  // Already capturing
    }
    
    if (!isInitialized_ && !Initialize()) {
        return false;
    }
    
    targetWidth_ = targetWidth;
    targetHeight_ = targetHeight;
    
    // Pre-allocate buffers
    frameBuffer_.resize(screenWidth_ * screenHeight_ * 3);
    resizedBuffer_.resize(targetWidth_ * targetHeight_ * 3);
    
    shouldStop_.store(false);
    isCapturing_.store(true);
    
    // Start capture thread
    captureThread_ = std::thread(&ScreenCapture::CaptureLoop, this);
    
    return true;
}

void ScreenCapture::StopCapture() {
    if (!isCapturing_.load()) {
        return;
    }
    
    shouldStop_.store(true);
    isCapturing_.store(false);
    
    if (captureThread_.joinable()) {
        captureThread_.join();
    }
}

std::vector<uint8_t> ScreenCapture::GetLatestFrame() {
    std::lock_guard<std::mutex> lock(frameMutex_);
    return resizedBuffer_;
}

void ScreenCapture::CaptureLoop() {
    const auto frameDuration = std::chrono::milliseconds(50);  // 20 FPS
    
    while (!shouldStop_.load()) {
        auto frameStart = std::chrono::steady_clock::now();
        
        bool success = false;
        if (useDesktopDuplication_) {
            success = CaptureFrameDesktopDuplication();
        } else {
            success = CaptureFrameGDI();
        }
        
        if (success) {
            // Resize frame to target dimensions
            std::lock_guard<std::mutex> lock(frameMutex_);
            ResizeFrame(frameBuffer_.data(), screenWidth_, screenHeight_,
                       resizedBuffer_.data(), targetWidth_, targetHeight_);
        }
        
        // Maintain frame rate
        auto frameEnd = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(frameEnd - frameStart);
        if (elapsed < frameDuration) {
            std::this_thread::sleep_for(frameDuration - elapsed);
        }
    }
}

bool ScreenCapture::CaptureFrameDesktopDuplication() {
    if (!deskDupl_) return false;
    
    DXGI_OUTDUPL_FRAME_INFO frameInfo;
    IDXGIResource* desktopResource = nullptr;
    
    // Acquire next frame
    HRESULT hr = deskDupl_->AcquireNextFrame(100, &frameInfo, &desktopResource);
    
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        // No new frame, use previous
        return true;
    }
    
    if (FAILED(hr)) {
        if (hr == DXGI_ERROR_ACCESS_LOST) {
            // Reinitialize desktop duplication
            CleanupDesktopDuplication();
            if (!InitializeDesktopDuplication()) {
                // Fall back to GDI
                useDesktopDuplication_ = false;
                InitializeGDI();
            }
        }
        return false;
    }
    
    // Get the texture
    ID3D11Texture2D* desktopTexture = nullptr;
    hr = desktopResource->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&desktopTexture);
    desktopResource->Release();
    
    if (FAILED(hr)) {
        deskDupl_->ReleaseFrame();
        return false;
    }
    
    // Copy to staging texture
    d3dContext_->CopyResource(stagingTexture_, desktopTexture);
    desktopTexture->Release();
    
    // Map the staging texture
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = d3dContext_->Map(stagingTexture_, 0, D3D11_MAP_READ, 0, &mapped);
    
    if (SUCCEEDED(hr)) {
        // Convert BGRA to RGB
        const uint8_t* src = static_cast<uint8_t*>(mapped.pData);
        uint8_t* dst = frameBuffer_.data();
        
        for (int y = 0; y < screenHeight_; ++y) {
            const uint8_t* srcRow = src + y * mapped.RowPitch;
            uint8_t* dstRow = dst + y * screenWidth_ * 3;
            
            for (int x = 0; x < screenWidth_; ++x) {
                // BGRA -> RGB
                dstRow[x * 3 + 0] = srcRow[x * 4 + 2];  // R
                dstRow[x * 3 + 1] = srcRow[x * 4 + 1];  // G
                dstRow[x * 3 + 2] = srcRow[x * 4 + 0];  // B
            }
        }
        
        d3dContext_->Unmap(stagingTexture_, 0);
    }
    
    deskDupl_->ReleaseFrame();
    return SUCCEEDED(hr);
}

bool ScreenCapture::CaptureFrameGDI() {
    if (!memDC_ || !screenDC_) return false;
    
    // Capture screen to memory DC
    if (!BitBlt(memDC_, 0, 0, screenWidth_, screenHeight_, 
                screenDC_, 0, 0, SRCCOPY)) {
        return false;
    }
    
    // Get bitmap bits
    BITMAPINFOHEADER bi = {};
    bi.biSize = sizeof(BITMAPINFOHEADER);
    bi.biWidth = screenWidth_;
    bi.biHeight = -screenHeight_;  // Negative for top-down
    bi.biPlanes = 1;
    bi.biBitCount = 24;
    bi.biCompression = BI_RGB;
    
    int scanlineBytes = ((screenWidth_ * 3 + 3) & ~3);
    std::vector<uint8_t> bmpData(scanlineBytes * screenHeight_);
    
    if (!GetDIBits(memDC_, memBitmap_, 0, screenHeight_, 
                   bmpData.data(), (BITMAPINFO*)&bi, DIB_RGB_COLORS)) {
        return false;
    }
    
    // Copy to frame buffer (BGR -> RGB)
    uint8_t* dst = frameBuffer_.data();
    for (int y = 0; y < screenHeight_; ++y) {
        const uint8_t* srcRow = bmpData.data() + y * scanlineBytes;
        uint8_t* dstRow = dst + y * screenWidth_ * 3;
        
        for (int x = 0; x < screenWidth_; ++x) {
            // BGR -> RGB
            dstRow[x * 3 + 0] = srcRow[x * 3 + 2];  // R
            dstRow[x * 3 + 1] = srcRow[x * 3 + 1];  // G
            dstRow[x * 3 + 2] = srcRow[x * 3 + 0];  // B
        }
    }
    
    return true;
}

void ScreenCapture::ResizeFrame(const uint8_t* src, int srcWidth, int srcHeight,
                                uint8_t* dst, int dstWidth, int dstHeight) {
    // Bilinear interpolation for smooth downscaling
    const float xRatio = static_cast<float>(srcWidth) / dstWidth;
    const float yRatio = static_cast<float>(srcHeight) / dstHeight;
    
    for (int y = 0; y < dstHeight; ++y) {
        const float srcY = y * yRatio;
        const int y0 = static_cast<int>(srcY);
        const int y1 = (std::min)(y0 + 1, srcHeight - 1);
        const float yFrac = srcY - y0;
        
        for (int x = 0; x < dstWidth; ++x) {
            const float srcX = x * xRatio;
            const int x0 = static_cast<int>(srcX);
            const int x1 = (std::min)(x0 + 1, srcWidth - 1);
            const float xFrac = srcX - x0;
            
            // Bilinear interpolation for each channel
            for (int c = 0; c < 3; ++c) {
                const float c00 = src[(y0 * srcWidth + x0) * 3 + c];
                const float c10 = src[(y0 * srcWidth + x1) * 3 + c];
                const float c01 = src[(y1 * srcWidth + x0) * 3 + c];
                const float c11 = src[(y1 * srcWidth + x1) * 3 + c];
                
                const float c0 = c00 * (1 - xFrac) + c10 * xFrac;
                const float c1 = c01 * (1 - xFrac) + c11 * xFrac;
                const float value = c0 * (1 - yFrac) + c1 * yFrac;
                
                dst[(y * dstWidth + x) * 3 + c] = static_cast<uint8_t>(value);
            }
        }
    }
}

std::vector<std::wstring> ScreenCapture::GetAvailableWindows() {
    std::vector<std::wstring> windows;
    
    EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
        auto* windows = reinterpret_cast<std::vector<std::wstring>*>(lParam);
        
        if (!IsWindowVisible(hwnd)) return TRUE;
        
        int length = GetWindowTextLengthW(hwnd);
        if (length == 0) return TRUE;
        
        std::wstring title(length + 1, L'\0');
        GetWindowTextW(hwnd, &title[0], length + 1);
        title.resize(length);
        
        if (!title.empty()) {
            windows->push_back(title);
        }
        
        return TRUE;
    }, reinterpret_cast<LPARAM>(&windows));
    
    return windows;
}

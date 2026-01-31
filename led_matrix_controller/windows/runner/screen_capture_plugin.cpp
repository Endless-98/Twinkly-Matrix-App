#include "screen_capture_plugin.h"
#include <windows.h>
#include <sstream>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

void ScreenCapturePlugin::Register(flutter::PluginRegistrarWindows* registrar) {
    auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), 
        "com.twinklywall.led_matrix_controller/screen_capture",
        &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ScreenCapturePlugin>(std::move(channel));

    plugin->channel_->SetMethodCallHandler(
        [plugin_ptr = plugin.get()](const auto& call, auto result) {
            plugin_ptr->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
}

ScreenCapturePlugin::ScreenCapturePlugin(
    std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel)
    : channel_(std::move(channel)), capture_(std::make_unique<ScreenCapture>()) {}

ScreenCapturePlugin::~ScreenCapturePlugin() {
    if (capture_) {
        capture_->StopCapture();
    }
}

void ScreenCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    
    const std::string& method = method_call.method_name();
    
    if (method == "initialize") {
        bool success = capture_->Initialize();
        result->Success(EncodableValue(success));
    }
    else if (method == "startScreenCapture") {
        // Get target dimensions from arguments if provided
        int targetWidth = 90;
        int targetHeight = 50;
        
        if (const auto* args = std::get_if<EncodableMap>(method_call.arguments())) {
            auto widthIt = args->find(EncodableValue("width"));
            auto heightIt = args->find(EncodableValue("height"));
            
            if (widthIt != args->end() && std::holds_alternative<int>(widthIt->second)) {
                targetWidth = std::get<int>(widthIt->second);
            }
            if (heightIt != args->end() && std::holds_alternative<int>(heightIt->second)) {
                targetHeight = std::get<int>(heightIt->second);
            }
        }
        
        bool success = capture_->StartCapture(targetWidth, targetHeight);
        result->Success(EncodableValue(success));
    }
    else if (method == "stopScreenCapture") {
        capture_->StopCapture();
        result->Success(EncodableValue(true));
    }
    else if (method == "captureScreenshot" || method == "getLatestFrame") {
        if (!capture_->IsCapturing()) {
            result->Success(EncodableValue(EncodableList()));
            return;
        }
        
        std::vector<uint8_t> frame = capture_->GetLatestFrame();
        
        if (frame.empty()) {
            result->Success(EncodableValue(EncodableList()));
        } else {
            // Convert to EncodableList of uint8_t values
            result->Success(EncodableValue(frame));
        }
    }
    else if (method == "isCapturing") {
        result->Success(EncodableValue(capture_->IsCapturing()));
    }
    else if (method == "getScreenDimensions") {
        EncodableMap dimensions;
        dimensions[EncodableValue("width")] = EncodableValue(capture_->GetScreenWidth());
        dimensions[EncodableValue("height")] = EncodableValue(capture_->GetScreenHeight());
        result->Success(EncodableValue(dimensions));
    }
    else if (method == "getCapabilities") {
        EncodableMap capabilities;
        capabilities[EncodableValue("supportsDesktopCapture")] = EncodableValue(true);
        capabilities[EncodableValue("supportsWindowCapture")] = EncodableValue(false); // TODO
        capabilities[EncodableValue("supportsRegionCapture")] = EncodableValue(false); // TODO
        capabilities[EncodableValue("requiresPermission")] = EncodableValue(false);
        capabilities[EncodableValue("hardwareAccelerated")] = EncodableValue(capture_->IsHardwareAccelerated());
        capabilities[EncodableValue("captureMethod")] = EncodableValue(
            capture_->IsHardwareAccelerated() ? "Desktop Duplication API" : "GDI BitBlt");
        result->Success(EncodableValue(capabilities));
    }
    else if (method == "getAvailableWindows") {
        std::vector<std::wstring> windows = ScreenCapture::GetAvailableWindows();
        EncodableList windowList;
        
        for (const auto& title : windows) {
            // Convert wstring to string
            std::string narrowTitle;
            narrowTitle.reserve(title.size());
            for (wchar_t ch : title) {
                narrowTitle.push_back(static_cast<char>(ch < 256 ? ch : '?'));
            }
            windowList.push_back(EncodableValue(narrowTitle));
        }
        
        result->Success(EncodableValue(windowList));
    }
    else {
        result->NotImplemented();
    }
}

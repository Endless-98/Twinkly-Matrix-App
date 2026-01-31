#ifndef RUNNER_SCREEN_CAPTURE_PLUGIN_H_
#define RUNNER_SCREEN_CAPTURE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include "screen_capture.h"

class ScreenCapturePlugin {
public:
    static void Register(flutter::PluginRegistrarWindows* registrar);

private:
    ScreenCapturePlugin(
        std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel);
    ~ScreenCapturePlugin();

    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& method_call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
    std::unique_ptr<ScreenCapture> capture_;
};

#endif  // RUNNER_SCREEN_CAPTURE_PLUGIN_H_

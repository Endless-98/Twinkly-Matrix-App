#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // ---- keep-alive: hide minimize / focus-loss from the Flutter engine --------
  //
  // Flutter's Windows embedder reacts to two messages that throttle or pause
  // the Dart event loop:
  //
  // 1. WM_SIZE  with SIZE_MINIMIZED → engine lifecycle becomes "hidden"
  //    → Dart timers / futures / microtasks stop completely.
  //
  // 2. WM_ACTIVATE with WA_INACTIVE → engine lifecycle becomes "inactive"
  //    → Dart event loop is throttled to ~5 FPS.
  //
  // Both kill the background screen-capture loop that must run at 20+ FPS.
  //
  // Fix: intercept these messages BEFORE HandleTopLevelWindowProc sees them.
  // The window still minimizes / deactivates visually (these are notifications,
  // not requests), but Flutter keeps running as if it were focused and visible.
  // SIZE_RESTORED, SIZE_MAXIMIZED, and WA_ACTIVE / WA_CLICKACTIVE pass through
  // normally so rendering and focus behaviour resume correctly.

  // (a) Minimized → swallow entirely
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
    return 0;
  }

  // (b) Focus lost → skip Flutter's handler but let the base Win32Window still
  //     process the message (it sets keyboard focus on the child content).
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }
  // ---- end keep-alive -------------------------------------------------------

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

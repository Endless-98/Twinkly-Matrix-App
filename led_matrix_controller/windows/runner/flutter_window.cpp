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
  // ---- keep-alive: hide ALL minimize / focus-loss events from Flutter --------
  //
  // Flutter's Windows embedder throttles or pauses the Dart event loop when
  // it detects these window messages:
  //
  //   WM_SIZE(SIZE_MINIMIZED)   → engine lifecycle "hidden"  → Dart stops
  //   WM_ACTIVATE(WA_INACTIVE)  → engine lifecycle "inactive" → 5 FPS throttle
  //   WM_ACTIVATEAPP(FALSE)     → also signals deactivation
  //
  // Any of these kill the 20+ FPS background screen-capture loop.
  //
  // Fix: swallow ALL of them before HandleTopLevelWindowProc or ANY child
  // window sees them.  We must NOT route to Win32Window::MessageHandler
  // either, because its WM_ACTIVATE handler calls SetFocus(child_content_)
  // which generates WM_KILLFOCUS on the Flutter child view — and the engine
  // processes that internally to trigger the same lifecycle transition.
  //
  // The window still minimizes/deactivates visually (these are post-hoc
  // notifications).  SIZE_RESTORED / WA_ACTIVE / WA_CLICKACTIVE pass through
  // normally so rendering and focus resume on restore.

  // (a) Window minimized
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
    return 0;
  }

  // (b) Window deactivated (focus lost to another window)
  if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    return 0;
  }

  // (c) Application deactivated (another app came to foreground)
  if (message == WM_ACTIVATEAPP && wparam == FALSE) {
    return 0;
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

#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

// ---- keep-alive: Flutter child view subclass ----
// The Flutter engine transitions to "inactive" (5 FPS throttle) when the
// child view window receives WM_KILLFOCUS.  Swallowing WM_ACTIVATE on the
// top-level window doesn't help because Windows sends WM_KILLFOCUS directly
// to the previously-focused child.  We subclass the child's WndProc to
// intercept it.
WNDPROC FlutterWindow::original_flutter_view_proc_ = nullptr;

LRESULT CALLBACK FlutterWindow::FlutterViewSubclassProc(
    HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_KILLFOCUS) {
    // Swallow: Flutter engine never learns focus was lost → stays
    // in "resumed" lifecycle → Dart event loop runs at full speed.
    return 0;
  }
  return CallWindowProcW(original_flutter_view_proc_, hwnd, msg, wparam, lparam);
}
// ---- end keep-alive ---------------------------------------------------------

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

  // Subclass the Flutter view to intercept WM_KILLFOCUS (see comment above)
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  original_flutter_view_proc_ = reinterpret_cast<WNDPROC>(
      SetWindowLongPtrW(flutter_view, GWLP_WNDPROC,
                        reinterpret_cast<LONG_PTR>(FlutterViewSubclassProc)));

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
  // Restore original WndProc before Flutter view is destroyed
  if (original_flutter_view_proc_ && flutter_controller_ &&
      flutter_controller_->view()) {
    HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
    if (flutter_view) {
      SetWindowLongPtrW(flutter_view, GWLP_WNDPROC,
                        reinterpret_cast<LONG_PTR>(original_flutter_view_proc_));
    }
    original_flutter_view_proc_ = nullptr;
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // ---- keep-alive: prevent "hidden" lifecycle on minimize --------------------
  // Flutter's embedder transitions to "hidden" (Dart fully paused) when it
  // sees WM_SIZE(SIZE_MINIMIZED) via HandleTopLevelWindowProc.  Swallow it
  // so the engine keeps running.  The actual focus-loss throttle ("inactive")
  // is handled by the child-view WM_KILLFOCUS subclass (see OnCreate).
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
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

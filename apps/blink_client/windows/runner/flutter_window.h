#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that hosts a Flutter view without prematurely flashing or stealing
// focus on startup, and forwards Windows shell TaskbarCreated broadcasts to
// Dart so system tray icons survive Explorer restarts.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Channel notifying Dart of native shell events such as TaskbarCreated.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_shell_channel_;

  // Registered Windows message ID for Explorer taskbar creation broadcasts.
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

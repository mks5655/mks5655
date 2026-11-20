#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // 1. Get DPI scale factor (100% = 1.0, 150% = 1.5)
  UINT dpi = ::GetDpiForSystem();
  double scale = static_cast<double>(dpi) / 96.0;

  // 2. Set target logical size (Optimized for 150% DPI display)
  int logicalWidth = 1000;
  int logicalHeight = 640;

  // 3. Convert physical screen resolution to logical resolution
  int physicalScreenWidth = ::GetSystemMetrics(SM_CXSCREEN);
  int physicalScreenHeight = ::GetSystemMetrics(SM_CYSCREEN);

  int logicalScreenWidth = static_cast<int>(physicalScreenWidth / scale);
  int logicalScreenHeight = static_cast<int>(physicalScreenHeight / scale);

  // 4. Calculate centered logical origin
  int originX = (logicalScreenWidth - logicalWidth) / 2;
  int originY = (logicalScreenHeight - logicalHeight) / 2;

  Win32Window::Size size(logicalWidth, logicalHeight);
  Win32Window::Point origin(originX, originY);

  if (!window.Create(L"PCloud", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
#include <objbase.h>
#include <windows.h>

#include "engine.h"

namespace {
constexpr UINT kTriggerMessage = WM_APP + 1;
ruswitcher::Engine* g_engine{};

LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) noexcept {
    if (message == kTriggerMessage && g_engine) {
        g_engine->convert_or_undo();
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

// Migration target for the compact native Windows client. The C# beta remains the behavioural
// oracle until hook, conversion, tray, clipboard and settings scenarios pass here one by one.
int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    HANDLE single_instance = CreateMutexW(nullptr, TRUE, L"Local\\RuSwitcher");
    if (!single_instance || GetLastError() == ERROR_ALREADY_EXISTS) {
        if (single_instance) CloseHandle(single_instance);
        return 0;
    }

    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    const wchar_t class_name[] = L"RuSwitcher.Native.MessageWindow";
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    if (!RegisterClassW(&window_class)) {
        if (SUCCEEDED(com)) CoUninitialize();
        CloseHandle(single_instance);
        return 1;
    }

    const HWND window = CreateWindowExW(0, class_name, L"RuSwitcher", 0, 0, 0, 0, 0,
                                        HWND_MESSAGE, nullptr, instance, nullptr);
    if (!window) {
        if (SUCCEEDED(com)) CoUninitialize();
        CloseHandle(single_instance);
        return 1;
    }

    ruswitcher::Engine engine(window);
    g_engine = &engine;
    if (!engine.install()) {
        MessageBoxW(nullptr, L"RuSwitcher could not install the input hooks.", L"RuSwitcher",
                    MB_OK | MB_ICONERROR);
        g_engine = nullptr;
        DestroyWindow(window);
        if (SUCCEEDED(com)) CoUninitialize();
        CloseHandle(single_instance);
        return 1;
    }

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    g_engine = nullptr;
    DestroyWindow(window);
    if (SUCCEEDED(com)) CoUninitialize();
    ReleaseMutex(single_instance);
    CloseHandle(single_instance);
    return 0;
}

#include "diagnostics.h"

#include <windows.h>

namespace ruswitcher {

void log_event(const wchar_t* message) noexcept {
    wchar_t directory[MAX_PATH]{};
    const DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", directory, MAX_PATH);
    if (!length || length >= MAX_PATH - 32) return;
    lstrcatW(directory, L"\\RuSwitcher");
    CreateDirectoryW(directory, nullptr);
    lstrcatW(directory, L"\\native.log");

    const HANDLE file = CreateFileW(directory, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;

    SYSTEMTIME time{};
    GetLocalTime(&time);
    wchar_t line[320]{};
    wsprintfW(line, L"%02u:%02u:%02u.%03u %s\r\n", time.wHour, time.wMinute,
              time.wSecond, time.wMilliseconds, message ? message : L"");
    DWORD written{};
    WriteFile(file, line, static_cast<DWORD>(lstrlenW(line) * sizeof(wchar_t)), &written, nullptr);
    CloseHandle(file);
}

}  // namespace ruswitcher

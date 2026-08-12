#pragma once

#include <windows.h>

namespace ruswitcher {
class Engine;
class Settings;

class Tray {
public:
    Tray(HWND window, HINSTANCE instance, Engine& engine, Settings& settings) noexcept;
    ~Tray();

    bool show() noexcept;
    bool handle(UINT message, WPARAM wparam, LPARAM lparam, LRESULT& result) noexcept;

private:
    struct Impl;
    Impl* impl_;
};
}  // namespace ruswitcher

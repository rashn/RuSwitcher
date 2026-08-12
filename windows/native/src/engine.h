#pragma once

#include <windows.h>

namespace ruswitcher {

class Engine {
public:
    explicit Engine(HWND message_window) noexcept;
    ~Engine();

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    bool install() noexcept;
    void convert_or_undo() noexcept;

private:
    struct Impl;
    Impl* impl_;
};

}  // namespace ruswitcher

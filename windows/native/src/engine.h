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
    void convert_line() noexcept;
    void set_enabled(bool enabled) noexcept;
    bool enabled() const noexcept;
    void set_layout_pair(HKL first, HKL second) noexcept;
    void remember_foreground() noexcept;

private:
    struct Impl;
    Impl* impl_;
};

}  // namespace ruswitcher

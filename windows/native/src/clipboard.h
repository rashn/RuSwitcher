#pragma once

#include <windows.h>

#include <string>

namespace ruswitcher {

class ClipboardSnapshot {
public:
    ClipboardSnapshot() noexcept;
    ~ClipboardSnapshot();

    ClipboardSnapshot(const ClipboardSnapshot&) = delete;
    ClipboardSnapshot& operator=(const ClipboardSnapshot&) = delete;

    bool capture() noexcept;
    bool restore() noexcept;

private:
    struct Impl;
    Impl* impl_;
};

bool copy_current_selection(std::wstring& text) noexcept;

}  // namespace ruswitcher

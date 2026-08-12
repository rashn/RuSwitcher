#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace ruswitcher {

struct LayoutChoice {
    HKL handle{};
    std::wstring name;
};

class Settings {
public:
    Settings() noexcept;

    bool enabled() const noexcept { return enabled_; }
    void set_enabled(bool value) noexcept;

    HKL first_layout() const noexcept { return first_layout_; }
    HKL second_layout() const noexcept { return second_layout_; }
    void set_first_layout(HKL value) noexcept;
    void set_second_layout(HKL value) noexcept;

    const std::vector<LayoutChoice>& layouts() const noexcept { return layouts_; }

    bool autostart_enabled() const noexcept;
    bool set_autostart(bool enabled) noexcept;

private:
    std::vector<LayoutChoice> layouts_;
    bool enabled_{true};
    HKL first_layout_{};
    HKL second_layout_{};

    void save_layout(const wchar_t* name, HKL value) noexcept;
};

}  // namespace ruswitcher

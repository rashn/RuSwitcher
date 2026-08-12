#include "settings.h"

#include <vector>

namespace ruswitcher {
namespace {

constexpr wchar_t kSettingsKey[] = L"Software\\RuSwitcher";
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"RuSwitcher";

HKEY open_settings(REGSAM access) noexcept {
    HKEY key{};
    return RegCreateKeyExW(HKEY_CURRENT_USER, kSettingsKey, 0, nullptr, 0, access, nullptr,
                           &key, nullptr) == ERROR_SUCCESS
               ? key
               : nullptr;
}

ULONG_PTR read_layout(HKEY key, const wchar_t* name) noexcept {
    ULONGLONG value{};
    DWORD type{};
    DWORD size = sizeof(value);
    return RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(&value), &size) ==
                       ERROR_SUCCESS &&
                   type == REG_QWORD
               ? static_cast<ULONG_PTR>(value)
               : 0;
}

HKL match_layout(ULONG_PTR saved, const std::vector<LayoutChoice>& layouts) noexcept {
    if (!saved) return nullptr;
    for (const auto& layout : layouts) {
        const ULONG_PTR raw = reinterpret_cast<ULONG_PTR>(layout.handle);
        if (raw == saved || static_cast<DWORD>(raw) == static_cast<DWORD>(saved))
            return layout.handle;
    }
    return nullptr;
}

std::wstring layout_name(HKL layout) {
    const LANGID language = LOWORD(reinterpret_cast<ULONG_PTR>(layout));
    wchar_t locale_name[LOCALE_NAME_MAX_LENGTH]{};
    wchar_t display_name[128]{};
    if (LCIDToLocaleName(MAKELCID(language, SORT_DEFAULT), locale_name,
                         LOCALE_NAME_MAX_LENGTH, 0) &&
        GetLocaleInfoEx(locale_name, LOCALE_SLOCALIZEDDISPLAYNAME, display_name,
                        static_cast<int>(std::size(display_name))))
        return display_name;
    return L"Keyboard layout";
}

}  // namespace

Settings::Settings() noexcept {
    const int count = GetKeyboardLayoutList(0, nullptr);
    if (count > 0) {
        std::vector<HKL> handles(static_cast<std::size_t>(count));
        const int actual = GetKeyboardLayoutList(count, handles.data());
        for (int index = 0; index < actual; ++index)
            layouts_.push_back({handles[static_cast<std::size_t>(index)],
                                layout_name(handles[static_cast<std::size_t>(index)])});
    }

    HKEY key = open_settings(KEY_QUERY_VALUE);
    ULONG_PTR saved_first{};
    ULONG_PTR saved_second{};
    if (key) {
        DWORD enabled_value = 1;
        DWORD type{};
        DWORD size = sizeof(enabled_value);
        if (RegQueryValueExW(key, L"Enabled", nullptr, &type,
                            reinterpret_cast<BYTE*>(&enabled_value), &size) == ERROR_SUCCESS &&
            type == REG_DWORD)
            enabled_ = enabled_value != 0;
        saved_first = read_layout(key, L"FirstLayout");
        saved_second = read_layout(key, L"SecondLayout");
        RegCloseKey(key);
    }

    first_layout_ = match_layout(saved_first, layouts_);
    second_layout_ = match_layout(saved_second, layouts_);
    if (!first_layout_) {
        for (const auto& layout : layouts_)
            if (PRIMARYLANGID(LOWORD(reinterpret_cast<ULONG_PTR>(layout.handle))) == LANG_ENGLISH) {
                first_layout_ = layout.handle;
                break;
            }
    }
    if (!first_layout_ && !layouts_.empty()) first_layout_ = layouts_[0].handle;
    if (!second_layout_) {
        for (const auto& layout : layouts_)
            if (layout.handle != first_layout_ &&
                PRIMARYLANGID(LOWORD(reinterpret_cast<ULONG_PTR>(layout.handle))) == LANG_RUSSIAN) {
                second_layout_ = layout.handle;
                break;
            }
    }
    if (!second_layout_)
        for (const auto& layout : layouts_)
            if (layout.handle != first_layout_) {
                second_layout_ = layout.handle;
                break;
            }
}

void Settings::set_enabled(bool value) noexcept {
    enabled_ = value;
    HKEY key = open_settings(KEY_SET_VALUE);
    if (!key) return;
    const DWORD stored = value ? 1 : 0;
    RegSetValueExW(key, L"Enabled", 0, REG_DWORD, reinterpret_cast<const BYTE*>(&stored),
                   sizeof(stored));
    RegCloseKey(key);
}

void Settings::save_layout(const wchar_t* name, HKL value) noexcept {
    HKEY key = open_settings(KEY_SET_VALUE);
    if (!key) return;
    const ULONGLONG stored = reinterpret_cast<ULONG_PTR>(value);
    RegSetValueExW(key, name, 0, REG_QWORD, reinterpret_cast<const BYTE*>(&stored),
                   sizeof(stored));
    RegCloseKey(key);
}

void Settings::set_first_layout(HKL value) noexcept {
    if (!value || value == second_layout_) return;
    first_layout_ = value;
    save_layout(L"FirstLayout", value);
}

void Settings::set_second_layout(HKL value) noexcept {
    if (!value || value == first_layout_) return;
    second_layout_ = value;
    save_layout(L"SecondLayout", value);
}

bool Settings::autostart_enabled() const noexcept {
    HKEY key{};
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
        return false;
    DWORD size{};
    const bool exists = RegQueryValueExW(key, kRunValue, nullptr, nullptr, nullptr, &size) ==
                        ERROR_SUCCESS;
    RegCloseKey(key);
    return exists;
}

bool Settings::set_autostart(bool enabled) noexcept {
    HKEY key{};
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS)
        return false;
    LONG result{};
    if (enabled) {
        wchar_t path[MAX_PATH]{};
        if (!GetModuleFileNameW(nullptr, path, MAX_PATH)) {
            RegCloseKey(key);
            return false;
        }
        std::wstring command = L"\"" + std::wstring(path) + L"\"";
        result = RegSetValueExW(key, kRunValue, 0, REG_SZ,
                                reinterpret_cast<const BYTE*>(command.c_str()),
                                static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    } else {
        result = RegDeleteValueW(key, kRunValue);
        if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

}  // namespace ruswitcher

#include "tray.h"

#include "engine.h"
#include "settings.h"

#include <shellapi.h>

namespace ruswitcher {
namespace {
constexpr UINT kTrayMessage = WM_APP + 2;
constexpr UINT kCommandEnabled = 100;
constexpr UINT kCommandLine = 101;
constexpr UINT kCommandAutostart = 102;
constexpr UINT kCommandAbout = 103;
constexpr UINT kCommandExit = 104;
constexpr UINT kFirstLayoutBase = 200;
constexpr UINT kSecondLayoutBase = 300;
constexpr UINT kIconId = 1;

UINT checked(bool value) noexcept { return MF_STRING | (value ? MF_CHECKED : MF_UNCHECKED); }
}

struct Tray::Impl {
    HWND window{};
    HINSTANCE instance{};
    Engine& engine;
    Settings& settings;
    NOTIFYICONDATAW icon{};
    UINT taskbar_created{};
    bool visible{};

    Impl(HWND owner, HINSTANCE module, Engine& input, Settings& preferences) noexcept
        : window(owner), instance(module), engine(input), settings(preferences) {}

    bool add() noexcept {
        icon = {};
        icon.cbSize = sizeof(icon);
        icon.hWnd = window;
        icon.uID = 1;
        icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        icon.uCallbackMessage = kTrayMessage;
        icon.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(kIconId));
        if (!icon.hIcon) icon.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
        lstrcpynW(icon.szTip, engine.enabled() ? L"RuSwitcher — active" : L"RuSwitcher — paused",
                  static_cast<int>(std::size(icon.szTip)));
        visible = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
        if (visible) {
            icon.uVersion = NOTIFYICON_VERSION_4;
            Shell_NotifyIconW(NIM_SETVERSION, &icon);
        }
        return visible;
    }

    void refresh() noexcept {
        if (!visible) return;
        icon.uFlags = NIF_TIP;
        lstrcpynW(icon.szTip, engine.enabled() ? L"RuSwitcher — active" : L"RuSwitcher — paused",
                  static_cast<int>(std::size(icon.szTip)));
        Shell_NotifyIconW(NIM_MODIFY, &icon);
    }

    void show_menu() noexcept {
        engine.remember_foreground();
        const HMENU menu = CreatePopupMenu();
        const HMENU first = CreatePopupMenu();
        const HMENU second = CreatePopupMenu();
        if (!menu || !first || !second) return;

        AppendMenuW(menu, checked(engine.enabled()), kCommandEnabled, L"Enabled");
        AppendMenuW(menu, MF_STRING, kCommandLine, L"Convert current line");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

        const auto& layouts = settings.layouts();
        for (std::size_t index = 0; index < layouts.size() && index < 90; ++index) {
            AppendMenuW(first, checked(layouts[index].handle == settings.first_layout()),
                        kFirstLayoutBase + static_cast<UINT>(index), layouts[index].name.c_str());
            AppendMenuW(second, checked(layouts[index].handle == settings.second_layout()),
                        kSecondLayoutBase + static_cast<UINT>(index), layouts[index].name.c_str());
        }
        AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(first), L"First layout");
        AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(second), L"Second layout");
        AppendMenuW(menu, checked(settings.autostart_enabled()), kCommandAutostart,
                    L"Launch at sign-in");
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, kCommandAbout, L"About RuSwitcher");
        AppendMenuW(menu, MF_STRING, kCommandExit, L"Exit");

        POINT point{};
        GetCursorPos(&point);
        SetForegroundWindow(window);
        TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, point.x, point.y, 0, window,
                       nullptr);
        PostMessageW(window, WM_NULL, 0, 0);
        DestroyMenu(menu);
    }

    void command(UINT id) noexcept {
        if (id == kCommandEnabled) {
            const bool value = !engine.enabled();
            engine.set_enabled(value);
            settings.set_enabled(value);
            refresh();
        } else if (id == kCommandLine) {
            engine.convert_line();
        } else if (id == kCommandAutostart) {
            settings.set_autostart(!settings.autostart_enabled());
        } else if (id == kCommandAbout) {
            MessageBoxW(nullptr,
                        L"RuSwitcher native beta\n\nDouble-tap Ctrl: fix the last word or selected text.\n"
                        L"Zero third-party runtime dependencies.",
                        L"RuSwitcher", MB_OK | MB_ICONINFORMATION);
        } else if (id == kCommandExit) {
            PostQuitMessage(0);
        } else if (id >= kFirstLayoutBase && id < kFirstLayoutBase + 90) {
            const std::size_t index = id - kFirstLayoutBase;
            if (index < settings.layouts().size()) {
                settings.set_first_layout(settings.layouts()[index].handle);
                engine.set_layout_pair(settings.first_layout(), settings.second_layout());
            }
        } else if (id >= kSecondLayoutBase && id < kSecondLayoutBase + 90) {
            const std::size_t index = id - kSecondLayoutBase;
            if (index < settings.layouts().size()) {
                settings.set_second_layout(settings.layouts()[index].handle);
                engine.set_layout_pair(settings.first_layout(), settings.second_layout());
            }
        }
    }

    ~Impl() {
        if (visible) Shell_NotifyIconW(NIM_DELETE, &icon);
    }
};

Tray::Tray(HWND window, HINSTANCE instance, Engine& engine, Settings& settings) noexcept
    : impl_(new Impl(window, instance, engine, settings)) {
    impl_->taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
}
Tray::~Tray() { delete impl_; }
bool Tray::show() noexcept { return impl_->add(); }
bool Tray::handle(UINT message, WPARAM wparam, LPARAM lparam, LRESULT& result) noexcept {
    if (message == impl_->taskbar_created) {
        impl_->visible = false;
        impl_->add();
        result = 0;
        return true;
    }
    if (message == kTrayMessage) {
        const UINT event = LOWORD(lparam);
        if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP || event == WM_LBUTTONUP)
            impl_->show_menu();
        result = 0;
        return true;
    }
    if (message == WM_COMMAND) {
        impl_->command(LOWORD(wparam));
        result = 0;
        return true;
    }
    return false;
}
}  // namespace ruswitcher

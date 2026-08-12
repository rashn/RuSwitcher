#include "engine.h"

#include "input_safety.h"

#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace ruswitcher {
namespace {

constexpr ULONG_PTR kInjectedMarker = 0x52555357;
constexpr UINT kTriggerMessage = WM_APP + 1;
constexpr ULONGLONG kDoubleTapWindowMs = 350;

struct TypedKey {
    DWORD vk;
    DWORD scan;
    bool shift;
    bool caps;
};

bool is_control(DWORD vk) noexcept {
    return vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL;
}

bool is_typing_key(DWORD vk) noexcept {
    return (vk >= '0' && vk <= '9') || (vk >= 'A' && vk <= 'Z') ||
           (vk >= VK_OEM_1 && vk <= VK_OEM_3) ||
           (vk >= VK_OEM_4 && vk <= VK_OEM_8) || vk == VK_OEM_102;
}

bool is_boundary(DWORD vk) noexcept {
    return vk == VK_SPACE || vk == VK_RETURN || vk == VK_TAB || vk == VK_ESCAPE;
}

bool invalidates_buffer(DWORD vk) noexcept {
    switch (vk) {
        case VK_DELETE:
        case VK_INSERT:
        case VK_HOME:
        case VK_END:
        case VK_LEFT:
        case VK_UP:
        case VK_RIGHT:
        case VK_DOWN:
        case VK_PRIOR:
        case VK_NEXT:
            return true;
        default:
            return false;
    }
}

bool shortcut_modifier_down() noexcept {
    return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_MENU) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
}

HKL current_layout() noexcept {
    const HWND foreground = GetForegroundWindow();
    const DWORD thread = GetWindowThreadProcessId(foreground, nullptr);
    return GetKeyboardLayout(thread);
}

HKL opposite_layout(HKL current) noexcept {
    const int count = GetKeyboardLayoutList(0, nullptr);
    if (count <= 1) return nullptr;

    std::vector<HKL> layouts(static_cast<std::size_t>(count));
    const int copied = GetKeyboardLayoutList(count, layouts.data());
    for (int index = 0; index < copied; ++index) {
        if (layouts[static_cast<std::size_t>(index)] != current)
            return layouts[static_cast<std::size_t>(index)];
    }
    return nullptr;
}

bool translate_key(const TypedKey& key, HKL layout, wchar_t& character) noexcept {
    std::array<BYTE, 256> state{};
    if (key.shift) state[VK_SHIFT] = 0x80;
    if (key.caps) state[VK_CAPITAL] = 0x01;

    wchar_t output[8]{};
    const int length = ToUnicodeEx(key.vk, key.scan, state.data(), output,
                                   static_cast<int>(std::size(output)), 0x4, layout);
    if (length < 1) return false;
    character = output[0];
    return true;
}

bool translate_keys(const std::vector<TypedKey>& keys, std::size_t count, HKL layout,
                    std::wstring& text) {
    text.clear();
    text.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        wchar_t character{};
        if (!translate_key(keys[index], layout, character)) return false;
        text.push_back(character);
    }
    return true;
}

bool is_trailing_punctuation(wchar_t character) noexcept {
    switch (character) {
        case L',':
        case L'.':
        case L'!':
        case L'?':
        case L';':
        case L':':
        case L')':
            return true;
        default:
            return false;
    }
}

INPUT key_input(WORD vk, WORD scan, DWORD flags) noexcept {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vk;
    input.ki.wScan = scan;
    input.ki.dwFlags = flags;
    input.ki.dwExtraInfo = kInjectedMarker;
    return input;
}

bool replace_text(std::size_t characters_to_delete, const std::wstring& replacement) {
    std::vector<INPUT> inputs;
    inputs.reserve((characters_to_delete + replacement.size()) * 2);

    for (std::size_t index = 0; index < characters_to_delete; ++index) {
        inputs.push_back(key_input(VK_BACK, 0, 0));
        inputs.push_back(key_input(VK_BACK, 0, KEYEVENTF_KEYUP));
    }
    for (const wchar_t character : replacement) {
        inputs.push_back(key_input(0, static_cast<WORD>(character), KEYEVENTF_UNICODE));
        inputs.push_back(
            key_input(0, static_cast<WORD>(character), KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    }

    if (inputs.empty()) return false;
    const UINT sent = SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    return sent == inputs.size();
}

void switch_layout(HKL layout) noexcept {
    const HWND foreground = GetForegroundWindow();
    if (foreground)
        PostMessageW(foreground, WM_INPUTLANGCHANGEREQUEST, 0,
                     reinterpret_cast<LPARAM>(layout));
}

}  // namespace

struct Engine::Impl {
    explicit Impl(HWND window) noexcept : message_window(window) {}

    HWND message_window{};
    HHOOK keyboard_hook{};
    HHOOK mouse_hook{};
    HWINEVENTHOOK foreground_hook{};
    HWINEVENTHOOK focus_hook{};
    std::vector<TypedKey> word;
    HWND word_owner{};

    bool control_down{};
    bool other_during_control{};
    ULONGLONG last_control_tap{};

    bool undo_available{};
    std::wstring screen_text;
    std::wstring alternate_text;
    HKL screen_layout{};
    HKL alternate_layout{};

    static Impl* instance;

    void clear_word() noexcept {
        word.clear();
        word_owner = nullptr;
    }

    void clear_all() noexcept {
        clear_word();
        undo_available = false;
        screen_text.clear();
        alternate_text.clear();
    }

    void on_key_down(DWORD vk, DWORD scan) {
        if (is_control(vk)) {
            if (!control_down) {
                control_down = true;
                other_during_control = false;
            }
            return;
        }

        if (control_down) other_during_control = true;
        last_control_tap = 0;

        if (vk == VK_BACK) {
            undo_available = false;
            if (shortcut_modifier_down()) {
                clear_word();
            } else if (!word.empty()) {
                word.pop_back();
                if (word.empty()) word_owner = nullptr;
            }
            return;
        }

        if (is_boundary(vk)) {
            clear_word();
            undo_available = false;
            return;
        }

        if (is_typing_key(vk)) {
            if (shortcut_modifier_down()) {
                clear_all();
                return;
            }
            const HWND foreground = GetForegroundWindow();
            if (word_owner && foreground != word_owner) clear_word();
            if (word.empty()) word_owner = foreground;

            const bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
            const bool caps = (GetKeyState(VK_CAPITAL) & 0x0001) != 0;
            word.push_back(TypedKey{vk, scan, shift, caps});
            undo_available = false;
        } else if (invalidates_buffer(vk)) {
            clear_all();
        }
    }

    void on_key_up(DWORD vk) noexcept {
        if (!is_control(vk)) return;
        const bool tap = control_down && !other_during_control;
        control_down = false;
        other_during_control = false;
        if (!tap) return;

        const ULONGLONG now = GetTickCount64();
        if (last_control_tap && now - last_control_tap <= kDoubleTapWindowMs) {
            last_control_tap = 0;
            PostMessageW(message_window, kTriggerMessage, 0, 0);
        } else {
            last_control_tap = now;
        }
    }

    static LRESULT CALLBACK keyboard_proc(int code, WPARAM message, LPARAM data) noexcept {
        if (code == HC_ACTION && instance) {
            const auto* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
            if (key->dwExtraInfo != kInjectedMarker) {
                if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)
                    instance->on_key_down(key->vkCode, key->scanCode);
                else if (message == WM_KEYUP || message == WM_SYSKEYUP)
                    instance->on_key_up(key->vkCode);
            }
        }
        return CallNextHookEx(instance ? instance->keyboard_hook : nullptr, code, message, data);
    }

    static LRESULT CALLBACK mouse_proc(int code, WPARAM message, LPARAM data) noexcept {
        if (code == HC_ACTION && instance &&
            (message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN ||
             message == WM_MBUTTONDOWN)) {
            instance->clear_all();
        }
        return CallNextHookEx(instance ? instance->mouse_hook : nullptr, code, message, data);
    }

    static void CALLBACK window_event_proc(HWINEVENTHOOK, DWORD event, HWND window, LONG,
                                           LONG, DWORD, DWORD) noexcept {
        if (!instance) return;
        if (event == EVENT_SYSTEM_FOREGROUND) {
            instance->clear_all();
            return;
        }

        // Tab can move between two fields without a mouse click or a foreground-window change.
        // Only accept focus events that belong to the active top-level window; background UIA
        // traffic must not invalidate a word the user is currently typing elsewhere.
        if (event == EVENT_OBJECT_FOCUS && window) {
            const HWND root = GetAncestor(window, GA_ROOT);
            if (root && root == GetForegroundWindow()) instance->clear_all();
        }
    }

    bool install() noexcept {
        instance = this;
        const HINSTANCE module = GetModuleHandleW(nullptr);
        keyboard_hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboard_proc, module, 0);
        if (!keyboard_hook) return false;
        mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, mouse_proc, module, 0);
        if (!mouse_hook) {
            UnhookWindowsHookEx(keyboard_hook);
            keyboard_hook = nullptr;
            return false;
        }
        foreground_hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
                                          nullptr, window_event_proc, 0, 0,
                                          WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        focus_hook = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, nullptr,
                                     window_event_proc, 0, 0,
                                     WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        if (!foreground_hook || !focus_hook) {
            if (focus_hook) UnhookWinEvent(focus_hook);
            if (foreground_hook) UnhookWinEvent(foreground_hook);
            UnhookWindowsHookEx(mouse_hook);
            UnhookWindowsHookEx(keyboard_hook);
            focus_hook = nullptr;
            foreground_hook = nullptr;
            mouse_hook = nullptr;
            keyboard_hook = nullptr;
            return false;
        }
        return true;
    }

    void convert_or_undo() noexcept {
        if (is_protected_foreground()) {
            clear_all();
            return;
        }

        if (undo_available) {
            if (replace_text(screen_text.size(), alternate_text)) {
                switch_layout(alternate_layout);
                std::swap(screen_text, alternate_text);
                std::swap(screen_layout, alternate_layout);
            }
            return;
        }

        if (word.empty() || !word_owner || word_owner != GetForegroundWindow()) {
            clear_word();
            return;
        }

        const HKL source = current_layout();
        const HKL target = opposite_layout(source);
        if (!source || !target) return;

        std::size_t core_count = word.size();
        std::wstring suffix;
        while (core_count > 0) {
            wchar_t source_character{};
            if (!translate_key(word[core_count - 1], source, source_character) ||
                !is_trailing_punctuation(source_character))
                break;
            suffix.insert(suffix.begin(), source_character);
            --core_count;
        }
        if (core_count == 0) return;

        std::wstring original;
        std::wstring converted;
        if (!translate_keys(word, core_count, source, original) ||
            !translate_keys(word, core_count, target, converted) || converted.empty())
            return;
        original += suffix;
        converted += suffix;
        if (original == converted) return;

        if (!replace_text(word.size(), converted)) return;
        switch_layout(target);

        screen_text = std::move(converted);
        alternate_text = std::move(original);
        screen_layout = target;
        alternate_layout = source;
        undo_available = true;
        clear_word();
    }

    ~Impl() {
        if (focus_hook) UnhookWinEvent(focus_hook);
        if (foreground_hook) UnhookWinEvent(foreground_hook);
        if (mouse_hook) UnhookWindowsHookEx(mouse_hook);
        if (keyboard_hook) UnhookWindowsHookEx(keyboard_hook);
        if (instance == this) instance = nullptr;
    }
};

Engine::Impl* Engine::Impl::instance = nullptr;

Engine::Engine(HWND message_window) noexcept : impl_(new Impl(message_window)) {}
Engine::~Engine() { delete impl_; }
bool Engine::install() noexcept { return impl_->install(); }
void Engine::convert_or_undo() noexcept { impl_->convert_or_undo(); }

}  // namespace ruswitcher

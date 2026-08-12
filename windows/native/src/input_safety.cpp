#include "input_safety.h"

#include <objbase.h>
#include <uiautomation.h>
#include <wrl/client.h>

namespace ruswitcher {
namespace {
constexpr LONG_PTR kPasswordStyle = ES_PASSWORD;

bool native_password_style(HWND focused) noexcept {
    return focused && (GetWindowLongPtrW(focused, GWL_STYLE) & kPasswordStyle) != 0;
}
}

bool is_protected_foreground() noexcept {
    const HWND foreground = GetForegroundWindow();
    const DWORD thread = GetWindowThreadProcessId(foreground, nullptr);
    GUITHREADINFO gui{sizeof(gui)};
    const HWND focused = GetGUIThreadInfo(thread, &gui) && gui.hwndFocus ? gui.hwndFocus : foreground;
    if (native_password_style(focused)) return true;

    Microsoft::WRL::ComPtr<IUIAutomation> automation;
    if (FAILED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&automation)))) return false;
    Microsoft::WRL::ComPtr<IUIAutomationElement> element;
    if (FAILED(automation->GetFocusedElement(&element)) || !element) return false;
    BOOL is_password = FALSE;
    return SUCCEEDED(element->get_CurrentIsPassword(&is_password)) && is_password;
}
}

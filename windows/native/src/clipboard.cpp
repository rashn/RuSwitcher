#include "clipboard.h"

#include <objbase.h>
#include <ole2.h>

#include <atomic>
#include <cstdint>
#include <utility>
#include <vector>

namespace ruswitcher {
namespace {

constexpr ULONG_PTR kInjectedMarker = 0x52555357;

struct ClipboardItem {
    FORMATETC format{};
    STGMEDIUM medium{};

    ClipboardItem() noexcept = default;
    ClipboardItem(const ClipboardItem&) = delete;
    ClipboardItem& operator=(const ClipboardItem&) = delete;

    ClipboardItem(ClipboardItem&& other) noexcept
        : format(other.format), medium(other.medium) {
        other.format.ptd = nullptr;
        other.medium.tymed = TYMED_NULL;
        other.medium.pUnkForRelease = nullptr;
    }

    ClipboardItem& operator=(ClipboardItem&& other) noexcept {
        if (this == &other) return *this;
        release();
        format = other.format;
        medium = other.medium;
        other.format.ptd = nullptr;
        other.medium.tymed = TYMED_NULL;
        other.medium.pUnkForRelease = nullptr;
        return *this;
    }

    ~ClipboardItem() { release(); }

    void release() noexcept {
        if (medium.tymed != TYMED_NULL) ReleaseStgMedium(&medium);
        medium = {};
        if (format.ptd) CoTaskMemFree(format.ptd);
        format.ptd = nullptr;
    }
};

DVTARGETDEVICE* clone_target_device(const DVTARGETDEVICE* source) noexcept {
    if (!source || source->tdSize < sizeof(DVTARGETDEVICE)) return nullptr;
    auto* copy = static_cast<DVTARGETDEVICE*>(CoTaskMemAlloc(source->tdSize));
    if (copy) CopyMemory(copy, source, source->tdSize);
    return copy;
}

FORMATETC clone_format(const FORMATETC& source) noexcept {
    FORMATETC copy = source;
    copy.ptd = clone_target_device(source.ptd);
    return copy;
}

bool format_matches(const FORMATETC& stored, const FORMATETC& requested) noexcept {
    return stored.cfFormat == requested.cfFormat && stored.dwAspect == requested.dwAspect &&
           stored.lindex == requested.lindex && (stored.tymed & requested.tymed) != 0;
}

class FormatEnumerator final : public IEnumFORMATETC {
public:
    explicit FormatEnumerator(const std::vector<ClipboardItem>* items, ULONG index = 0) noexcept
        : items_(items), index_(index) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid == IID_IUnknown || iid == IID_IEnumFORMATETC) {
            *object = static_cast<IEnumFORMATETC*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --references_;
        if (!remaining) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE Next(ULONG count, FORMATETC* formats, ULONG* fetched) override {
        if (!formats || (count != 1 && !fetched)) return E_POINTER;
        ULONG actual = 0;
        while (actual < count && items_ && index_ < items_->size()) {
            formats[actual] = clone_format((*items_)[index_].format);
            if ((*items_)[index_].format.ptd && !formats[actual].ptd) break;
            ++actual;
            ++index_;
        }
        if (fetched) *fetched = actual;
        return actual == count ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Skip(ULONG count) override {
        if (!items_) return S_FALSE;
        const ULONG remaining = static_cast<ULONG>(items_->size() - index_);
        const ULONG skipped = count < remaining ? count : remaining;
        index_ += skipped;
        return skipped == count ? S_OK : S_FALSE;
    }
    HRESULT STDMETHODCALLTYPE Reset() override {
        index_ = 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Clone(IEnumFORMATETC** result) override {
        if (!result) return E_POINTER;
        *result = new FormatEnumerator(items_, index_);
        return *result ? S_OK : E_OUTOFMEMORY;
    }

private:
    std::atomic<ULONG> references_{1};
    const std::vector<ClipboardItem>* items_{};
    ULONG index_{};
};

class SnapshotDataObject final : public IDataObject {
public:
    explicit SnapshotDataObject(std::vector<ClipboardItem>&& items) noexcept
        : items_(std::move(items)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid == IID_IUnknown || iid == IID_IDataObject) {
            *object = static_cast<IDataObject*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --references_;
        if (!remaining) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE GetData(FORMATETC* requested, STGMEDIUM* medium) override {
        if (!requested || !medium) return E_POINTER;
        ZeroMemory(medium, sizeof(*medium));
        for (const auto& item : items_) {
            if (format_matches(item.format, *requested))
                return CopyStgMedium(&item.medium, medium);
        }
        return DV_E_FORMATETC;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override {
        return DATA_E_FORMATETC;
    }
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* requested) override {
        if (!requested) return E_POINTER;
        for (const auto& item : items_)
            if (format_matches(item.format, *requested)) return S_OK;
        return DV_E_FORMATETC;
    }
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* output) override {
        if (output) output->ptd = nullptr;
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (direction != DATADIR_GET) return E_NOTIMPL;
        *result = new FormatEnumerator(&items_);
        return *result ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override {
        return OLE_E_ADVISENOTSUPPORTED;
    }
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override {
        return OLE_E_ADVISENOTSUPPORTED;
    }

private:
    std::atomic<ULONG> references_{1};
    std::vector<ClipboardItem> items_;
};

bool clear_clipboard() noexcept {
    for (int attempt = 0; attempt < 8; ++attempt) {
        if (OpenClipboard(nullptr)) {
            const bool cleared = EmptyClipboard() != FALSE;
            CloseClipboard();
            return cleared;
        }
        Sleep(15 + attempt * 10);
    }
    return false;
}

INPUT key_input(WORD vk, DWORD flags) noexcept {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vk;
    input.ki.dwFlags = flags;
    input.ki.dwExtraInfo = kInjectedMarker;
    return input;
}

bool send_copy_chord() noexcept {
    const BYTE scan = static_cast<BYTE>(
        MapVirtualKeyExW('C', MAPVK_VK_TO_VSC, GetKeyboardLayout(0)));
    keybd_event(VK_LCONTROL, 0x1D, KEYEVENTF_EXTENDEDKEY, kInjectedMarker);
    keybd_event('C', scan, 0, kInjectedMarker);
    keybd_event('C', scan, KEYEVENTF_KEYUP, kInjectedMarker);
    keybd_event(VK_LCONTROL, 0x1D, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP,
                kInjectedMarker);
    return true;
}

void wait_for_modifiers_released() noexcept {
    const ULONGLONG deadline = GetTickCount64() + 300;
    while (GetTickCount64() < deadline) {
        const bool down = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
                          (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0 ||
                          (GetAsyncKeyState(VK_MENU) & 0x8000) != 0 ||
                          (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 ||
                          (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
        if (!down) break;
        Sleep(5);
    }
    Sleep(25);
}

bool read_unicode_text(std::wstring& text) noexcept {
    if (!OpenClipboard(nullptr)) return false;
    bool copied = false;
    if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        const HANDLE handle = GetClipboardData(CF_UNICODETEXT);
        const auto* value = handle ? static_cast<const wchar_t*>(GlobalLock(handle)) : nullptr;
        if (value) {
            text.assign(value);
            GlobalUnlock(handle);
            copied = !text.empty();
        }
    }
    CloseClipboard();
    return copied;
}

bool wait_for_text(DWORD initial_sequence, DWORD timeout_ms, std::wstring& text) noexcept {
    const ULONGLONG deadline = GetTickCount64() + timeout_ms;
    while (GetTickCount64() < deadline) {
        if (GetClipboardSequenceNumber() != initial_sequence && read_unicode_text(text)) return true;
        Sleep(15);
    }
    return false;
}

bool send_native_copy() noexcept {
    const HWND foreground = GetForegroundWindow();
    const DWORD thread = GetWindowThreadProcessId(foreground, nullptr);
    GUITHREADINFO info{sizeof(info)};
    const HWND focused = GetGUIThreadInfo(thread, &info) && info.hwndFocus ? info.hwndFocus
                                                                          : foreground;
    if (!focused) return false;
    DWORD_PTR ignored{};
    return SendMessageTimeoutW(focused, WM_COPY, 0, 0,
                               SMTO_ABORTIFHUNG | SMTO_BLOCK, 150, &ignored) != 0;
}

}  // namespace

struct ClipboardSnapshot::Impl {
    std::vector<ClipboardItem> items;
    bool captured{};
};

ClipboardSnapshot::ClipboardSnapshot() noexcept : impl_(new Impl) {}
ClipboardSnapshot::~ClipboardSnapshot() { delete impl_; }

bool ClipboardSnapshot::capture() noexcept {
    impl_->items.clear();
    impl_->captured = false;

    IDataObject* source{};
    const HRESULT clipboard_result = OleGetClipboard(&source);
    if (FAILED(clipboard_result)) return false;
    if (!source) {
        impl_->captured = true;
        return true;
    }
    IEnumFORMATETC* enumerator{};
    const HRESULT enum_result = source->EnumFormatEtc(DATADIR_GET, &enumerator);
    if (FAILED(enum_result) || !enumerator) {
        source->Release();
        return false;
    }

    FORMATETC format{};
    ULONG fetched{};
    while (enumerator->Next(1, &format, &fetched) == S_OK && fetched == 1) {
        STGMEDIUM medium{};
        if (SUCCEEDED(source->GetData(&format, &medium))) {
            ClipboardItem item;
            item.format = clone_format(format);
            item.medium = medium;
            if (!format.ptd || item.format.ptd) impl_->items.push_back(std::move(item));
        }
        if (format.ptd) CoTaskMemFree(format.ptd);
        format = {};
    }
    enumerator->Release();
    source->Release();
    impl_->captured = true;
    return true;
}

bool ClipboardSnapshot::restore() noexcept {
    if (!impl_->captured) return false;
    if (impl_->items.empty()) {
        const bool cleared = clear_clipboard();
        impl_->captured = false;
        return cleared;
    }
    auto* data = new SnapshotDataObject(std::move(impl_->items));
    const HRESULT set = OleSetClipboard(data);
    const HRESULT flush = SUCCEEDED(set) ? OleFlushClipboard() : set;
    data->Release();
    impl_->captured = false;
    return SUCCEEDED(set) && SUCCEEDED(flush);
}

bool copy_current_selection(std::wstring& text) noexcept {
    text.clear();
    wait_for_modifiers_released();
    DWORD sequence = GetClipboardSequenceNumber();
    if (send_native_copy() && wait_for_text(sequence, 250, text)) return true;

    // Custom/Chromium/terminal controls often expose no useful focused HWND. Fall back to the
    // same user-level copy command in every app, still without executable-name routing.
    if (!clear_clipboard()) return false;
    sequence = GetClipboardSequenceNumber();
    if (!send_copy_chord()) return false;
    return wait_for_text(sequence, 650, text);
}

}  // namespace ruswitcher

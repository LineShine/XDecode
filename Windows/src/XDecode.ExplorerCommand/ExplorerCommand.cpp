#include <windows.h>
#include <shobjidl_core.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <atomic>
#include <new>
#include <string>
#include <vector>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")

namespace {
constexpr GUID CLSID_XDecodeExplorerCommand{
    0xa9d140b0, 0x2466, 0x47ab, {0x88, 0xf4, 0x1a, 0x2d, 0x0c, 0x7b, 0xbe, 0x12}};
std::atomic<long> g_objectCount{0};
HMODULE g_module{};

#define RETURN_IF_FAILED(expression) \
    do { const HRESULT return_if_failed_result = (expression); \
         if (FAILED(return_if_failed_result)) return return_if_failed_result; } while (false)

HRESULT DuplicateString(const wchar_t* value, wchar_t** result) noexcept {
    if (result == nullptr) return E_POINTER;
    return SHStrDupW(value, result);
}

std::wstring QuoteArgument(const std::wstring& value) {
    std::wstring result{L"\""};
    unsigned backslashes = 0;
    for (const auto character : value) {
        if (character == L'\\') {
            ++backslashes;
        } else if (character == L'"') {
            result.append(backslashes * 2 + 1, L'\\');
            result.push_back(L'"');
            backslashes = 0;
        } else {
            result.append(backslashes, L'\\');
            backslashes = 0;
            result.push_back(character);
        }
    }
    result.append(backslashes * 2, L'\\');
    result.push_back(L'"');
    return result;
}

bool IsRegularFile(IShellItem* item) noexcept {
    SFGAOF attributes{};
    if (FAILED(item->GetAttributes(SFGAO_FILESYSTEM | SFGAO_FOLDER, &attributes)) ||
        (attributes & SFGAO_FILESYSTEM) == 0 ||
        (attributes & SFGAO_FOLDER) != 0) {
        return false;
    }
    PWSTR path{};
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) || path == nullptr) {
        return false;
    }
    const auto fileAttributes = GetFileAttributesW(path);
    CoTaskMemFree(path);
    return fileAttributes != INVALID_FILE_ATTRIBUTES &&
           (fileAttributes & (FILE_ATTRIBUTE_DIRECTORY |
                              FILE_ATTRIBUTE_DEVICE |
                              FILE_ATTRIBUTE_REPARSE_POINT)) == 0;
}

class ExplorerCommand final : public IExplorerCommand {
public:
    ExplorerCommand() noexcept { ++g_objectCount; }
    ~ExplorerCommand() { --g_objectCount; }

    IFACEMETHODIMP QueryInterface(REFIID iid, void** result) override {
        if (result == nullptr) return E_POINTER;
        *result = nullptr;
        if (iid == IID_IUnknown || iid == IID_IExplorerCommand) {
            *result = static_cast<IExplorerCommand*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef() override { return ++references_; }
    IFACEMETHODIMP_(ULONG) Release() override {
        const auto value = --references_;
        if (value == 0) delete this;
        return value;
    }

    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* title) override {
        return DuplicateString(L"使用 XDecode 解密", title);
    }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override {
        if (icon == nullptr) return E_POINTER;
        *icon = nullptr;
        return E_NOTIMPL;
    }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tooltip) override {
        return DuplicateString(L"将所选普通文件交给 XDecode", tooltip);
    }
    IFACEMETHODIMP GetCanonicalName(GUID* commandName) override {
        if (commandName == nullptr) return E_POINTER;
        *commandName = CLSID_XDecodeExplorerCommand;
        return S_OK;
    }
    IFACEMETHODIMP GetState(IShellItemArray* selection, BOOL, EXPCMDSTATE* state) override {
        if (selection == nullptr || state == nullptr) return E_INVALIDARG;
        DWORD count{};
        if (FAILED(selection->GetCount(&count)) || count == 0) {
            *state = ECS_HIDDEN;
            return S_OK;
        }
        for (DWORD index = 0; index < count; ++index) {
            IShellItem* item{};
            if (FAILED(selection->GetItemAt(index, &item)) || item == nullptr) {
                *state = ECS_HIDDEN;
                return S_OK;
            }
            const auto regular = IsRegularFile(item);
            item->Release();
            if (!regular) {
                *state = ECS_HIDDEN;
                return S_OK;
            }
        }
        *state = ECS_ENABLED;
        return S_OK;
    }
    IFACEMETHODIMP Invoke(IShellItemArray* selection, IBindCtx*) override {
        if (selection == nullptr) return E_INVALIDARG;
        DWORD count{};
        RETURN_IF_FAILED(selection->GetCount(&count));
        if (count == 0) return E_INVALIDARG;

        std::vector<std::wstring> paths;
        paths.reserve(count);
        for (DWORD index = 0; index < count; ++index) {
            IShellItem* item{};
            RETURN_IF_FAILED(selection->GetItemAt(index, &item));
            if (!IsRegularFile(item)) {
                item->Release();
                return E_INVALIDARG;
            }
            PWSTR path{};
            const auto result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
            item->Release();
            RETURN_IF_FAILED(result);
            paths.emplace_back(path);
            CoTaskMemFree(path);
        }

        wchar_t modulePath[MAX_PATH]{};
        if (GetModuleFileNameW(g_module, modulePath, ARRAYSIZE(modulePath)) == 0) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        if (!PathRemoveFileSpecW(modulePath)) return E_FAIL;
        std::wstring executable{modulePath};
        executable += L"\\XDecode.Windows.exe";
        std::wstring arguments{L"--explorer"};
        for (const auto& path : paths) {
            arguments.push_back(L' ');
            arguments += QuoteArgument(path);
        }
        const auto process = ShellExecuteW(
            nullptr, L"open", executable.c_str(), arguments.c_str(), modulePath, SW_SHOWNORMAL);
        return reinterpret_cast<INT_PTR>(process) > 32
            ? S_OK
            : HRESULT_FROM_WIN32(static_cast<DWORD>(reinterpret_cast<INT_PTR>(process)));
    }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override {
        if (flags == nullptr) return E_POINTER;
        *flags = ECF_DEFAULT;
        return S_OK;
    }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** commands) override {
        if (commands == nullptr) return E_POINTER;
        *commands = nullptr;
        return E_NOTIMPL;
    }

private:
    std::atomic<ULONG> references_{1};
};

class ClassFactory final : public IClassFactory {
public:
    ClassFactory() noexcept { ++g_objectCount; }
    ~ClassFactory() { --g_objectCount; }
    IFACEMETHODIMP QueryInterface(REFIID iid, void** result) override {
        if (result == nullptr) return E_POINTER;
        *result = nullptr;
        if (iid == IID_IUnknown || iid == IID_IClassFactory) {
            *result = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return ++references_; }
    IFACEMETHODIMP_(ULONG) Release() override {
        const auto value = --references_;
        if (value == 0) delete this;
        return value;
    }
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID iid, void** result) override {
        if (outer != nullptr) return CLASS_E_NOAGGREGATION;
        auto* command = new (std::nothrow) ExplorerCommand();
        if (command == nullptr) return E_OUTOFMEMORY;
        const auto status = command->QueryInterface(iid, result);
        command->Release();
        return status;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override {
        lock ? ++g_objectCount : --g_objectCount;
        return S_OK;
    }
private:
    std::atomic<ULONG> references_{1};
};
} // namespace

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void*) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}

extern "C" HRESULT __stdcall DllCanUnloadNow() {
    return g_objectCount.load() == 0 ? S_OK : S_FALSE;
}

extern "C" HRESULT __stdcall DllGetClassObject(REFCLSID classId, REFIID iid, void** result) {
    if (classId != CLSID_XDecodeExplorerCommand) return CLASS_E_CLASSNOTAVAILABLE;
    auto* factory = new (std::nothrow) ClassFactory();
    if (factory == nullptr) return E_OUTOFMEMORY;
    const auto status = factory->QueryInterface(iid, result);
    factory->Release();
    return status;
}

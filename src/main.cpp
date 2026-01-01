
#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <shellapi.h>
#include "resource.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>

#pragma comment(lib, "d2d1")
#pragma comment(lib, "dwrite")
#pragma comment(lib, "windowscodecs")
#pragma comment(lib, "shell32")

namespace {
constexpr UINT_PTR kTimerId = 1;
constexpr UINT_PTR kTrayClickTimerId = 2;
constexpr UINT_PTR kWorkTimerId = 3;
constexpr UINT kTrayId = 1;
constexpr UINT kTrayMsg = WM_USER + 1;
constexpr double kMinFadeSeconds = 0.05;
constexpr double kMinRestSeconds = 1.0;
constexpr double kMinFps = 5.0;
constexpr double kMaxFps = 60.0;
constexpr double kPi = 3.141592653589793;

constexpr UINT kCmdShowOverlay = 1001;
constexpr UINT kCmdOpenSettings = 1002;
constexpr UINT kCmdReloadConfig = 1003;
constexpr UINT kCmdAbout = 1004;
constexpr UINT kCmdExit = 1005;

constexpr UINT kSettingsSaveId = 2001;
constexpr UINT kSettingsReloadId = 2002;

#ifndef NIN_POPUPOPEN
#define NIN_POPUPOPEN (WM_USER + 6)
#endif
#ifndef NIF_SHOWTIP
#define NIF_SHOWTIP 0x00000080
#endif

enum class VisualMode { Breathing, Image, ImageBreathing };
enum class ImageMode { Fit, Fill, Center };
enum class Language { English, Chinese };

struct Config {
    Language language = Language::English;
    bool autostart = false;
    double work_interval_minutes = 20.0;
    double rest_seconds = 20.0;
    double fade_ms = 600.0;
    double fps = 20.0;

    D2D1_COLOR_F bg_color = D2D1::ColorF(0x11 / 255.0f, 0x11 / 255.0f, 0x11 / 255.0f, 1.0f);
    D2D1_COLOR_F text_color = D2D1::ColorF(0xCF / 255.0f, 0xCF / 255.0f, 0xCF / 255.0f, 1.0f);
    std::wstring message = L"Look far and blink";

    VisualMode visual_mode = VisualMode::Image;
    std::wstring image_path = L"assets\\bg.png";
    ImageMode image_mode = ImageMode::Fit;
    float image_opacity = 0.35f;

    double breath_cycle_ms = 9000.0;
    float breath_min_radius = 80.0f;
    float breath_max_radius = 140.0f;
    float breath_opacity = 0.35f;
};

struct AppState {
    enum class Phase { FadeIn, Rest, FadeOut };

    Phase phase = Phase::FadeIn;
    double opacity = 0.0;
    double phase_elapsed = 0.0;
    double rest_remaining = 0.0;
    double total_elapsed = 0.0;

    LARGE_INTEGER freq{};
    LARGE_INTEGER last{};
};

Config g_config;
AppState g_state;
std::wstring g_config_path;
UINT g_tray_msg = kTrayMsg;

HWND g_overlay_hwnd = nullptr;
HWND g_tray_hwnd = nullptr;
HWND g_settings_hwnd = nullptr;
HWND g_settings_edit = nullptr;
HWND g_about_hwnd = nullptr;
HWND g_about_edit = nullptr;
bool g_overlay_visible = false;
bool g_tray_click_pending = false;
HICON g_tray_icon = nullptr;
bool g_tray_icon_owned = false;
std::unordered_map<std::string, std::wstring> g_i18n;
ULONGLONG g_next_overlay_tick = 0;

ID2D1Factory* g_d2d_factory = nullptr;
ID2D1HwndRenderTarget* g_render_target = nullptr;
ID2D1SolidColorBrush* g_bg_brush = nullptr;
ID2D1SolidColorBrush* g_text_brush = nullptr;
ID2D1SolidColorBrush* g_breath_brush = nullptr;
IDWriteFactory* g_dwrite_factory = nullptr;
IDWriteTextFormat* g_message_format = nullptr;
IDWriteTextFormat* g_countdown_format = nullptr;

IWICImagingFactory* g_wic_factory = nullptr;
ID2D1Bitmap* g_image_bitmap = nullptr;
D2D1_SIZE_F g_image_size{};

void StartOverlay();
void ShowSettingsWindow(HWND owner);
void ShowAboutWindow(HWND owner);
void LoadConfig();
void ApplyConfig(HWND hwnd);
void UpdateWorkTimer();
void ApplyAutostart();
void UpdateLocalizedWindowTexts();
void LoadLocalization();
std::wstring Tr(const char* key, const wchar_t* fallback);
std::wstring BuildAboutText();
std::wstring BuildTrayTooltip();
void UpdateTrayTooltip();

void SafeRelease(IUnknown* obj) {
    if (obj) {
        obj->Release();
    }
}

std::wstring Utf8ToWide(const std::string& text) {
    if (text.empty()) {
        return L"";
    }
    int len = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (len <= 0) {
        return L"";
    }
    std::wstring out(static_cast<size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), len);
    return out;
}

std::string WideToUtf8(const std::wstring& text) {
    if (text.empty()) {
        return "";
    }
    int len = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (len <= 0) {
        return "";
    }
    std::string out(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), len, nullptr, nullptr);
    return out;
}

std::wstring GetExeDirectory() {
    wchar_t buffer[MAX_PATH] = {};
    DWORD len = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    if (len == 0 || len == MAX_PATH) {
        return L".";
    }
    std::wstring path(buffer);
    size_t pos = path.find_last_of(L"\\/");
    if (pos == std::wstring::npos) {
        return L".";
    }
    return path.substr(0, pos);
}

std::wstring GetCurrentDirectoryPath() {
    DWORD len = GetCurrentDirectoryW(0, nullptr);
    if (len == 0) {
        return L".";
    }
    std::wstring buffer(len, L'\0');
    DWORD out_len = GetCurrentDirectoryW(len, buffer.data());
    if (out_len == 0 || out_len >= len) {
        return L".";
    }
    buffer.resize(out_len);
    return buffer;
}

std::wstring JoinPath(const std::wstring& dir, const std::wstring& file) {
    if (dir.empty()) {
        return file;
    }
    if (dir.back() == L'\\' || dir.back() == L'/') {
        return dir + file;
    }
    return dir + L"\\" + file;
}

bool FileExists(const std::wstring& path) {
    DWORD attrs = GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

HICON LoadTrayIcon() {
    int cx = GetSystemMetrics(SM_CXSMICON);
    int cy = GetSystemMetrics(SM_CYSMICON);
    HICON icon = nullptr;
    g_tray_icon_owned = false;

    icon = reinterpret_cast<HICON>(
        LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, cx, cy, 0)
    );
    if (!icon) {
        icon = LoadIcon(nullptr, IDI_APPLICATION);
    }
    g_tray_icon_owned = false;
    return icon;
}

std::wstring ResolveConfigPath() {
    if (!g_config_path.empty()) {
        return g_config_path;
    }
    std::wstring exe_path = JoinPath(GetExeDirectory(), L"config.json");
    if (FileExists(exe_path)) {
        g_config_path = exe_path;
        return g_config_path;
    }
    std::wstring cwd_path = JoinPath(GetCurrentDirectoryPath(), L"config.json");
    if (FileExists(cwd_path)) {
        g_config_path = cwd_path;
        return g_config_path;
    }
    g_config_path = exe_path;
    return g_config_path;
}

std::string ReadFileUtf8(const std::wstring& path) {
    std::ifstream file(std::filesystem::path(path), std::ios::binary);
    if (!file) {
        return {};
    }
    std::string data((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    if (data.size() >= 3 && static_cast<unsigned char>(data[0]) == 0xEF &&
        static_cast<unsigned char>(data[1]) == 0xBB && static_cast<unsigned char>(data[2]) == 0xBF) {
        data.erase(0, 3);
    }
    return data;
}

bool WriteFileUtf8(const std::wstring& path, const std::string& data) {
    std::ofstream file(std::filesystem::path(path), std::ios::binary | std::ios::trunc);
    if (!file) {
        return false;
    }
    file.write(data.data(), static_cast<std::streamsize>(data.size()));
    return file.good();
}
bool FindValueStart(const std::string& json, const char* key, size_t* pos_out) {
    std::string needle = "\"";
    needle += key;
    needle += "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) {
        return false;
    }
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) {
        return false;
    }
    pos += 1;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
        ++pos;
    }
    if (pos >= json.size()) {
        return false;
    }
    *pos_out = pos;
    return true;
}

bool ExtractString(const std::string& json, const char* key, std::string* out) {
    size_t pos = 0;
    if (!FindValueStart(json, key, &pos)) {
        return false;
    }
    if (json[pos] != '"') {
        return false;
    }
    std::string value;
    for (size_t i = pos + 1; i < json.size(); ++i) {
        char c = json[i];
        if (c == '\\' && i + 1 < json.size()) {
            value.push_back(json[i + 1]);
            ++i;
            continue;
        }
        if (c == '"') {
            *out = value;
            return true;
        }
        value.push_back(c);
    }
    return false;
}

bool ExtractDouble(const std::string& json, const char* key, double* out) {
    size_t pos = 0;
    if (!FindValueStart(json, key, &pos)) {
        return false;
    }
    char* end = nullptr;
    double value = std::strtod(json.c_str() + pos, &end);
    if (end == json.c_str() + pos) {
        return false;
    }
    *out = value;
    return true;
}

bool ExtractBool(const std::string& json, const char* key, bool* out) {
    size_t pos = 0;
    if (!FindValueStart(json, key, &pos)) {
        return false;
    }
    if (json.compare(pos, 4, "true") == 0) {
        *out = true;
        return true;
    }
    if (json.compare(pos, 5, "false") == 0) {
        *out = false;
        return true;
    }
    if (json[pos] == '1' || json[pos] == '0') {
        *out = (json[pos] == '1');
        return true;
    }
    return false;
}

std::string ToLowerAscii(std::string value) {
    for (char& c : value) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    return value;
}

Language ParseLanguage(const std::string& value) {
    std::string v = ToLowerAscii(value);
    if (v == "zh" || v == "zh-cn" || v == "cn" || v == "chinese") {
        return Language::Chinese;
    }
    return Language::English;
}

std::string Trim(const std::string& value) {
    size_t start = 0;
    while (start < value.size() && std::isspace(static_cast<unsigned char>(value[start]))) {
        ++start;
    }
    size_t end = value.size();
    while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1]))) {
        --end;
    }
    return value.substr(start, end - start);
}

std::wstring FindAssetsDir() {
    std::wstring dir = GetExeDirectory();
    for (int i = 0; i < 5; ++i) {
        std::wstring assets = JoinPath(dir, L"assets");
        if (FileExists(JoinPath(assets, L"lang_en.txt")) || FileExists(JoinPath(assets, L"lang_zh.txt"))) {
            return assets;
        }
        size_t pos = dir.find_last_of(L"\\/");
        if (pos == std::wstring::npos) {
            break;
        }
        dir = dir.substr(0, pos);
        if (dir.empty()) {
            break;
        }
    }
    return L"";
}

void LoadLocalization() {
    g_i18n.clear();
    std::wstring assets_dir = FindAssetsDir();
    if (assets_dir.empty()) {
        return;
    }
    std::wstring file = JoinPath(
        assets_dir,
        g_config.language == Language::Chinese ? L"lang_zh.txt" : L"lang_en.txt"
    );
    std::string data = ReadFileUtf8(file);
    if (data.empty()) {
        return;
    }
    size_t start = 0;
    while (start <= data.size()) {
        size_t end = data.find('\n', start);
        std::string line = (end == std::string::npos) ? data.substr(start) : data.substr(start, end - start);
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        line = Trim(line);
        if (!line.empty() && line[0] != '#') {
            size_t sep = line.find('=');
            if (sep != std::string::npos) {
                std::string key = Trim(line.substr(0, sep));
                std::string value = Trim(line.substr(sep + 1));
                if (!key.empty()) {
                    g_i18n[key] = Utf8ToWide(value);
                }
            }
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
}

std::wstring Tr(const char* key, const wchar_t* fallback) {
    if (key) {
        auto it = g_i18n.find(key);
        if (it != g_i18n.end()) {
            return it->second;
        }
    }
    return fallback ? std::wstring(fallback) : std::wstring();
}

std::wstring BuildTrayTooltip() {
    if (g_overlay_visible) {
        return Tr("tray_tooltip_active", L"Eye Break (active)");
    }
    if (g_config.work_interval_minutes <= 0.0 || g_next_overlay_tick == 0) {
        return Tr("tray_tooltip_disabled", L"Eye Break (periodic off)");
    }

    ULONGLONG now = GetTickCount64();
    if (g_next_overlay_tick <= now) {
        return Tr("tray_tooltip_soon", L"Eye Break (soon)");
    }

    ULONGLONG remaining_ms = g_next_overlay_tick - now;
    FILETIME ft{};
    SYSTEMTIME local{};
    GetLocalTime(&local);
    if (SystemTimeToFileTime(&local, &ft)) {
        ULARGE_INTEGER uli{};
        uli.LowPart = ft.dwLowDateTime;
        uli.HighPart = ft.dwHighDateTime;
        uli.QuadPart += remaining_ms * 10000ULL;
        ft.dwLowDateTime = uli.LowPart;
        ft.dwHighDateTime = uli.HighPart;
        if (FileTimeToSystemTime(&ft, &local)) {
            wchar_t time_buf[16] = {};
            swprintf_s(time_buf, L"%02u:%02u:%02u", local.wHour, local.wMinute, local.wSecond);
            std::wstring prefix = Tr("tray_tooltip_next", L"Next break: ");
            return prefix + time_buf;
        }
    }

    return Tr("tray_tooltip_soon", L"Eye Break (soon)");
}

void UpdateTrayTooltip() {
    if (!g_tray_hwnd) {
        return;
    }
    NOTIFYICONDATA nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_tray_hwnd;
    nid.uID = kTrayId;
    nid.uFlags = NIF_TIP | NIF_SHOWTIP;
    std::wstring tip = BuildTrayTooltip();
    wcsncpy_s(nid.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIcon(NIM_MODIFY, &nid);
}

bool ParseHexColor(const std::string& text, D2D1_COLOR_F* color) {
    if (text.size() != 7 || text[0] != '#') {
        return false;
    }
    auto hex_to_int = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
        if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
        return -1;
    };
    int r1 = hex_to_int(text[1]);
    int r2 = hex_to_int(text[2]);
    int g1 = hex_to_int(text[3]);
    int g2 = hex_to_int(text[4]);
    int b1 = hex_to_int(text[5]);
    int b2 = hex_to_int(text[6]);
    if (r1 < 0 || r2 < 0 || g1 < 0 || g2 < 0 || b1 < 0 || b2 < 0) {
        return false;
    }
    int r = r1 * 16 + r2;
    int g = g1 * 16 + g2;
    int b = b1 * 16 + b2;
    *color = D2D1::ColorF(r / 255.0f, g / 255.0f, b / 255.0f, 1.0f);
    return true;
}

std::string EscapeJsonString(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (char c : value) {
        if (c == '\\' || c == '"') {
            out.push_back('\\');
            out.push_back(c);
        } else if (c == '\n') {
            out += "\\n";
        } else if (c == '\r') {
            out += "\\r";
        } else if (c == '\t') {
            out += "\\t";
        } else {
            out.push_back(c);
        }
    }
    return out;
}

std::string BuildConfigJson(const Config& cfg) {
    std::ostringstream out;
    out.setf(std::ios::fixed);
    out.precision(2);

    std::string message = EscapeJsonString(WideToUtf8(cfg.message));
    std::string image_path = EscapeJsonString(WideToUtf8(cfg.image_path));

    std::string visual = "breathing";
    if (cfg.visual_mode == VisualMode::Image) {
        visual = "image";
    } else if (cfg.visual_mode == VisualMode::ImageBreathing) {
        visual = "image+breathing";
    }
    std::string image_mode = "fit";
    if (cfg.image_mode == ImageMode::Fill) {
        image_mode = "fill";
    } else if (cfg.image_mode == ImageMode::Center) {
        image_mode = "center";
    }

    out << "{\n";
    out << "  \"language\": \"" << (cfg.language == Language::Chinese ? "zh" : "en") << "\",\n";
    out << "  \"autostart\": " << (cfg.autostart ? "true" : "false") << ",\n";
    out << "  \"work_interval_minutes\": " << cfg.work_interval_minutes << ",\n";
    out << "  \"rest_seconds\": " << cfg.rest_seconds << ",\n";
    out << "  \"fade_ms\": " << cfg.fade_ms << ",\n";
    out << "  \"fps\": " << cfg.fps << ",\n";
    out << "  \"bg_color\": \"#111111\",\n";
    out << "  \"text_color\": \"#CFCFCF\",\n";
    out << "  \"message\": \"" << message << "\",\n\n";

    out << "  \"visual_mode\": \"" << visual << "\",\n";
    out << "  \"image_path\": \"" << image_path << "\",\n";
    out << "  \"image_mode\": \"" << image_mode << "\",\n";
    out << "  \"image_opacity\": " << cfg.image_opacity << ",\n\n";

    out << "  \"breath_cycle_ms\": " << cfg.breath_cycle_ms << ",\n";
    out << "  \"breath_min_radius\": " << cfg.breath_min_radius << ",\n";
    out << "  \"breath_max_radius\": " << cfg.breath_max_radius << ",\n";
    out << "  \"breath_opacity\": " << cfg.breath_opacity << "\n";
    out << "}\n";

    return out.str();
}

void LoadConfig() {
    Config cfg;
    std::wstring config_path = ResolveConfigPath();
    bool existed = FileExists(config_path);
    std::string json = ReadFileUtf8(config_path);
    if (json.empty() && !existed) {
        WriteFileUtf8(config_path, BuildConfigJson(cfg));
        json = ReadFileUtf8(config_path);
    }
    if (!json.empty()) {
        double value = 0.0;
        bool flag = false;
        std::string lang;
        if (ExtractString(json, "language", &lang)) {
            cfg.language = ParseLanguage(lang);
        }
        if (ExtractBool(json, "autostart", &flag)) {
            cfg.autostart = flag;
        }
        if (ExtractDouble(json, "work_interval_minutes", &value)) {
            cfg.work_interval_minutes = value;
        }
        if (ExtractDouble(json, "rest_seconds", &value)) {
            cfg.rest_seconds = value;
        }
        if (ExtractDouble(json, "fade_ms", &value)) {
            cfg.fade_ms = value;
        }
        if (ExtractDouble(json, "fps", &value)) {
            cfg.fps = value;
        }

        std::string str;
        if (ExtractString(json, "message", &str)) {
            cfg.message = Utf8ToWide(str);
        }
        if (ExtractString(json, "bg_color", &str)) {
            D2D1_COLOR_F color{};
            if (ParseHexColor(str, &color)) {
                cfg.bg_color = color;
            }
        }
        if (ExtractString(json, "text_color", &str)) {
            D2D1_COLOR_F color{};
            if (ParseHexColor(str, &color)) {
                cfg.text_color = color;
            }
        }
        if (ExtractString(json, "visual_mode", &str)) {
            std::string mode = ToLowerAscii(str);
            if (mode == "image") {
                cfg.visual_mode = VisualMode::Image;
            } else if (mode == "image+breathing") {
                cfg.visual_mode = VisualMode::ImageBreathing;
            } else {
                cfg.visual_mode = VisualMode::Breathing;
            }
        }
        if (ExtractString(json, "image_path", &str)) {
            cfg.image_path = Utf8ToWide(str);
        }
        if (ExtractString(json, "image_mode", &str)) {
            std::string mode = ToLowerAscii(str);
            if (mode == "fill") {
                cfg.image_mode = ImageMode::Fill;
            } else if (mode == "center") {
                cfg.image_mode = ImageMode::Center;
            } else {
                cfg.image_mode = ImageMode::Fit;
            }
        }
        if (ExtractDouble(json, "image_opacity", &value)) {
            cfg.image_opacity = static_cast<float>(value);
        }
        if (ExtractDouble(json, "breath_cycle_ms", &value)) {
            cfg.breath_cycle_ms = value;
        }
        if (ExtractDouble(json, "breath_min_radius", &value)) {
            cfg.breath_min_radius = static_cast<float>(value);
        }
        if (ExtractDouble(json, "breath_max_radius", &value)) {
            cfg.breath_max_radius = static_cast<float>(value);
        }
        if (ExtractDouble(json, "breath_opacity", &value)) {
            cfg.breath_opacity = static_cast<float>(value);
        }
    }

    if (cfg.work_interval_minutes < 0.0) {
        cfg.work_interval_minutes = 0.0;
    }
    cfg.fps = std::clamp(cfg.fps, kMinFps, kMaxFps);
    cfg.fade_ms = std::max(cfg.fade_ms, kMinFadeSeconds * 1000.0);
    cfg.rest_seconds = std::max(cfg.rest_seconds, kMinRestSeconds);
    cfg.image_opacity = std::clamp(cfg.image_opacity, 0.0f, 1.0f);
    cfg.breath_opacity = std::clamp(cfg.breath_opacity, 0.0f, 1.0f);
    g_config = cfg;
}

void ResetTiming() {
    QueryPerformanceFrequency(&g_state.freq);
    QueryPerformanceCounter(&g_state.last);
}

void StopOverlay(HWND hwnd) {
    if (!g_overlay_visible) {
        return;
    }
    KillTimer(hwnd, kTimerId);
    ShowWindow(hwnd, SW_HIDE);
    g_overlay_visible = false;
    UpdateWorkTimer();
}

void RequestFadeOut() {
    if (g_state.phase != AppState::Phase::FadeOut) {
        g_state.phase = AppState::Phase::FadeOut;
        g_state.phase_elapsed = 0.0;
    }
}

void UpdateState(double dt, HWND hwnd) {
    g_state.total_elapsed += dt;
    double fade_seconds = std::max(kMinFadeSeconds, g_config.fade_ms / 1000.0);

    switch (g_state.phase) {
        case AppState::Phase::FadeIn: {
            g_state.phase_elapsed += dt;
            double t = g_state.phase_elapsed / fade_seconds;
            if (t >= 1.0) {
                t = 1.0;
                g_state.phase = AppState::Phase::Rest;
                g_state.phase_elapsed = 0.0;
                g_state.rest_remaining = g_config.rest_seconds;
            }
            g_state.opacity = t;
            break;
        }
        case AppState::Phase::Rest: {
            g_state.rest_remaining -= dt;
            if (g_state.rest_remaining <= 0.0) {
                g_state.phase = AppState::Phase::FadeOut;
                g_state.phase_elapsed = 0.0;
                g_state.rest_remaining = 0.0;
            }
            g_state.opacity = 1.0;
            break;
        }
        case AppState::Phase::FadeOut: {
            g_state.phase_elapsed += dt;
            double t = g_state.phase_elapsed / fade_seconds;
            double o = 1.0 - t;
            if (o <= 0.0) {
                g_state.opacity = 0.0;
                StopOverlay(hwnd);
                return;
            }
            g_state.opacity = o;
            break;
        }
    }

    BYTE alpha = static_cast<BYTE>(std::round(std::clamp(g_state.opacity, 0.0, 1.0) * 255.0));
    SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
}
HRESULT CreateDeviceResources(HWND hwnd) {
    if (g_render_target) {
        return S_OK;
    }

    RECT rc{};
    GetClientRect(hwnd, &rc);
    D2D1_SIZE_U size = D2D1::SizeU(rc.right - rc.left, rc.bottom - rc.top);

    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &g_d2d_factory);
    if (FAILED(hr)) {
        return hr;
    }

    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties();
    hr = g_d2d_factory->CreateHwndRenderTarget(
        props,
        D2D1::HwndRenderTargetProperties(hwnd, size),
        &g_render_target
    );
    if (FAILED(hr)) {
        return hr;
    }

    hr = g_render_target->CreateSolidColorBrush(g_config.bg_color, &g_bg_brush);
    if (FAILED(hr)) {
        return hr;
    }

    hr = g_render_target->CreateSolidColorBrush(g_config.text_color, &g_text_brush);
    if (FAILED(hr)) {
        return hr;
    }

    hr = g_render_target->CreateSolidColorBrush(g_config.text_color, &g_breath_brush);
    if (FAILED(hr)) {
        return hr;
    }

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(&g_dwrite_factory));
    if (FAILED(hr)) {
        return hr;
    }

    hr = g_dwrite_factory->CreateTextFormat(
        L"Segoe UI",
        nullptr,
        DWRITE_FONT_WEIGHT_REGULAR,
        DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,
        28.0f,
        L"en-us",
        &g_message_format
    );
    if (FAILED(hr)) {
        return hr;
    }

    g_message_format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    g_message_format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

    hr = g_dwrite_factory->CreateTextFormat(
        L"Segoe UI",
        nullptr,
        DWRITE_FONT_WEIGHT_SEMI_BOLD,
        DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL,
        72.0f,
        L"en-us",
        &g_countdown_format
    );
    if (FAILED(hr)) {
        return hr;
    }

    g_countdown_format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    g_countdown_format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

    if (g_wic_factory && g_config.visual_mode != VisualMode::Breathing && !g_config.image_path.empty()) {
        SafeRelease(g_image_bitmap);
        g_image_bitmap = nullptr;
        g_image_size = D2D1::SizeF(0.0f, 0.0f);

        IWICBitmapDecoder* decoder = nullptr;
        IWICBitmapFrameDecode* frame = nullptr;
        IWICFormatConverter* converter = nullptr;
        HRESULT img_hr = g_wic_factory->CreateDecoderFromFilename(
            g_config.image_path.c_str(),
            nullptr,
            GENERIC_READ,
            WICDecodeMetadataCacheOnLoad,
            &decoder
        );
        if (SUCCEEDED(img_hr)) {
            img_hr = decoder->GetFrame(0, &frame);
        }
        if (SUCCEEDED(img_hr)) {
            img_hr = g_wic_factory->CreateFormatConverter(&converter);
        }
        if (SUCCEEDED(img_hr)) {
            img_hr = converter->Initialize(
                frame,
                GUID_WICPixelFormat32bppPBGRA,
                WICBitmapDitherTypeNone,
                nullptr,
                0.0,
                WICBitmapPaletteTypeMedianCut
            );
        }
        if (SUCCEEDED(img_hr)) {
            img_hr = g_render_target->CreateBitmapFromWicBitmap(converter, nullptr, &g_image_bitmap);
        }
        if (SUCCEEDED(img_hr) && g_image_bitmap) {
            g_image_size = g_image_bitmap->GetSize();
        }
        SafeRelease(converter);
        SafeRelease(frame);
        SafeRelease(decoder);
    }

    return S_OK;
}

void DiscardDeviceResources() {
    SafeRelease(g_bg_brush);
    SafeRelease(g_text_brush);
    SafeRelease(g_breath_brush);
    SafeRelease(g_image_bitmap);
    SafeRelease(g_render_target);
    SafeRelease(g_message_format);
    SafeRelease(g_countdown_format);
    SafeRelease(g_dwrite_factory);
    SafeRelease(g_d2d_factory);
    g_bg_brush = nullptr;
    g_text_brush = nullptr;
    g_breath_brush = nullptr;
    g_image_bitmap = nullptr;
    g_render_target = nullptr;
    g_message_format = nullptr;
    g_countdown_format = nullptr;
    g_dwrite_factory = nullptr;
    g_d2d_factory = nullptr;
}

void ApplyConfig(HWND hwnd) {
    DiscardDeviceResources();
    UINT interval = static_cast<UINT>(std::round(1000.0 / g_config.fps));
    if (interval < 10) {
        interval = 10;
    }
    if (g_overlay_visible) {
        SetTimer(hwnd, kTimerId, interval, nullptr);
    }
    UpdateWorkTimer();
    ApplyAutostart();
    LoadLocalization();
    UpdateLocalizedWindowTexts();
}

void Render(HWND hwnd) {
    if (!g_overlay_visible) {
        return;
    }
    if (FAILED(CreateDeviceResources(hwnd))) {
        return;
    }

    g_render_target->BeginDraw();
    g_render_target->Clear(g_config.bg_color);

    D2D1_SIZE_F size = g_render_target->GetSize();
    float width = size.width;
    float height = size.height;

    int seconds_left = static_cast<int>(std::ceil(g_state.rest_remaining));
    if (seconds_left < 0) {
        seconds_left = 0;
    }

    std::wstring message = g_config.message;
    std::wstring countdown = std::to_wstring(seconds_left) + L" s";

    D2D1_RECT_F message_rect = D2D1::RectF(0.0f, height * 0.4f - 40.0f, width, height * 0.4f + 20.0f);
    D2D1_RECT_F countdown_rect = D2D1::RectF(0.0f, height * 0.5f - 20.0f, width, height * 0.5f + 120.0f);

    g_render_target->FillRectangle(D2D1::RectF(0.0f, 0.0f, width, height), g_bg_brush);

    if (g_image_bitmap && g_config.visual_mode != VisualMode::Breathing) {
        float img_w = g_image_size.width;
        float img_h = g_image_size.height;
        if (img_w > 0.0f && img_h > 0.0f) {
            float scale = 1.0f;
            if (g_config.image_mode == ImageMode::Fit) {
                scale = std::min(width / img_w, height / img_h);
            } else if (g_config.image_mode == ImageMode::Fill) {
                scale = std::max(width / img_w, height / img_h);
            }
            float draw_w = img_w * scale;
            float draw_h = img_h * scale;
            if (g_config.image_mode == ImageMode::Center) {
                draw_w = img_w;
                draw_h = img_h;
            }
            float x = (width - draw_w) * 0.5f;
            float y = (height - draw_h) * 0.5f;
            D2D1_RECT_F dest = D2D1::RectF(x, y, x + draw_w, y + draw_h);
            g_render_target->DrawBitmap(g_image_bitmap, dest, g_config.image_opacity, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        }
    }

    if (g_config.visual_mode != VisualMode::Image) {
        double cycle = std::max(0.1, g_config.breath_cycle_ms / 1000.0);
        double phase = std::fmod(g_state.total_elapsed, cycle) / cycle;
        double t = 0.5 - 0.5 * std::cos(phase * 2.0 * kPi);
        float radius = (g_config.breath_min_radius +
            static_cast<float>((g_config.breath_max_radius - g_config.breath_min_radius) * t)) * 1.5f;
        float alpha = g_config.breath_opacity * static_cast<float>(0.6 + 0.4 * std::sin(phase * 2.0 * kPi));
        alpha = std::clamp(alpha, 0.0f, 1.0f);
        if (g_breath_brush) {
            g_breath_brush->SetOpacity(alpha);
            D2D1_ELLIPSE ellipse = D2D1::Ellipse(D2D1::Point2F(width * 0.5f, height * 0.45f), radius, radius);
            g_render_target->DrawEllipse(ellipse, g_breath_brush, 3.0f);
        }
    }

    g_render_target->DrawTextW(message.c_str(), static_cast<UINT32>(message.size()), g_message_format, message_rect, g_text_brush);
    g_render_target->DrawTextW(countdown.c_str(), static_cast<UINT32>(countdown.size()), g_countdown_format, countdown_rect, g_text_brush);

    HRESULT hr = g_render_target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        DiscardDeviceResources();
    }
}

RECT GetPrimaryMonitorRect() {
    POINT pt{0, 0};
    HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    GetMonitorInfo(monitor, &info);
    return info.rcMonitor;
}

void StartOverlay() {
    if (!g_overlay_hwnd) {
        return;
    }

    RECT monitor = GetPrimaryMonitorRect();
    int width = monitor.right - monitor.left;
    int height = monitor.bottom - monitor.top;
    SetWindowPos(g_overlay_hwnd, HWND_TOPMOST, monitor.left, monitor.top, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);

    g_state.phase = AppState::Phase::FadeIn;
    g_state.phase_elapsed = 0.0;
    g_state.opacity = 0.0;
    g_state.total_elapsed = 0.0;
    g_state.rest_remaining = g_config.rest_seconds;

    ResetTiming();
    g_overlay_visible = true;
    SetLayeredWindowAttributes(g_overlay_hwnd, 0, 0, LWA_ALPHA);
    if (g_tray_hwnd) {
        KillTimer(g_tray_hwnd, kWorkTimerId);
    }

    UINT interval = static_cast<UINT>(std::round(1000.0 / g_config.fps));
    if (interval < 10) {
        interval = 10;
    }
    SetTimer(g_overlay_hwnd, kTimerId, interval, nullptr);
    InvalidateRect(g_overlay_hwnd, nullptr, FALSE);
}

bool AddTrayIcon(HWND hwnd) {
    NOTIFYICONDATA nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = kTrayId;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    nid.uCallbackMessage = g_tray_msg;
    g_tray_icon = LoadTrayIcon();
    nid.hIcon = g_tray_icon;
    std::wstring tip = BuildTrayTooltip();
    wcsncpy_s(nid.szTip, tip.c_str(), _TRUNCATE);
    if (!Shell_NotifyIcon(NIM_ADD, &nid)) {
        return false;
    }
    nid.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &nid);
    UpdateTrayTooltip();
    return true;
}

void RemoveTrayIcon(HWND hwnd) {
    NOTIFYICONDATA nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = hwnd;
    nid.uID = kTrayId;
    Shell_NotifyIcon(NIM_DELETE, &nid);
    if (g_tray_icon_owned && g_tray_icon) {
        DestroyIcon(g_tray_icon);
    }
    g_tray_icon = nullptr;
    g_tray_icon_owned = false;
}

void ShowTrayMenu(HWND hwnd) {
    HMENU menu = CreatePopupMenu();
    if (!menu) {
        return;
    }
    std::wstring open_settings = Tr("menu_open_settings", L"Open Settings");
    std::wstring show_overlay = Tr("menu_show_overlay", L"Show Overlay Now");
    std::wstring reload_config = Tr("menu_reload_config", L"Reload Config");
    std::wstring about = Tr("menu_about", L"About");
    std::wstring exit_label = Tr("menu_exit", L"Exit");
    AppendMenu(menu, MF_STRING, kCmdOpenSettings, open_settings.c_str());
    AppendMenu(menu, MF_STRING, kCmdShowOverlay, show_overlay.c_str());
    AppendMenu(menu, MF_STRING, kCmdReloadConfig, reload_config.c_str());
    AppendMenu(menu, MF_STRING, kCmdAbout, about.c_str());
    AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenu(menu, MF_STRING, kCmdExit, exit_label.c_str());

    POINT pt{};
    GetCursorPos(&pt);
    SetForegroundWindow(hwnd);
    UINT cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, nullptr);
    if (cmd != 0) {
        SendMessage(hwnd, WM_COMMAND, cmd, 0);
    }
    DestroyMenu(menu);
}

void HandleTrayCommand(UINT cmd) {
    switch (cmd) {
        case kCmdShowOverlay:
            StartOverlay();
            break;
        case kCmdOpenSettings:
            ShowSettingsWindow(g_tray_hwnd ? g_tray_hwnd : g_overlay_hwnd);
            break;
        case kCmdReloadConfig:
            LoadConfig();
            ApplyConfig(g_overlay_hwnd);
            break;
        case kCmdAbout:
            ShowAboutWindow(g_tray_hwnd ? g_tray_hwnd : g_overlay_hwnd);
            break;
        case kCmdExit:
            if (g_overlay_hwnd) {
                DestroyWindow(g_overlay_hwnd);
                g_overlay_hwnd = nullptr;
            }
            if (g_tray_hwnd) {
                DestroyWindow(g_tray_hwnd);
            }
            break;
        default:
            break;
    }
}

void UpdateWorkTimer() {
    if (!g_tray_hwnd) {
        return;
    }
    KillTimer(g_tray_hwnd, kWorkTimerId);
    if (g_config.work_interval_minutes <= 0.0) {
        g_next_overlay_tick = 0;
        UpdateTrayTooltip();
        return;
    }
    double ms = g_config.work_interval_minutes * 60.0 * 1000.0;
    if (ms < 1000.0) {
        ms = 1000.0;
    }
    if (ms > static_cast<double>(UINT_MAX)) {
        ms = static_cast<double>(UINT_MAX);
    }
    SetTimer(g_tray_hwnd, kWorkTimerId, static_cast<UINT>(ms), nullptr);
    g_next_overlay_tick = GetTickCount64() + static_cast<ULONGLONG>(ms);
    UpdateTrayTooltip();
}

void ApplyAutostart() {
    HKEY key = nullptr;
    const wchar_t* run_key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    if (RegCreateKeyExW(HKEY_CURRENT_USER, run_key, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
        return;
    }

    const wchar_t* value_name = L"EyeBreak";
    if (g_config.autostart) {
        wchar_t path[MAX_PATH] = {};
        DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
        if (len > 0 && len < MAX_PATH) {
            std::wstring value = L"\"";
            value.append(path, len);
            value += L"\"";
            RegSetValueExW(key, value_name, 0, REG_SZ,
                reinterpret_cast<const BYTE*>(value.c_str()),
                static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
        }
    } else {
        RegDeleteValueW(key, value_name);
    }

    RegCloseKey(key);
}

void UpdateLocalizedWindowTexts() {
    if (g_settings_hwnd) {
        std::wstring title = Tr("settings_title", L"Eye Break Settings");
        SetWindowTextW(g_settings_hwnd, title.c_str());
        HWND save_btn = GetDlgItem(g_settings_hwnd, kSettingsSaveId);
        HWND reload_btn = GetDlgItem(g_settings_hwnd, kSettingsReloadId);
        if (save_btn) {
            std::wstring save_text = Tr("btn_save", L"Save");
            SetWindowTextW(save_btn, save_text.c_str());
        }
        if (reload_btn) {
            std::wstring reload_text = Tr("btn_reload", L"Reload");
            SetWindowTextW(reload_btn, reload_text.c_str());
        }
    }
    if (g_about_hwnd) {
        std::wstring about_title = Tr("about_title", L"About Eye Break");
        SetWindowTextW(g_about_hwnd, about_title.c_str());
        if (g_about_edit) {
            std::wstring text = BuildAboutText();
            SetWindowTextW(g_about_edit, text.c_str());
        }
    }
    UpdateTrayTooltip();
}

void LoadConfigIntoEditor() {
    if (!g_settings_edit) {
        return;
    }
    std::string text = ReadFileUtf8(ResolveConfigPath());
    if (text.empty()) {
        text = BuildConfigJson(g_config);
    }
    std::wstring wide = Utf8ToWide(text);
    SetWindowTextW(g_settings_edit, wide.c_str());
}

void SaveEditorToConfig() {
    if (!g_settings_edit) {
        return;
    }
    int length = GetWindowTextLengthW(g_settings_edit);
    std::wstring buffer(static_cast<size_t>(length), L'\0');
    GetWindowTextW(g_settings_edit, buffer.data(), length + 1);

    std::string utf8 = WideToUtf8(buffer);
    WriteFileUtf8(ResolveConfigPath(), utf8);
    LoadConfig();
    ApplyConfig(g_overlay_hwnd);
}

LRESULT CALLBACK SettingsProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_CREATE: {
            HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
            g_settings_edit = CreateWindowExW(
                WS_EX_CLIENTEDGE,
                L"EDIT",
                L"",
                WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL,
                0,
                0,
                100,
                100,
                hwnd,
                nullptr,
                GetModuleHandleW(nullptr),
                nullptr
            );
            if (g_settings_edit && font) {
                SendMessageW(g_settings_edit, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            }

            std::wstring save_text = Tr("btn_save", L"Save");
            HWND save_btn = CreateWindowW(
                L"BUTTON",
                save_text.c_str(),
                WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                0,
                0,
                80,
                28,
                hwnd,
                reinterpret_cast<HMENU>(kSettingsSaveId),
                GetModuleHandleW(nullptr),
                nullptr
            );
            if (save_btn && font) {
                SendMessageW(save_btn, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            }

            std::wstring reload_text = Tr("btn_reload", L"Reload");
            HWND reload_btn = CreateWindowW(
                L"BUTTON",
                reload_text.c_str(),
                WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                0,
                0,
                80,
                28,
                hwnd,
                reinterpret_cast<HMENU>(kSettingsReloadId),
                GetModuleHandleW(nullptr),
                nullptr
            );
            if (reload_btn && font) {
                SendMessageW(reload_btn, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            }

            LoadConfigIntoEditor();
            return 0;
        }
        case WM_SIZE: {
            int width = LOWORD(lparam);
            int height = HIWORD(lparam);
            int margin = 12;
            int button_h = 28;
            int button_w = 90;
            int spacing = 8;

            if (g_settings_edit) {
                MoveWindow(g_settings_edit, margin, margin, width - margin * 2, height - margin * 2 - button_h - spacing, TRUE);
            }
            HWND save_btn = GetDlgItem(hwnd, kSettingsSaveId);
            HWND reload_btn = GetDlgItem(hwnd, kSettingsReloadId);
            if (save_btn) {
                MoveWindow(save_btn, margin, height - margin - button_h, button_w, button_h, TRUE);
            }
            if (reload_btn) {
                MoveWindow(reload_btn, margin + button_w + spacing, height - margin - button_h, button_w, button_h, TRUE);
            }
            return 0;
        }
        case WM_COMMAND: {
            switch (LOWORD(wparam)) {
                case kSettingsSaveId:
                    SaveEditorToConfig();
                    return 0;
                case kSettingsReloadId:
                    LoadConfigIntoEditor();
                    return 0;
                default:
                    break;
            }
            break;
        }
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            g_settings_hwnd = nullptr;
            g_settings_edit = nullptr;
            return 0;
        default:
            break;
    }
    return DefWindowProc(hwnd, msg, wparam, lparam);
}

void ShowSettingsWindow(HWND owner) {
    if (!g_settings_hwnd) {
        std::wstring title = Tr("settings_title", L"Eye Break Settings");
        g_settings_hwnd = CreateWindowExW(
            0,
            L"EyeBreakSettings",
            title.c_str(),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            720,
            520,
            owner,
            nullptr,
            GetModuleHandleW(nullptr),
            nullptr
        );
    }
    if (g_settings_hwnd) {
        ShowWindow(g_settings_hwnd, SW_SHOW);
        SetForegroundWindow(g_settings_hwnd);
        LoadConfigIntoEditor();
    }
}


std::wstring BuildAboutText() {
    std::wstring text;
    text += Tr("about_header", L"Eye Break");
    text += L"\r\n\r\n";
    text += Tr("about_usage", L"Usage:");
    text += L"\r\n";
    text += Tr("about_tray_right", L"- Tray right-click: menu");
    text += L"\r\n";
    text += Tr("about_tray_double", L"- Double-click: open settings");
    text += L"\r\n";
    text += Tr("about_tray_single", L"- Single click: show overlay");
    text += L"\r\n\r\n";
    text += Tr("about_config", L"Config file:");
    text += L"\r\n";
    text += ResolveConfigPath();
    text += L"\r\n\r\n";
    text += Tr("about_keys", L"Key options:");
    text += L"\r\n";
    text += Tr("about_lang", L"- language: en/zh");
    text += L"\r\n";
    text += Tr("about_autostart", L"- autostart: true/false");
    text += L"\r\n";
    text += Tr("about_work_interval", L"- work_interval_minutes: 0 disables periodic");
    text += L"\r\n";
    text += Tr("about_basic", L"- rest_seconds, fade_ms, fps");
    text += L"\r\n";
    text += Tr("about_visual", L"- visual_mode: breathing | image | image+breathing");
    text += L"\r\n";
    text += Tr("about_image", L"- image_path, image_mode: fit/fill/center");
    text += L"\r\n";
    text += Tr("about_breath", L"- image_opacity, breath_cycle_ms, breath_min_radius, breath_max_radius, breath_opacity");
    text += L"\r\n";
    return text;
}


LRESULT CALLBACK AboutProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_CREATE: {
            HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
            g_about_edit = CreateWindowExW(
                WS_EX_CLIENTEDGE,
                L"EDIT",
                L"",
                WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL | ES_READONLY,
                0,
                0,
                100,
                100,
                hwnd,
                nullptr,
                GetModuleHandleW(nullptr),
                nullptr
            );
            if (g_about_edit && font) {
                SendMessageW(g_about_edit, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
            }
            std::wstring text = BuildAboutText();
            SetWindowTextW(g_about_edit, text.c_str());
            return 0;
        }
        case WM_SIZE: {
            int width = LOWORD(lparam);
            int height = HIWORD(lparam);
            int margin = 12;
            if (g_about_edit) {
                MoveWindow(g_about_edit, margin, margin, width - margin * 2, height - margin * 2, TRUE);
            }
            return 0;
        }
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            g_about_hwnd = nullptr;
            g_about_edit = nullptr;
            return 0;
        default:
            break;
    }
    return DefWindowProc(hwnd, msg, wparam, lparam);
}

void ShowAboutWindow(HWND owner) {
    if (!g_about_hwnd) {
        std::wstring title = Tr("about_title", L"About Eye Break");
        g_about_hwnd = CreateWindowExW(
            0,
            L"EyeBreakAbout",
            title.c_str(),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            640,
            420,
            owner,
            nullptr,
            GetModuleHandleW(nullptr),
            nullptr
        );
    }
    if (g_about_hwnd) {
        ShowWindow(g_about_hwnd, SW_SHOW);
        SetForegroundWindow(g_about_hwnd);
        if (g_about_edit) {
            std::wstring text = BuildAboutText();
            SetWindowTextW(g_about_edit, text.c_str());
        }
    }
}


LRESULT CALLBACK TrayProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == g_tray_msg) {
        UINT mouse_msg = LOWORD(lparam);
        if (mouse_msg == NIN_POPUPOPEN) {
            UpdateTrayTooltip();
        } else if (mouse_msg == WM_RBUTTONUP || mouse_msg == WM_CONTEXTMENU) {
            ShowTrayMenu(hwnd);
        } else if (mouse_msg == WM_LBUTTONDBLCLK) {
            if (g_tray_click_pending) {
                KillTimer(hwnd, kTrayClickTimerId);
                g_tray_click_pending = false;
            }
            ShowSettingsWindow(hwnd);
        } else if (mouse_msg == WM_LBUTTONUP) {
            g_tray_click_pending = true;
            SetTimer(hwnd, kTrayClickTimerId, 250, nullptr);
        }
        return 0;
    }

    switch (msg) {
        case NIN_POPUPOPEN:
            UpdateTrayTooltip();
            return 0;
        case WM_COMMAND:
            HandleTrayCommand(LOWORD(wparam));
            return 0;
        case WM_TIMER:
            if (wparam == kTrayClickTimerId) {
                KillTimer(hwnd, kTrayClickTimerId);
                if (g_tray_click_pending) {
                    g_tray_click_pending = false;
                    StartOverlay();
                }
                return 0;
            }
            if (wparam == kWorkTimerId) {
                if (!g_overlay_visible) {
                    StartOverlay();
                }
                return 0;
            }
            break;
        case WM_CLOSE:
            HandleTrayCommand(kCmdExit);
            return 0;
        case WM_DESTROY:
            RemoveTrayIcon(hwnd);
            PostQuitMessage(0);
            return 0;
        default:
            break;
    }
    return DefWindowProc(hwnd, msg, wparam, lparam);
}

LRESULT CALLBACK OverlayProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
        case WM_CREATE: {
            ResetTiming();
            return 0;
        }
        case WM_TIMER: {
            if (!g_overlay_visible) {
                return 0;
            }
            LARGE_INTEGER now{};
            QueryPerformanceCounter(&now);
            double last = static_cast<double>(g_state.last.QuadPart) / static_cast<double>(g_state.freq.QuadPart);
            double current = static_cast<double>(now.QuadPart) / static_cast<double>(g_state.freq.QuadPart);
            double dt = current - last;
            g_state.last = now;

            UpdateState(dt, hwnd);
            InvalidateRect(hwnd, nullptr, FALSE);
            return 0;
        }
        case WM_PAINT: {
            PAINTSTRUCT ps{};
            BeginPaint(hwnd, &ps);
            Render(hwnd);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_SIZE: {
            if (g_render_target) {
                UINT width = LOWORD(lparam);
                UINT height = HIWORD(lparam);
                g_render_target->Resize(D2D1::SizeU(width, height));
            }
            return 0;
        }
        case WM_DPICHANGED: {
            RECT* suggested = reinterpret_cast<RECT*>(lparam);
            SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                suggested->right - suggested->left,
                suggested->bottom - suggested->top,
                SWP_NOZORDER | SWP_NOACTIVATE);
            if (g_render_target) {
                UINT dpi = HIWORD(wparam);
                g_render_target->SetDpi(static_cast<float>(dpi), static_cast<float>(dpi));
            }
            return 0;
        }
        case WM_LBUTTONDOWN:
        case WM_RBUTTONDOWN:
        case WM_MBUTTONDOWN:
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN: {
            if (g_overlay_visible) {
                RequestFadeOut();
            }
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_DESTROY:
            g_overlay_hwnd = nullptr;
            return 0;
        default:
            return DefWindowProc(hwnd, msg, wparam, lparam);
    }
    return DefWindowProc(hwnd, msg, wparam, lparam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    LoadConfig();
    LoadLocalization();
    ApplyAutostart();

    HRESULT com_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(com_hr)) {
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&g_wic_factory));
    }

    WNDCLASSEX wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = OverlayProc;
    wc.hInstance = instance;
    wc.lpszClassName = L"EyeBreakOverlay";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    wc.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));

    if (!RegisterClassEx(&wc)) {
        if (SUCCEEDED(com_hr)) {
            SafeRelease(g_wic_factory);
            CoUninitialize();
        }
        return 0;
    }

    WNDCLASSEX sc{};
    sc.cbSize = sizeof(sc);
    sc.lpfnWndProc = SettingsProc;
    sc.hInstance = instance;
    sc.lpszClassName = L"EyeBreakSettings";
    sc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    sc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    sc.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    RegisterClassEx(&sc);

    WNDCLASSEX tc{};
    tc.cbSize = sizeof(tc);
    tc.lpfnWndProc = TrayProc;
    tc.hInstance = instance;
    tc.lpszClassName = L"EyeBreakTray";
    tc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    tc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    tc.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    RegisterClassEx(&tc);

    WNDCLASSEX ac{};
    ac.cbSize = sizeof(ac);
    ac.lpfnWndProc = AboutProc;
    ac.hInstance = instance;
    ac.lpszClassName = L"EyeBreakAbout";
    ac.hCursor = LoadCursor(nullptr, IDC_ARROW);
    ac.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    ac.hIconSm = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
    RegisterClassEx(&ac);

    g_tray_hwnd = CreateWindowEx(
        0,
        tc.lpszClassName,
        L"Eye Break Tray",
        WS_OVERLAPPED,
        0,
        0,
        0,
        0,
        nullptr,
        nullptr,
        instance,
        nullptr
    );

    if (!g_tray_hwnd) {
        if (SUCCEEDED(com_hr)) {
            SafeRelease(g_wic_factory);
            CoUninitialize();
        }
        return 0;
    }

    ShowWindow(g_tray_hwnd, SW_HIDE);
    AddTrayIcon(g_tray_hwnd);
    UpdateWorkTimer();

    RECT monitor = GetPrimaryMonitorRect();
    int width = monitor.right - monitor.left;
    int height = monitor.bottom - monitor.top;

    g_overlay_hwnd = CreateWindowEx(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
        wc.lpszClassName,
        L"Eye Break",
        WS_POPUP,
        monitor.left,
        monitor.top,
        width,
        height,
        nullptr,
        nullptr,
        instance,
        nullptr
    );

    if (!g_overlay_hwnd) {
        if (SUCCEEDED(com_hr)) {
            SafeRelease(g_wic_factory);
            CoUninitialize();
        }
        return 0;
    }

    ShowWindow(g_overlay_hwnd, SW_HIDE);
    UpdateWindow(g_overlay_hwnd);

    StartOverlay();

    MSG msg{};
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    if (g_overlay_hwnd) {
        KillTimer(g_overlay_hwnd, kTimerId);
    }
    DiscardDeviceResources();
    SafeRelease(g_wic_factory);
    if (SUCCEEDED(com_hr)) {
        CoUninitialize();
    }
    return 0;
}

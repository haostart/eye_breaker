#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <mach-o/dyld.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <climits>
#include <limits.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include <unistd.h>

@class AppController;

namespace {
constexpr double kMinFadeSeconds = 0.05;
constexpr double kMinRestSeconds = 1.0;
constexpr double kMinFps = 5.0;
constexpr double kMaxFps = 60.0;
constexpr double kPi = 3.141592653589793;
constexpr double kTrayClickDelaySeconds = 0.25;
constexpr double kDeferSeconds = 30.0;
constexpr double kImageModeMaxFps = 1.0;
constexpr double kLowPowerMaxFps = 10.0;

enum class VisualMode { Breathing, Image, ImageBreathing };
enum class ImageMode { Fit, Fill, Center };
enum class Language { English, Chinese };

struct Color {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
    float a = 1.0f;
};

struct Config {
    Language language = Language::English;
    bool autostart = false;
    bool pause_on_fullscreen = true;
    double work_interval_minutes = 20.0;
    double rest_seconds = 20.0;
    double fade_ms = 600.0;
    double fps = 20.0;

    Color bg_color = {0x11 / 255.0f, 0x11 / 255.0f, 0x11 / 255.0f, 1.0f};
    Color text_color = {0xCF / 255.0f, 0xCF / 255.0f, 0xCF / 255.0f, 1.0f};
    std::string message = "Look far and blink";

    VisualMode visual_mode = VisualMode::Image;
    std::string image_path = "assets/bg.png";
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
    std::chrono::steady_clock::time_point last{};
};

Config g_config;
AppState g_state;
std::string g_config_path;
bool g_overlay_visible = false;
bool g_periodic_suppressed = false;
std::unordered_map<std::string, std::string> g_i18n;
std::chrono::steady_clock::time_point g_next_overlay_deadline{};
bool g_next_overlay_valid = false;

static NSImage* g_image = nil;
static NSSize g_image_size = NSZeroSize;
static NSFont* g_message_font = nil;
static NSFont* g_countdown_font = nil;
static NSParagraphStyle* g_paragraph_style = nil;
static NSColor* g_text_color = nil;

static AppController* g_app = nil;

NSString* ToNSString(const std::string& value) {
    if (value.empty()) {
        return @"";
    }
    return [NSString stringWithUTF8String:value.c_str()];
}

std::string FromNSString(NSString* value) {
    if (!value) {
        return {};
    }
    const char* utf8 = [value UTF8String];
    return utf8 ? std::string(utf8) : std::string();
}

std::string GetExePath() {
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string buffer(size, '\0');
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
        return {};
    }
    buffer.resize(std::strlen(buffer.c_str()));
    return buffer;
}

std::string GetExeDirectory() {
    std::string exe = GetExePath();
    if (exe.empty()) {
        return ".";
    }
    std::filesystem::path p(exe);
    if (p.has_parent_path()) {
        return p.parent_path().string();
    }
    return ".";
}

std::string GetCurrentDirectoryPath() {
    char buffer[PATH_MAX] = {};
    if (!getcwd(buffer, sizeof(buffer))) {
        return ".";
    }
    return std::string(buffer);
}

std::string JoinPath(const std::string& dir, const std::string& file) {
    if (dir.empty()) {
        return file;
    }
    return (std::filesystem::path(dir) / std::filesystem::path(file)).string();
}

bool FileExists(const std::string& path) {
    std::error_code ec;
    return std::filesystem::is_regular_file(std::filesystem::path(path), ec);
}

std::string NormalizePathSeparators(std::string value) {
    std::replace(value.begin(), value.end(), '\\', '/');
    return value;
}

std::string GetAppSupportDir() {
    @autoreleasepool {
        NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString* base = paths.firstObject ?: NSHomeDirectory();
        NSString* dir = [base stringByAppendingPathComponent:@"eye_breaker"];
        std::filesystem::create_directories(std::filesystem::path([dir UTF8String]));
        return FromNSString(dir);
    }
}

std::string GetLaunchAgentsDir() {
    @autoreleasepool {
        NSString* base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents"];
        std::filesystem::create_directories(std::filesystem::path([base UTF8String]));
        return FromNSString(base);
    }
}

std::string ResolveConfigPath() {
    if (!g_config_path.empty()) {
        return g_config_path;
    }
    std::string exe_path = JoinPath(GetExeDirectory(), "config.json");
    if (FileExists(exe_path)) {
        g_config_path = exe_path;
        return g_config_path;
    }
    std::string cwd_path = JoinPath(GetCurrentDirectoryPath(), "config.json");
    if (FileExists(cwd_path)) {
        g_config_path = cwd_path;
        return g_config_path;
    }
    std::string app_support = JoinPath(GetAppSupportDir(), "config.json");
    g_config_path = app_support;
    return g_config_path;
}

std::string ReadFileUtf8(const std::string& path) {
    std::ifstream file(std::filesystem::path(path), std::ios::binary);
    if (!file) {
        return {};
    }
    std::string data((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    if (data.size() >= 3 &&
        static_cast<unsigned char>(data[0]) == 0xEF &&
        static_cast<unsigned char>(data[1]) == 0xBB &&
        static_cast<unsigned char>(data[2]) == 0xBF) {
        data.erase(0, 3);
    }
    return data;
}

bool WriteFileUtf8(const std::string& path, const std::string& data) {
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

std::string FindAssetsDir() {
    @autoreleasepool {
        NSString* resource_path = [[NSBundle mainBundle] resourcePath];
        if (resource_path) {
            std::string assets = JoinPath(FromNSString(resource_path), "assets");
            if (FileExists(JoinPath(assets, "lang_en.txt")) || FileExists(JoinPath(assets, "lang_zh.txt"))) {
                return assets;
            }
        }
    }

    std::string dir = GetExeDirectory();
    for (int i = 0; i < 5; ++i) {
        std::string assets = JoinPath(dir, "assets");
        if (FileExists(JoinPath(assets, "lang_en.txt")) || FileExists(JoinPath(assets, "lang_zh.txt"))) {
            return assets;
        }
        std::filesystem::path p(dir);
        if (!p.has_parent_path()) {
            break;
        }
        dir = p.parent_path().string();
        if (dir.empty()) {
            break;
        }
    }
    return {};
}

std::string ResolvePathRelativeTo(const std::string& base_dir, const std::string& input) {
    if (input.empty()) {
        return input;
    }
    std::filesystem::path p(input);
    if (p.is_absolute()) {
        return input;
    }
    std::filesystem::path base(base_dir.empty() ? GetExeDirectory() : base_dir);
    return (base / p).lexically_normal().string();
}

std::string ResolveImagePath(const std::string& config_dir, const std::string& input) {
    if (input.empty()) {
        return input;
    }
    std::string normalized = NormalizePathSeparators(input);
    std::filesystem::path p(normalized);
    if (p.is_absolute()) {
        return normalized;
    }

    std::string candidate = ResolvePathRelativeTo(config_dir, normalized);
    if (FileExists(candidate)) {
        return candidate;
    }

    std::string assets_dir = FindAssetsDir();
    if (!assets_dir.empty()) {
        std::string alt;
        if (normalized.rfind("assets/", 0) == 0) {
            std::filesystem::path base = std::filesystem::path(assets_dir).parent_path();
            alt = (base / std::filesystem::path(normalized)).lexically_normal().string();
        } else {
            alt = (std::filesystem::path(assets_dir) / std::filesystem::path(normalized)).lexically_normal().string();
        }
        if (FileExists(alt)) {
            return alt;
        }
    }

    return candidate;
}

void NormalizeConfig(Config& cfg, const std::string& config_dir) {
    if (cfg.work_interval_minutes < 0.0) {
        cfg.work_interval_minutes = 0.0;
    }

    cfg.image_path = ResolveImagePath(config_dir, cfg.image_path);
    cfg.fps = std::clamp(cfg.fps, kMinFps, kMaxFps);
    cfg.fade_ms = std::max(cfg.fade_ms, kMinFadeSeconds * 1000.0);
    cfg.rest_seconds = std::max(cfg.rest_seconds, kMinRestSeconds);
    cfg.image_opacity = std::clamp(cfg.image_opacity, 0.0f, 1.0f);
    cfg.breath_opacity = std::clamp(cfg.breath_opacity, 0.0f, 1.0f);
}

double EffectiveOverlayFps() {
    double fps = g_config.fps;
    if (g_config.visual_mode == VisualMode::Image) {
        fps = std::min(fps, kImageModeMaxFps);
    }
    if (@available(macOS 10.10, *)) {
        if ([NSProcessInfo processInfo].lowPowerModeEnabled) {
            fps = std::min(fps, kLowPowerMaxFps);
        }
    }
    if (fps < 1.0) {
        fps = 1.0;
    }
    return fps;
}

void UpdateTextResources() {
    g_message_font = [NSFont systemFontOfSize:28.0 weight:NSFontWeightRegular];
    g_countdown_font = [NSFont systemFontOfSize:72.0 weight:NSFontWeightSemibold];
    NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    g_paragraph_style = style;
    g_text_color = [NSColor colorWithCalibratedRed:g_config.text_color.r
                                             green:g_config.text_color.g
                                              blue:g_config.text_color.b
                                             alpha:g_config.text_color.a];
}

void LoadLocalization() {
    g_i18n.clear();
    std::string assets_dir = FindAssetsDir();
    if (assets_dir.empty()) {
        return;
    }
    std::string file = JoinPath(assets_dir, g_config.language == Language::Chinese ? "lang_zh.txt" : "lang_en.txt");
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
                    g_i18n[key] = value;
                }
            }
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
}

std::string Tr(const char* key, const char* fallback) {
    if (key) {
        auto it = g_i18n.find(key);
        if (it != g_i18n.end()) {
            return it->second;
        }
    }
    return fallback ? std::string(fallback) : std::string();
}

NSString* TrNSString(const char* key, const char* fallback) {
    return ToNSString(Tr(key, fallback));
}

bool ParseHexColor(const std::string& text, Color* color) {
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
    color->r = r / 255.0f;
    color->g = g / 255.0f;
    color->b = b / 255.0f;
    color->a = 1.0f;
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

    std::string message = EscapeJsonString(cfg.message);
    std::string image_path = EscapeJsonString(cfg.image_path);

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
    out << "  \"pause_on_fullscreen\": " << (cfg.pause_on_fullscreen ? "true" : "false") << ",\n";
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
    std::string config_path = ResolveConfigPath();
    std::string config_dir;
    try {
        config_dir = std::filesystem::path(config_path).parent_path().string();
    } catch (...) {
        config_dir = GetExeDirectory();
    }
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
        if (ExtractBool(json, "pause_on_fullscreen", &flag)) {
            cfg.pause_on_fullscreen = flag;
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
            cfg.message = str;
        }
        if (ExtractString(json, "bg_color", &str)) {
            Color color{};
            if (ParseHexColor(str, &color)) {
                cfg.bg_color = color;
            }
        }
        if (ExtractString(json, "text_color", &str)) {
            Color color{};
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
            cfg.image_path = str;
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

    NormalizeConfig(cfg, config_dir);
    g_config = cfg;
}

void ResetTiming() {
    g_state.last = std::chrono::steady_clock::now();
}

void RequestFadeOut() {
    if (g_state.phase != AppState::Phase::FadeOut) {
        g_state.phase = AppState::Phase::FadeOut;
        g_state.phase_elapsed = 0.0;
    }
}

bool UpdateState(double dt) {
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
                return false;
            }
            g_state.opacity = o;
            break;
        }
    }
    return true;
}

std::string BuildTrayTooltip() {
    if (g_overlay_visible) {
        return Tr("tray_tooltip_active", "Eye Break (active)");
    }
    if (g_config.work_interval_minutes <= 0.0 || !g_next_overlay_valid) {
        return Tr("tray_tooltip_disabled", "Eye Break (periodic off)");
    }
    if (g_periodic_suppressed) {
        return Tr("tray_tooltip_paused", "Eye Break (paused: fullscreen)");
    }

    auto now = std::chrono::steady_clock::now();
    if (g_next_overlay_deadline <= now) {
        return Tr("tray_tooltip_soon", "Eye Break (soon)");
    }

    auto remaining = g_next_overlay_deadline - now;
    auto target = std::chrono::system_clock::now() +
        std::chrono::duration_cast<std::chrono::system_clock::duration>(remaining);
    std::time_t tt = std::chrono::system_clock::to_time_t(target);
    std::tm local{};
    localtime_r(&tt, &local);
    char buf[16] = {};
    std::strftime(buf, sizeof(buf), "%H:%M:%S", &local);
    std::string prefix = Tr("tray_tooltip_next", "Next break: ");
    return prefix + buf;
}

void UpdateTrayTooltip();
void UpdateWorkTimer();
void ApplyAutostart();
void UpdateLocalizedWindowTexts();
void ApplyConfig();

std::string EscapeXml(const std::string& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (char c : value) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '"': out += "&quot;"; break;
            case '\'': out += "&apos;"; break;
            default: out.push_back(c); break;
        }
    }
    return out;
}

void RunLaunchctl(const std::vector<std::string>& args) {
    @autoreleasepool {
        NSTask* task = [[NSTask alloc] init];
        task.launchPath = @"/bin/launchctl";
        NSMutableArray<NSString*>* ns_args = [NSMutableArray arrayWithCapacity:args.size()];
        for (const auto& arg : args) {
            [ns_args addObject:ToNSString(arg)];
        }
        task.arguments = ns_args;
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        @try {
            [task launch];
            [task waitUntilExit];
        } @catch (NSException*) {
        }
    }
}

void ApplyAutostart() {
    std::string label = "com.eye_breaker.autostart";
    std::string plist_path = JoinPath(GetLaunchAgentsDir(), label + ".plist");

    if (!g_config.autostart) {
        RunLaunchctl({"bootout", "gui/" + std::to_string(getuid()) + "/" + label});
        std::error_code ec;
        std::filesystem::remove(std::filesystem::path(plist_path), ec);
        return;
    }

    std::string exec_path = GetExePath();
    if (exec_path.empty()) {
        return;
    }

    std::ostringstream out;
    out << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    out << "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n";
    out << "<plist version=\"1.0\">\n";
    out << "<dict>\n";
    out << "  <key>Label</key><string>" << EscapeXml(label) << "</string>\n";
    out << "  <key>ProgramArguments</key>\n";
    out << "  <array>\n";
    out << "    <string>" << EscapeXml(exec_path) << "</string>\n";
    out << "  </array>\n";
    out << "  <key>RunAtLoad</key><true/>\n";
    out << "</dict>\n";
    out << "</plist>\n";

    WriteFileUtf8(plist_path, out.str());

    std::string gui_target = "gui/" + std::to_string(getuid());
    RunLaunchctl({"bootout", gui_target + "/" + label});
    RunLaunchctl({"bootstrap", gui_target, plist_path});
}

bool IsFrontmostAppFullscreenFallback() {
    @autoreleasepool {
        NSRunningApplication* front = [NSWorkspace sharedWorkspace].frontmostApplication;
        if (!front) {
            return false;
        }
        if (front.processIdentifier == getpid()) {
            return false;
        }

        NSScreen* screen = [NSScreen mainScreen];
        if (!screen) {
            return false;
        }
        CGRect screen_frame = screen.frame;
        constexpr double kTol = 2.0;

        CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!window_list) {
            return false;
        }
        bool fullscreen = false;
        NSArray* windows = CFBridgingRelease(window_list);
        for (NSDictionary* info in windows) {
            NSNumber* pid = info[(id)kCGWindowOwnerPID];
            if (!pid || pid.intValue != front.processIdentifier) {
                continue;
            }
            NSNumber* layer = info[(id)kCGWindowLayer];
            if (layer && layer.intValue != 0) {
                continue;
            }
            NSDictionary* bounds = info[(id)kCGWindowBounds];
            if (!bounds) {
                continue;
            }
            CGRect win = CGRectNull;
            if (!CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)bounds, &win)) {
                continue;
            }
            if (std::abs(win.origin.x - screen_frame.origin.x) <= kTol &&
                std::abs(win.origin.y - screen_frame.origin.y) <= kTol &&
                std::abs(win.size.width - screen_frame.size.width) <= kTol &&
                std::abs(win.size.height - screen_frame.size.height) <= kTol) {
                fullscreen = true;
                break;
            }
        }
        return fullscreen;
    }
}

bool ShouldSuppressPeriodicOverlay() {
    if (!g_config.pause_on_fullscreen) {
        return false;
    }
    return IsFrontmostAppFullscreenFallback();
}

void ReloadImage() {
    g_image = nil;
    g_image_size = NSZeroSize;
    if (g_config.visual_mode == VisualMode::Breathing) {
        return;
    }
    if (g_config.image_path.empty()) {
        return;
    }
    @autoreleasepool {
        NSString* path = ToNSString(g_config.image_path);
        NSImage* img = [[NSImage alloc] initWithContentsOfFile:path];
        if (!img) {
            return;
        }
        g_image = img;
        g_image_size = img.size;
    }
}

std::string BuildAboutText() {
    std::string text;
    text += Tr("about_header", "Eye Break");
    text += "\n\n";
    text += Tr("about_usage", "Usage:");
    text += "\n";
    text += Tr("about_tray_right", "- Tray right-click: menu");
    text += "\n";
    text += Tr("about_tray_double", "- Double-click: open settings");
    text += "\n";
    text += Tr("about_tray_single", "- Single click: show overlay");
    text += "\n\n";
    text += Tr("about_config", "Config file:");
    text += "\n";
    text += ResolveConfigPath();
    text += "\n\n";
    text += Tr("about_keys", "Key options:");
    text += "\n";
    text += Tr("about_lang", "- language: en/zh");
    text += "\n";
    text += Tr("about_autostart", "- autostart: true/false");
    text += "\n";
    text += Tr("about_work_interval", "- work_interval_minutes: 0 disables periodic");
    text += "\n";
    text += Tr("about_basic", "- rest_seconds, fade_ms, fps");
    text += "\n";
    text += Tr("about_visual", "- visual_mode: breathing | image | image+breathing");
    text += "\n";
    text += Tr("about_image", "- image_path, image_mode: fit/fill/center");
    text += "\n";
    text += Tr("about_breath", "- image_opacity, breath_cycle_ms, breath_min_radius, breath_max_radius, breath_opacity");
    text += "\n";
    return text;
}

std::string GetConfigDir() {
    std::string config_path = ResolveConfigPath();
    try {
        return std::filesystem::path(config_path).parent_path().string();
    } catch (...) {
        return GetExeDirectory();
    }
}

double ReadDoubleField(NSTextField* field, double fallback) {
    if (!field) {
        return fallback;
    }
    std::string text = FromNSString(field.stringValue);
    char* end = nullptr;
    double value = std::strtod(text.c_str(), &end);
    if (end == text.c_str()) {
        return fallback;
    }
    return value;
}

double ReadRoundedField(NSTextField* field, double fallback) {
    double value = ReadDoubleField(field, fallback);
    return std::round(value);
}

NSString* FormatNumber(double value) {
    char buf[64] = {};
    std::snprintf(buf, sizeof(buf), "%.2f", value);
    std::string text(buf);
    size_t dot = text.find('.');
    if (dot != std::string::npos) {
        while (!text.empty() && text.back() == '0') {
            text.pop_back();
        }
        if (!text.empty() && text.back() == '.') {
            text.pop_back();
        }
    }
    return [NSString stringWithUTF8String:text.c_str()];
}

void LoadConfigIntoControls();

} // namespace

@interface OverlayWindow : NSWindow
@end

@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}
@end

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface OverlayView : NSView
@end

@implementation OverlayView
- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent*)event {
    RequestFadeOut();
}

- (void)rightMouseDown:(NSEvent*)event {
    RequestFadeOut();
}

- (void)otherMouseDown:(NSEvent*)event {
    RequestFadeOut();
}

- (void)keyDown:(NSEvent*)event {
    RequestFadeOut();
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (!g_overlay_visible) {
        return;
    }

    NSRect bounds = self.bounds;

    NSColor* bg = [NSColor colorWithCalibratedRed:g_config.bg_color.r
                                            green:g_config.bg_color.g
                                             blue:g_config.bg_color.b
                                            alpha:1.0f];
    [bg setFill];
    NSRectFill(bounds);

    if (g_image && g_config.visual_mode != VisualMode::Breathing) {
        float img_w = static_cast<float>(g_image_size.width);
        float img_h = static_cast<float>(g_image_size.height);
        if (img_w > 0.0f && img_h > 0.0f) {
            float width = static_cast<float>(bounds.size.width);
            float height = static_cast<float>(bounds.size.height);
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
            NSRect dest = NSMakeRect(x, y, draw_w, draw_h);
            [g_image drawInRect:dest
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver
                       fraction:g_config.image_opacity
                 respectFlipped:YES
                          hints:nil];
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

        NSColor* stroke = [NSColor colorWithCalibratedRed:g_config.text_color.r
                                                   green:g_config.text_color.g
                                                    blue:g_config.text_color.b
                                                   alpha:alpha];
        [stroke setStroke];
        NSBezierPath* path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(
            bounds.size.width * 0.5f - radius,
            bounds.size.height * 0.45f - radius,
            radius * 2.0f,
            radius * 2.0f
        )];
        path.lineWidth = 3.0f;
        [path stroke];
    }

    int seconds_left = static_cast<int>(std::ceil(g_state.rest_remaining));
    if (seconds_left < 0) {
        seconds_left = 0;
    }

    NSString* message = ToNSString(g_config.message);
    NSString* countdown = [NSString stringWithFormat:@"%d s", seconds_left];

    NSParagraphStyle* style = g_paragraph_style;
    NSColor* text_color = g_text_color;
    NSFont* message_font = g_message_font;
    NSFont* countdown_font = g_countdown_font;
    if (!style || !text_color || !message_font || !countdown_font) {
        UpdateTextResources();
        style = g_paragraph_style;
        text_color = g_text_color;
        message_font = g_message_font;
        countdown_font = g_countdown_font;
    }

    NSDictionary* message_attrs = @{
        NSFontAttributeName: message_font,
        NSForegroundColorAttributeName: text_color,
        NSParagraphStyleAttributeName: style
    };
    NSDictionary* countdown_attrs = @{
        NSFontAttributeName: countdown_font,
        NSForegroundColorAttributeName: text_color,
        NSParagraphStyleAttributeName: style
    };

    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    NSRect message_rect = NSMakeRect(0.0, height * 0.4f - 40.0f, width, 60.0f);
    NSRect countdown_rect = NSMakeRect(0.0, height * 0.5f - 20.0f, width, 160.0f);

    [message drawInRect:message_rect withAttributes:message_attrs];
    [countdown drawInRect:countdown_rect withAttributes:countdown_attrs];
}
@end

@interface AppController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem* statusItem;
@property (nonatomic, strong) NSMenu* statusMenu;
@property (nonatomic, strong) NSMenuItem* menuOpenSettings;
@property (nonatomic, strong) NSMenuItem* menuShowOverlay;
@property (nonatomic, strong) NSMenuItem* menuReloadConfig;
@property (nonatomic, strong) NSMenuItem* menuAbout;
@property (nonatomic, strong) NSMenuItem* menuExit;
@property (nonatomic, strong) OverlayWindow* overlayWindow;
@property (nonatomic, strong) OverlayView* overlayView;
@property (nonatomic, strong) NSWindow* settingsWindow;
@property (nonatomic, strong) NSScrollView* settingsScrollView;
@property (nonatomic, strong) NSView* settingsFormView;
@property (nonatomic, strong) NSPopUpButton* languagePopup;
@property (nonatomic, strong) NSButton* autostartCheckbox;
@property (nonatomic, strong) NSButton* pauseFullscreenCheckbox;
@property (nonatomic, strong) NSTextField* workIntervalField;
@property (nonatomic, strong) NSTextField* restSecondsField;
@property (nonatomic, strong) NSTextField* fadeMsField;
@property (nonatomic, strong) NSTextField* fpsField;
@property (nonatomic, strong) NSTextField* messageField;
@property (nonatomic, strong) NSPopUpButton* visualModePopup;
@property (nonatomic, strong) NSTextField* imagePathField;
@property (nonatomic, strong) NSButton* imageBrowseButton;
@property (nonatomic, strong) NSPopUpButton* imageModePopup;
@property (nonatomic, strong) NSTextField* imageOpacityField;
@property (nonatomic, strong) NSTextField* breathCycleField;
@property (nonatomic, strong) NSTextField* breathMinRadiusField;
@property (nonatomic, strong) NSTextField* breathMaxRadiusField;
@property (nonatomic, strong) NSTextField* breathOpacityField;
@property (nonatomic, strong) NSTextField* labelSectionGeneral;
@property (nonatomic, strong) NSTextField* labelSectionContent;
@property (nonatomic, strong) NSTextField* labelSectionBreathing;
@property (nonatomic, strong) NSTextField* labelLanguage;
@property (nonatomic, strong) NSTextField* labelAutostart;
@property (nonatomic, strong) NSTextField* labelPauseFullscreen;
@property (nonatomic, strong) NSTextField* labelWorkInterval;
@property (nonatomic, strong) NSTextField* labelRestSeconds;
@property (nonatomic, strong) NSTextField* labelFadeMs;
@property (nonatomic, strong) NSTextField* labelFps;
@property (nonatomic, strong) NSTextField* labelMessage;
@property (nonatomic, strong) NSTextField* labelVisualMode;
@property (nonatomic, strong) NSTextField* labelImagePath;
@property (nonatomic, strong) NSTextField* labelImageMode;
@property (nonatomic, strong) NSTextField* labelImageOpacity;
@property (nonatomic, strong) NSTextField* labelBreathCycle;
@property (nonatomic, strong) NSTextField* labelBreathMinRadius;
@property (nonatomic, strong) NSTextField* labelBreathMaxRadius;
@property (nonatomic, strong) NSTextField* labelBreathOpacity;
@property (nonatomic, strong) NSButton* settingsSaveButton;
@property (nonatomic, strong) NSButton* settingsReloadButton;
@property (nonatomic, strong) NSWindow* aboutWindow;
@property (nonatomic, strong) NSTextView* aboutTextView;
@property (nonatomic, strong) NSTimer* overlayTimer;
@property (nonatomic, strong) NSTimer* workTimer;
@property (nonatomic, strong) NSTimer* trayClickTimer;
@end

@implementation AppController
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    LoadConfig();
    [self setupStatusItem];
    [self setupOverlayWindow];
    ApplyConfig();
    [self startOverlay];

    NSWorkspace* ws = [NSWorkspace sharedWorkspace];
    [[ws notificationCenter] addObserver:self selector:@selector(handleScreenSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [[ws notificationCenter] addObserver:self selector:@selector(handleScreenWake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePowerState:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return NO;
}

- (NSTextField*)makeLabel:(NSString*)text bold:(BOOL)bold {
    NSTextField* label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = text ?: @"";
    label.editable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.selectable = NO;
    label.font = bold ? [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:13];
    return label;
}

- (NSTextField*)makeTextField {
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.font = [NSFont systemFontOfSize:13];
    return field;
}

- (NSPopUpButton*)makePopup {
    NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.font = [NSFont systemFontOfSize:13];
    return popup;
}

- (NSButton*)makeCheckbox {
    NSButton* button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.buttonType = NSButtonTypeSwitch;
    button.title = @"";
    return button;
}

- (void)layoutSettingsForm {
    if (!self.settingsFormView || !self.settingsScrollView) {
        return;
    }
    CGFloat width = self.settingsScrollView.contentSize.width;
    CGFloat margin = 16.0;
    CGFloat row_h = 24.0;
    CGFloat label_w = 180.0;
    CGFloat spacing = 10.0;
    CGFloat section_spacing = 18.0;
    CGFloat control_x = margin + label_w + 12.0;
    CGFloat control_w = width - control_x - margin;
    if (control_w < 120.0) {
        control_w = 120.0;
    }

    CGFloat y = margin;

    auto place_section = [&](NSTextField* label) {
        if (!label) return;
        label.frame = NSMakeRect(margin, y, width - margin * 2, row_h);
        y += row_h + spacing;
    };
    auto place_row = [&](NSTextField* label, NSView* control) {
        if (label) {
            label.frame = NSMakeRect(margin, y, label_w, row_h);
        }
        if (control) {
            control.frame = NSMakeRect(control_x, y - 2.0, control_w, row_h + 4.0);
        }
        y += row_h + spacing;
    };

    place_section(self.labelSectionGeneral);
    place_row(self.labelLanguage, self.languagePopup);
    place_row(self.labelAutostart, self.autostartCheckbox);
    place_row(self.labelPauseFullscreen, self.pauseFullscreenCheckbox);
    place_row(self.labelWorkInterval, self.workIntervalField);
    place_row(self.labelRestSeconds, self.restSecondsField);
    place_row(self.labelFadeMs, self.fadeMsField);
    place_row(self.labelFps, self.fpsField);

    y += section_spacing;
    place_section(self.labelSectionContent);
    place_row(self.labelMessage, self.messageField);
    place_row(self.labelVisualMode, self.visualModePopup);

    if (self.labelImagePath || self.imagePathField || self.imageBrowseButton) {
        if (self.labelImagePath) {
            self.labelImagePath.frame = NSMakeRect(margin, y, label_w, row_h);
        }
        CGFloat browse_w = 80.0;
        CGFloat field_w = control_w - browse_w - 8.0;
        if (field_w < 120.0) {
            field_w = 120.0;
        }
        if (self.imagePathField) {
            self.imagePathField.frame = NSMakeRect(control_x, y - 2.0, field_w, row_h + 4.0);
        }
        if (self.imageBrowseButton) {
            self.imageBrowseButton.frame = NSMakeRect(control_x + field_w + 8.0, y - 2.0, browse_w, row_h + 4.0);
        }
        y += row_h + spacing;
    }

    place_row(self.labelImageMode, self.imageModePopup);
    place_row(self.labelImageOpacity, self.imageOpacityField);

    y += section_spacing;
    place_section(self.labelSectionBreathing);
    place_row(self.labelBreathCycle, self.breathCycleField);
    place_row(self.labelBreathMinRadius, self.breathMinRadiusField);
    place_row(self.labelBreathMaxRadius, self.breathMaxRadiusField);
    place_row(self.labelBreathOpacity, self.breathOpacityField);

    CGFloat content_height = y + margin;
    self.settingsFormView.frame = NSMakeRect(0, 0, width, content_height);
}

- (void)buildSettingsFormInContent:(NSView*)content {
    NSRect bounds = content.bounds;
    CGFloat margin = 12.0;
    CGFloat button_h = 28.0;
    CGFloat button_w = 90.0;
    CGFloat spacing = 8.0;

    self.settingsScrollView = [[NSScrollView alloc] initWithFrame:bounds];
    self.settingsScrollView.hasVerticalScroller = YES;
    self.settingsScrollView.hasHorizontalScroller = NO;
    self.settingsScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.settingsFormView = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, bounds.size.width, bounds.size.height)];
    self.settingsScrollView.documentView = self.settingsFormView;
    [content addSubview:self.settingsScrollView];

    self.labelSectionGeneral = [self makeLabel:TrNSString("settings_section_general", "General") bold:YES];
    self.labelSectionContent = [self makeLabel:TrNSString("settings_section_content", "Content") bold:YES];
    self.labelSectionBreathing = [self makeLabel:TrNSString("settings_section_breathing", "Breathing") bold:YES];

    self.labelLanguage = [self makeLabel:TrNSString("label_language", "Language") bold:NO];
    self.labelAutostart = [self makeLabel:TrNSString("label_autostart", "Auto start") bold:NO];
    self.labelPauseFullscreen = [self makeLabel:TrNSString("label_pause_fullscreen", "Pause on fullscreen") bold:NO];
    self.labelWorkInterval = [self makeLabel:TrNSString("label_work_interval", "Work interval (minutes)") bold:NO];
    self.labelRestSeconds = [self makeLabel:TrNSString("label_rest_seconds", "Rest seconds") bold:NO];
    self.labelFadeMs = [self makeLabel:TrNSString("label_fade_ms", "Fade (ms)") bold:NO];
    self.labelFps = [self makeLabel:TrNSString("label_fps", "FPS") bold:NO];
    self.labelMessage = [self makeLabel:TrNSString("label_message", "Message") bold:NO];
    self.labelVisualMode = [self makeLabel:TrNSString("label_visual_mode", "Visual mode") bold:NO];
    self.labelImagePath = [self makeLabel:TrNSString("label_image_path", "Image path") bold:NO];
    self.labelImageMode = [self makeLabel:TrNSString("label_image_mode", "Image mode") bold:NO];
    self.labelImageOpacity = [self makeLabel:TrNSString("label_image_opacity", "Image opacity") bold:NO];
    self.labelBreathCycle = [self makeLabel:TrNSString("label_breath_cycle", "Breath cycle (ms)") bold:NO];
    self.labelBreathMinRadius = [self makeLabel:TrNSString("label_breath_min_radius", "Breath min radius") bold:NO];
    self.labelBreathMaxRadius = [self makeLabel:TrNSString("label_breath_max_radius", "Breath max radius") bold:NO];
    self.labelBreathOpacity = [self makeLabel:TrNSString("label_breath_opacity", "Breath opacity") bold:NO];

    self.languagePopup = [self makePopup];
    [self.languagePopup addItemWithTitle:TrNSString("option_lang_en", "English")];
    [self.languagePopup addItemWithTitle:TrNSString("option_lang_zh", "Chinese")];

    self.autostartCheckbox = [self makeCheckbox];
    self.pauseFullscreenCheckbox = [self makeCheckbox];
    self.workIntervalField = [self makeTextField];
    self.restSecondsField = [self makeTextField];
    self.fadeMsField = [self makeTextField];
    self.fpsField = [self makeTextField];
    self.messageField = [self makeTextField];

    self.visualModePopup = [self makePopup];
    [self.visualModePopup addItemWithTitle:TrNSString("option_visual_breathing", "Breathing")];
    [self.visualModePopup addItemWithTitle:TrNSString("option_visual_image", "Image")];
    [self.visualModePopup addItemWithTitle:TrNSString("option_visual_both", "Image + Breathing")];

    self.imagePathField = [self makeTextField];
    self.imageBrowseButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.imageBrowseButton.title = TrNSString("btn_browse", "Browse");
    self.imageBrowseButton.bezelStyle = NSBezelStyleRounded;
    self.imageBrowseButton.target = self;
    self.imageBrowseButton.action = @selector(browseImage:);

    self.imageModePopup = [self makePopup];
    [self.imageModePopup addItemWithTitle:TrNSString("option_image_fit", "Fit")];
    [self.imageModePopup addItemWithTitle:TrNSString("option_image_fill", "Fill")];
    [self.imageModePopup addItemWithTitle:TrNSString("option_image_center", "Center")];

    self.imageOpacityField = [self makeTextField];
    self.breathCycleField = [self makeTextField];
    self.breathMinRadiusField = [self makeTextField];
    self.breathMaxRadiusField = [self makeTextField];
    self.breathOpacityField = [self makeTextField];

    for (NSView* view in @[
        self.labelSectionGeneral, self.labelSectionContent, self.labelSectionBreathing,
        self.labelLanguage, self.labelAutostart, self.labelPauseFullscreen, self.labelWorkInterval,
        self.labelRestSeconds, self.labelFadeMs, self.labelFps, self.labelMessage, self.labelVisualMode,
        self.labelImagePath, self.labelImageMode, self.labelImageOpacity, self.labelBreathCycle,
        self.labelBreathMinRadius, self.labelBreathMaxRadius, self.labelBreathOpacity,
        self.languagePopup, self.autostartCheckbox, self.pauseFullscreenCheckbox, self.workIntervalField,
        self.restSecondsField, self.fadeMsField, self.fpsField, self.messageField, self.visualModePopup,
        self.imagePathField, self.imageBrowseButton, self.imageModePopup, self.imageOpacityField,
        self.breathCycleField, self.breathMinRadiusField, self.breathMaxRadiusField, self.breathOpacityField
    ]) {
        if (view) {
            [self.settingsFormView addSubview:view];
        }
    }

    self.settingsSaveButton = [[NSButton alloc] initWithFrame:NSMakeRect(margin, margin, button_w, button_h)];
    self.settingsSaveButton.title = TrNSString("btn_save", "Save");
    self.settingsSaveButton.bezelStyle = NSBezelStyleRounded;
    self.settingsSaveButton.target = self;
    self.settingsSaveButton.action = @selector(saveSettings:);
    self.settingsSaveButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.settingsSaveButton];

    self.settingsReloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(margin + button_w + spacing, margin, button_w, button_h)];
    self.settingsReloadButton.title = TrNSString("btn_reload", "Reload");
    self.settingsReloadButton.bezelStyle = NSBezelStyleRounded;
    self.settingsReloadButton.target = self;
    self.settingsReloadButton.action = @selector(reloadSettings:);
    self.settingsReloadButton.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [content addSubview:self.settingsReloadButton];

    self.settingsScrollView.frame = NSMakeRect(margin, margin + button_h + spacing,
                                              bounds.size.width - margin * 2,
                                              bounds.size.height - margin * 2 - button_h - spacing);
    [self layoutSettingsForm];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSButton* button = self.statusItem.button;
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    NSString* assets_dir = ToNSString(FindAssetsDir());
    NSString* resource_dir = [[NSBundle mainBundle] resourcePath];
    NSImage* icon = nil;
    NSMutableArray<NSString*>* candidates = [NSMutableArray array];
    if (resource_dir.length > 0) {
        [candidates addObject:[resource_dir stringByAppendingPathComponent:@"icon.icns"]];
    }
    if (assets_dir.length > 0) {
        [candidates addObject:[assets_dir stringByAppendingPathComponent:@"icon.icns"]];
        [candidates addObject:[assets_dir stringByAppendingPathComponent:@"icon.png"]];
        [candidates addObject:[assets_dir stringByAppendingPathComponent:@"icon.ico"]];
    }
    for (NSString* path in candidates) {
        icon = [[NSImage alloc] initWithContentsOfFile:path];
        if (icon) {
            break;
        }
    }
    if (!icon) {
        icon = [NSImage imageNamed:NSImageNameActionTemplate];
    }
    if (icon) {
        CGFloat size = [NSStatusBar systemStatusBar].thickness;
        icon.size = NSMakeSize(size, size);
        [icon setTemplate:YES];
    }
    button.image = icon;

    self.statusMenu = [[NSMenu alloc] initWithTitle:@"Eye Break Menu"];
    self.statusMenu.delegate = self;
    self.menuOpenSettings = [[NSMenuItem alloc] initWithTitle:@"Open Settings" action:@selector(openSettings:) keyEquivalent:@""];
    self.menuShowOverlay = [[NSMenuItem alloc] initWithTitle:@"Show Overlay" action:@selector(showOverlayNow:) keyEquivalent:@""];
    self.menuReloadConfig = [[NSMenuItem alloc] initWithTitle:@"Reload Config" action:@selector(reloadConfig:) keyEquivalent:@""];
    self.menuAbout = [[NSMenuItem alloc] initWithTitle:@"About" action:@selector(openAbout:) keyEquivalent:@""];
    self.menuExit = [[NSMenuItem alloc] initWithTitle:@"Exit" action:@selector(exitApp:) keyEquivalent:@""];

    for (NSMenuItem* item in @[self.menuOpenSettings, self.menuShowOverlay, self.menuReloadConfig, self.menuAbout]) {
        item.target = self;
        [self.statusMenu addItem:item];
    }
    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    self.menuExit.target = self;
    [self.statusMenu addItem:self.menuExit];
}

- (void)setupOverlayWindow {
    NSScreen* screen = [NSScreen mainScreen];
    NSRect frame = screen ? screen.frame : NSMakeRect(0, 0, 800, 600);
    self.overlayWindow = [[OverlayWindow alloc] initWithContentRect:frame
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
    self.overlayWindow.opaque = NO;
    self.overlayWindow.backgroundColor = [NSColor clearColor];
    self.overlayWindow.level = NSScreenSaverWindowLevel;
    self.overlayWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.overlayWindow.ignoresMouseEvents = NO;
    self.overlayWindow.hasShadow = NO;
    self.overlayWindow.releasedWhenClosed = NO;

    self.overlayView = [[OverlayView alloc] initWithFrame:frame];
    self.overlayWindow.contentView = self.overlayView;
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    NSEvent* event = [NSApp currentEvent];
    if (event.type == NSEventTypeRightMouseUp || event.buttonNumber == 1) {
        self.statusItem.menu = self.statusMenu;
        [self.statusItem.button performClick:nil];
        return;
    }

    if (event.clickCount >= 2) {
        if (self.trayClickTimer) {
            [self.trayClickTimer invalidate];
            self.trayClickTimer = nil;
        }
        [self openSettings:nil];
        return;
    }

    if (self.trayClickTimer) {
        [self.trayClickTimer invalidate];
        self.trayClickTimer = nil;
    }
    self.trayClickTimer = [NSTimer scheduledTimerWithTimeInterval:kTrayClickDelaySeconds
                                                           target:self
                                                         selector:@selector(handleTraySingleClick)
                                                         userInfo:nil
                                                          repeats:NO];
}

- (void)handleTraySingleClick {
    self.trayClickTimer = nil;
    [self startOverlay];
}

- (void)handleScreenSleep:(NSNotification*)notification {
    (void)notification;
    if (g_overlay_visible) {
        [self stopOverlay];
    }
    [self invalidateWorkTimer];
    g_next_overlay_valid = false;
    g_periodic_suppressed = false;
    UpdateTrayTooltip();
}

- (void)handleScreenWake:(NSNotification*)notification {
    (void)notification;
    UpdateWorkTimer();
}

- (void)handlePowerState:(NSNotification*)notification {
    (void)notification;
    if (g_overlay_visible) {
        [self rescheduleOverlayTimer];
    }
}

- (void)setStatusToolTip:(NSString*)tip {
    self.statusItem.button.toolTip = tip;
}

- (void)startOverlay {
    if (!self.overlayWindow) {
        [self setupOverlayWindow];
    }
    NSScreen* screen = [NSScreen mainScreen];
    if (screen) {
        [self.overlayWindow setFrame:screen.frame display:NO];
        [self.overlayView setFrame:screen.frame];
    }

    g_state.phase = AppState::Phase::FadeIn;
    g_state.phase_elapsed = 0.0;
    g_state.opacity = 0.0;
    g_state.total_elapsed = 0.0;
    g_state.rest_remaining = g_config.rest_seconds;

    ResetTiming();
    g_overlay_visible = true;
    g_periodic_suppressed = false;

    [self.overlayWindow setAlphaValue:0.0];
    [NSApp activateIgnoringOtherApps:YES];
    [self.overlayWindow makeKeyAndOrderFront:nil];

    [self rescheduleOverlayTimer];
    [self invalidateWorkTimer];
    UpdateTrayTooltip();
}

- (void)stopOverlay {
    if (!g_overlay_visible) {
        return;
    }
    g_overlay_visible = false;
    [self invalidateOverlayTimer];
    [self.overlayWindow orderOut:nil];
    UpdateWorkTimer();
}

- (void)rescheduleOverlayTimer {
    [self invalidateOverlayTimer];
    double fps = EffectiveOverlayFps();
    double interval = 1.0 / fps;
    if (interval < 0.01) {
        interval = 0.01;
    }
    self.overlayTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                         target:self
                                                       selector:@selector(overlayTimerTick:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)invalidateOverlayTimer {
    if (self.overlayTimer) {
        [self.overlayTimer invalidate];
        self.overlayTimer = nil;
    }
}

- (void)overlayTimerTick:(NSTimer*)timer {
    (void)timer;
    if (!g_overlay_visible) {
        return;
    }

    auto now = std::chrono::steady_clock::now();
    double dt = std::chrono::duration<double>(now - g_state.last).count();
    g_state.last = now;

    if (!UpdateState(dt)) {
        [self stopOverlay];
        return;
    }

    [self.overlayWindow setAlphaValue:static_cast<CGFloat>(g_state.opacity)];
    [self.overlayView setNeedsDisplay:YES];
}

- (void)invalidateWorkTimer {
    if (self.workTimer) {
        [self.workTimer invalidate];
        self.workTimer = nil;
    }
}

- (void)scheduleWorkTimer:(double)seconds {
    [self invalidateWorkTimer];
    self.workTimer = [NSTimer scheduledTimerWithTimeInterval:seconds
                                                      target:self
                                                    selector:@selector(workTimerFired:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)workTimerFired:(NSTimer*)timer {
    (void)timer;
    if (g_overlay_visible) {
        return;
    }
    if (ShouldSuppressPeriodicOverlay()) {
        g_periodic_suppressed = true;
        double defer = kDeferSeconds;
        g_next_overlay_deadline = std::chrono::steady_clock::now() +
            std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(defer));
        g_next_overlay_valid = true;
        [self scheduleWorkTimer:defer];
        UpdateTrayTooltip();
        return;
    }
    g_periodic_suppressed = false;
    [self startOverlay];
}

- (void)openSettings:(id)sender {
    (void)sender;
    if (!self.settingsWindow) {
        NSRect frame = NSMakeRect(0, 0, 720, 520);
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
        self.settingsWindow.title = TrNSString("settings_title", "Eye Break Settings");
        self.settingsWindow.releasedWhenClosed = NO;
        self.settingsWindow.delegate = self;
        [self buildSettingsFormInContent:self.settingsWindow.contentView];
    }

    [self.settingsWindow center];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    LoadConfigIntoControls();
}

- (void)reloadSettings:(id)sender {
    (void)sender;
    LoadConfig();
    LoadConfigIntoControls();
}

- (void)saveSettings:(id)sender {
    (void)sender;
    Config cfg = g_config;
    if (self.languagePopup) {
        cfg.language = (self.languagePopup.indexOfSelectedItem == 1) ? Language::Chinese : Language::English;
    }
    if (self.autostartCheckbox) {
        cfg.autostart = (self.autostartCheckbox.state == NSControlStateValueOn);
    }
    if (self.pauseFullscreenCheckbox) {
        cfg.pause_on_fullscreen = (self.pauseFullscreenCheckbox.state == NSControlStateValueOn);
    }
    if (self.workIntervalField) {
        cfg.work_interval_minutes = ReadRoundedField(self.workIntervalField, cfg.work_interval_minutes);
    }
    if (self.restSecondsField) {
        cfg.rest_seconds = ReadRoundedField(self.restSecondsField, cfg.rest_seconds);
    }
    if (self.fadeMsField) {
        cfg.fade_ms = ReadRoundedField(self.fadeMsField, cfg.fade_ms);
    }
    if (self.fpsField) {
        cfg.fps = ReadRoundedField(self.fpsField, cfg.fps);
    }
    if (self.messageField) {
        cfg.message = FromNSString(self.messageField.stringValue);
    }
    if (self.visualModePopup) {
        switch (self.visualModePopup.indexOfSelectedItem) {
            case 0:
                cfg.visual_mode = VisualMode::Breathing;
                break;
            case 1:
                cfg.visual_mode = VisualMode::Image;
                break;
            default:
                cfg.visual_mode = VisualMode::ImageBreathing;
                break;
        }
    }
    if (self.imagePathField) {
        cfg.image_path = FromNSString(self.imagePathField.stringValue);
    }
    if (self.imageModePopup) {
        switch (self.imageModePopup.indexOfSelectedItem) {
            case 0:
                cfg.image_mode = ImageMode::Fit;
                break;
            case 1:
                cfg.image_mode = ImageMode::Fill;
                break;
            default:
                cfg.image_mode = ImageMode::Center;
                break;
        }
    }
    if (self.imageOpacityField) {
        cfg.image_opacity = static_cast<float>(ReadDoubleField(self.imageOpacityField, cfg.image_opacity));
    }
    if (self.breathCycleField) {
        cfg.breath_cycle_ms = ReadRoundedField(self.breathCycleField, cfg.breath_cycle_ms);
    }
    if (self.breathMinRadiusField) {
        cfg.breath_min_radius = static_cast<float>(ReadRoundedField(self.breathMinRadiusField, cfg.breath_min_radius));
    }
    if (self.breathMaxRadiusField) {
        cfg.breath_max_radius = static_cast<float>(ReadRoundedField(self.breathMaxRadiusField, cfg.breath_max_radius));
    }
    if (self.breathOpacityField) {
        cfg.breath_opacity = static_cast<float>(ReadDoubleField(self.breathOpacityField, cfg.breath_opacity));
    }

    NormalizeConfig(cfg, GetConfigDir());
    WriteFileUtf8(ResolveConfigPath(), BuildConfigJson(cfg));
    g_config = cfg;
    ApplyConfig();
    LoadConfigIntoControls();
}

- (void)browseImage:(id)sender {
    (void)sender;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypePNG, UTTypeJPEG, UTTypeTIFF, UTTypeBMP, UTTypeGIF, UTTypeHEIC, UTTypeWebP];
    if ([panel runModal] == NSModalResponseOK) {
        NSURL* url = panel.URL;
        if (url && self.imagePathField) {
            self.imagePathField.stringValue = url.path ?: @"";
        }
    }
}

- (void)openAbout:(id)sender {
    (void)sender;
    if (!self.aboutWindow) {
        NSRect frame = NSMakeRect(0, 0, 640, 420);
        self.aboutWindow = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        self.aboutWindow.title = TrNSString("about_title", "About Eye Break");
        self.aboutWindow.releasedWhenClosed = NO;

        NSView* content = self.aboutWindow.contentView;
        NSRect bounds = content.bounds;
        CGFloat margin = 12.0;

        NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:bounds];
        scroll.hasVerticalScroller = YES;
        scroll.hasHorizontalScroller = NO;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        self.aboutTextView = [[NSTextView alloc] initWithFrame:bounds];
        self.aboutTextView.editable = NO;
        self.aboutTextView.selectable = YES;
        self.aboutTextView.font = [NSFont systemFontOfSize:12.0];
        scroll.documentView = self.aboutTextView;
        [content addSubview:scroll];

        scroll.frame = NSMakeRect(margin, margin, bounds.size.width - margin * 2, bounds.size.height - margin * 2);
    }
    self.aboutTextView.string = ToNSString(BuildAboutText());
    [self.aboutWindow center];
    [self.aboutWindow makeKeyAndOrderFront:nil];
}

- (void)showOverlayNow:(id)sender {
    (void)sender;
    [self startOverlay];
}

- (void)reloadConfig:(id)sender {
    (void)sender;
    LoadConfig();
    ApplyConfig();
}

- (void)exitApp:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)windowDidResize:(NSNotification*)notification {
    if (notification.object == self.settingsWindow) {
        [self layoutSettingsForm];
    }
}

- (void)menuDidClose:(NSMenu*)menu {
    if (menu == self.statusMenu) {
        self.statusItem.menu = nil;
    }
}

- (void)windowWillClose:(NSNotification*)notification {
    if (notification.object == self.settingsWindow) {
        self.settingsWindow = nil;
        self.settingsScrollView = nil;
        self.settingsFormView = nil;
        self.languagePopup = nil;
        self.autostartCheckbox = nil;
        self.pauseFullscreenCheckbox = nil;
        self.workIntervalField = nil;
        self.restSecondsField = nil;
        self.fadeMsField = nil;
        self.fpsField = nil;
        self.messageField = nil;
        self.visualModePopup = nil;
        self.imagePathField = nil;
        self.imageBrowseButton = nil;
        self.imageModePopup = nil;
        self.imageOpacityField = nil;
        self.breathCycleField = nil;
        self.breathMinRadiusField = nil;
        self.breathMaxRadiusField = nil;
        self.breathOpacityField = nil;
        self.labelSectionGeneral = nil;
        self.labelSectionContent = nil;
        self.labelSectionBreathing = nil;
        self.labelLanguage = nil;
        self.labelAutostart = nil;
        self.labelPauseFullscreen = nil;
        self.labelWorkInterval = nil;
        self.labelRestSeconds = nil;
        self.labelFadeMs = nil;
        self.labelFps = nil;
        self.labelMessage = nil;
        self.labelVisualMode = nil;
        self.labelImagePath = nil;
        self.labelImageMode = nil;
        self.labelImageOpacity = nil;
        self.labelBreathCycle = nil;
        self.labelBreathMinRadius = nil;
        self.labelBreathMaxRadius = nil;
        self.labelBreathOpacity = nil;
        self.settingsSaveButton = nil;
        self.settingsReloadButton = nil;
    } else if (notification.object == self.aboutWindow) {
        self.aboutWindow = nil;
        self.aboutTextView = nil;
    }
}

@end

namespace {

void ApplyConfig() {
    ReloadImage();
    UpdateTextResources();
    if (g_overlay_visible && g_app) {
        [g_app performSelectorOnMainThread:@selector(rescheduleOverlayTimer) withObject:nil waitUntilDone:NO];
    }
    LoadLocalization();
    UpdateWorkTimer();
    ApplyAutostart();
    UpdateLocalizedWindowTexts();
}

void UpdateTrayTooltip() {
    if (!g_app) {
        return;
    }
    NSString* tip = ToNSString(BuildTrayTooltip());
    [g_app performSelectorOnMainThread:@selector(setStatusToolTip:) withObject:tip waitUntilDone:NO];
}

void UpdateWorkTimer() {
    if (!g_app) {
        return;
    }
    [g_app invalidateWorkTimer];
    if (g_config.work_interval_minutes <= 0.0) {
        g_next_overlay_valid = false;
        g_periodic_suppressed = false;
        UpdateTrayTooltip();
        return;
    }
    double seconds = g_config.work_interval_minutes * 60.0;
    if (seconds < 1.0) {
        seconds = 1.0;
    }
    if (seconds > static_cast<double>(INT_MAX)) {
        seconds = static_cast<double>(INT_MAX);
    }
    g_next_overlay_deadline = std::chrono::steady_clock::now() +
        std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(seconds));
    g_next_overlay_valid = true;
    [g_app scheduleWorkTimer:seconds];
    g_periodic_suppressed = false;
    UpdateTrayTooltip();
}

void UpdateLocalizedWindowTexts() {
    if (!g_app) {
        return;
    }
    g_app.menuOpenSettings.title = TrNSString("menu_open_settings", "Open Settings");
    g_app.menuShowOverlay.title = TrNSString("menu_show_overlay", "Show Overlay Now");
    g_app.menuReloadConfig.title = TrNSString("menu_reload_config", "Reload Config");
    g_app.menuAbout.title = TrNSString("menu_about", "About");
    g_app.menuExit.title = TrNSString("menu_exit", "Exit");

    if (g_app.settingsWindow) {
        g_app.settingsWindow.title = TrNSString("settings_title", "Eye Break Settings");
        if (g_app.settingsSaveButton) {
            g_app.settingsSaveButton.title = TrNSString("btn_save", "Save");
        }
        if (g_app.settingsReloadButton) {
            g_app.settingsReloadButton.title = TrNSString("btn_reload", "Reload");
        }
        if (g_app.labelSectionGeneral) {
            g_app.labelSectionGeneral.stringValue = TrNSString("settings_section_general", "General");
        }
        if (g_app.labelSectionContent) {
            g_app.labelSectionContent.stringValue = TrNSString("settings_section_content", "Content");
        }
        if (g_app.labelSectionBreathing) {
            g_app.labelSectionBreathing.stringValue = TrNSString("settings_section_breathing", "Breathing");
        }
        if (g_app.labelLanguage) {
            g_app.labelLanguage.stringValue = TrNSString("label_language", "Language");
        }
        if (g_app.labelAutostart) {
            g_app.labelAutostart.stringValue = TrNSString("label_autostart", "Auto start");
        }
        if (g_app.labelPauseFullscreen) {
            g_app.labelPauseFullscreen.stringValue = TrNSString("label_pause_fullscreen", "Pause on fullscreen");
        }
        if (g_app.labelWorkInterval) {
            g_app.labelWorkInterval.stringValue = TrNSString("label_work_interval", "Work interval (minutes)");
        }
        if (g_app.labelRestSeconds) {
            g_app.labelRestSeconds.stringValue = TrNSString("label_rest_seconds", "Rest seconds");
        }
        if (g_app.labelFadeMs) {
            g_app.labelFadeMs.stringValue = TrNSString("label_fade_ms", "Fade (ms)");
        }
        if (g_app.labelFps) {
            g_app.labelFps.stringValue = TrNSString("label_fps", "FPS");
        }
        if (g_app.labelMessage) {
            g_app.labelMessage.stringValue = TrNSString("label_message", "Message");
        }
        if (g_app.labelVisualMode) {
            g_app.labelVisualMode.stringValue = TrNSString("label_visual_mode", "Visual mode");
        }
        if (g_app.labelImagePath) {
            g_app.labelImagePath.stringValue = TrNSString("label_image_path", "Image path");
        }
        if (g_app.labelImageMode) {
            g_app.labelImageMode.stringValue = TrNSString("label_image_mode", "Image mode");
        }
        if (g_app.labelImageOpacity) {
            g_app.labelImageOpacity.stringValue = TrNSString("label_image_opacity", "Image opacity");
        }
        if (g_app.labelBreathCycle) {
            g_app.labelBreathCycle.stringValue = TrNSString("label_breath_cycle", "Breath cycle (ms)");
        }
        if (g_app.labelBreathMinRadius) {
            g_app.labelBreathMinRadius.stringValue = TrNSString("label_breath_min_radius", "Breath min radius");
        }
        if (g_app.labelBreathMaxRadius) {
            g_app.labelBreathMaxRadius.stringValue = TrNSString("label_breath_max_radius", "Breath max radius");
        }
        if (g_app.labelBreathOpacity) {
            g_app.labelBreathOpacity.stringValue = TrNSString("label_breath_opacity", "Breath opacity");
        }
        if (g_app.imageBrowseButton) {
            g_app.imageBrowseButton.title = TrNSString("btn_browse", "Browse");
        }
        if (g_app.languagePopup && g_app.languagePopup.numberOfItems >= 2) {
            [g_app.languagePopup itemAtIndex:0].title = TrNSString("option_lang_en", "English");
            [g_app.languagePopup itemAtIndex:1].title = TrNSString("option_lang_zh", "Chinese");
        }
        if (g_app.visualModePopup && g_app.visualModePopup.numberOfItems >= 3) {
            [g_app.visualModePopup itemAtIndex:0].title = TrNSString("option_visual_breathing", "Breathing");
            [g_app.visualModePopup itemAtIndex:1].title = TrNSString("option_visual_image", "Image");
            [g_app.visualModePopup itemAtIndex:2].title = TrNSString("option_visual_both", "Image + Breathing");
        }
        if (g_app.imageModePopup && g_app.imageModePopup.numberOfItems >= 3) {
            [g_app.imageModePopup itemAtIndex:0].title = TrNSString("option_image_fit", "Fit");
            [g_app.imageModePopup itemAtIndex:1].title = TrNSString("option_image_fill", "Fill");
            [g_app.imageModePopup itemAtIndex:2].title = TrNSString("option_image_center", "Center");
        }
        [g_app layoutSettingsForm];
    }
    if (g_app.aboutWindow) {
        g_app.aboutWindow.title = TrNSString("about_title", "About Eye Break");
        if (g_app.aboutTextView) {
            g_app.aboutTextView.string = ToNSString(BuildAboutText());
        }
    }
    UpdateTrayTooltip();
}

void LoadConfigIntoControls() {
    if (!g_app) {
        return;
    }
    if (g_app.languagePopup) {
        [g_app.languagePopup selectItemAtIndex:(g_config.language == Language::Chinese) ? 1 : 0];
    }
    if (g_app.autostartCheckbox) {
        g_app.autostartCheckbox.state = g_config.autostart ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (g_app.pauseFullscreenCheckbox) {
        g_app.pauseFullscreenCheckbox.state = g_config.pause_on_fullscreen ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (g_app.workIntervalField) {
        g_app.workIntervalField.stringValue = FormatNumber(g_config.work_interval_minutes);
    }
    if (g_app.restSecondsField) {
        g_app.restSecondsField.stringValue = FormatNumber(g_config.rest_seconds);
    }
    if (g_app.fadeMsField) {
        g_app.fadeMsField.stringValue = FormatNumber(g_config.fade_ms);
    }
    if (g_app.fpsField) {
        g_app.fpsField.stringValue = FormatNumber(g_config.fps);
    }
    if (g_app.messageField) {
        g_app.messageField.stringValue = ToNSString(g_config.message);
    }
    if (g_app.visualModePopup) {
        int index = 0;
        if (g_config.visual_mode == VisualMode::Image) {
            index = 1;
        } else if (g_config.visual_mode == VisualMode::ImageBreathing) {
            index = 2;
        }
        [g_app.visualModePopup selectItemAtIndex:index];
    }
    if (g_app.imagePathField) {
        g_app.imagePathField.stringValue = ToNSString(g_config.image_path);
    }
    if (g_app.imageModePopup) {
        int index = 0;
        if (g_config.image_mode == ImageMode::Fill) {
            index = 1;
        } else if (g_config.image_mode == ImageMode::Center) {
            index = 2;
        }
        [g_app.imageModePopup selectItemAtIndex:index];
    }
    if (g_app.imageOpacityField) {
        g_app.imageOpacityField.stringValue = FormatNumber(g_config.image_opacity);
    }
    if (g_app.breathCycleField) {
        g_app.breathCycleField.stringValue = FormatNumber(g_config.breath_cycle_ms);
    }
    if (g_app.breathMinRadiusField) {
        g_app.breathMinRadiusField.stringValue = FormatNumber(g_config.breath_min_radius);
    }
    if (g_app.breathMaxRadiusField) {
        g_app.breathMaxRadiusField.stringValue = FormatNumber(g_config.breath_max_radius);
    }
    if (g_app.breathOpacityField) {
        g_app.breathOpacityField.stringValue = FormatNumber(g_config.breath_opacity);
    }
}

} // namespace

int main(int argc, const char* argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppController* controller = [[AppController alloc] init];
        g_app = controller;
        app.delegate = controller;
        [app run];
    }
    return 0;
}

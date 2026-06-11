// FlatAim.dll — standalone NON-VR Freelook mode for SS2:AE (KEX remaster).
//
// One hook: PlayerTurnTilt (per-frame, game thread). In Freelook mode it captures
// the mouse turn accumulators, zeroes them (so the view does NOT turn), moves a
// screen-space crosshair, projects it to a world ray, and publishes "ss2fa_aim"
// into the KEX config store for the ss2fa.nut Squirrel mod (bullet + weapon follow).
//
// No VR / OpenXR / D3D. Inject with any injector. RVAs confirmed against the same
// SS2:AE build the SS2VR DLL targets (image base 0x140000000).
//
// Tunables live in <game dir>\flataim.ini (re-read each time Freelook turns ON), so
// FoV / sensitivity / sign calibration needs no recompile.

#include <Windows.h>
#include <MinHook.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

// ---- confirmed RVAs (added to GetModuleHandle(nullptr)) ----
constexpr uintptr_t kRvaPlayerTurnTilt        = 0x5126E0;  // FUN_1405126e0
constexpr uintptr_t kRvaKexSetConfigRaw       = 0x8D2C20;  // FUN_1408d2c20 (console "set")
constexpr uintptr_t kRvaCurrentPositionObject = 0x13BC4D0; // DAT_1413bc4d0
constexpr uintptr_t kRvaPickCamOrigin         = 0x1348E68; // DAT_141348e68 (xyz floats)
constexpr uintptr_t kRvaMouseTurnAccumulator  = 0x133F168; // yaw delta consumed by PlayerTurnTilt
constexpr uintptr_t kRvaMouseLookAccumulator  = 0x133F608; // pitch delta
constexpr uintptr_t kRvaHoverCandidate        = 0x4B9A80;  // FUN_1404b9a80: native hover/frob candidate scorer
constexpr uintptr_t kRvaObjectUnderCursor     = 0xF01A50;  // DAT_140f01a50 committed object-under-cursor
constexpr uintptr_t kRvaStagingHoverObject    = 0xF01A54;  // DAT_140f01a54 candidate staged during pick
constexpr uintptr_t kRvaFrobTargetCache       = 0x14D279C; // DAT_1414d279c frob target consumed downstream
constexpr uintptr_t kRvaCursorModeFlag        = 0x14D147C; // nonzero while KEX cursor/UI mode owns cursor
constexpr uintptr_t kRvaKexCursorXFixed       = 0x13179B8; // DAT_1413179b8 cursor X in 16.16 fixed
constexpr uintptr_t kRvaKexCursorYFixed       = 0x1317938; // DAT_141317938 cursor Y in 16.16 fixed
constexpr uintptr_t kRvaShockOverlayOrder     = 0x00B8E210; // gOverlayOrder[50], native Shock overlay draw order
constexpr uintptr_t kRvaShockOverlayOnGhidra  = 0x011E4690; // DAT_1411e4690, Ghidra-xrefed overlay on/off table
constexpr uintptr_t kRvaShockOverlayRects     = 0x011E4850; // packed short Rect[50]: left/top/right/bottom
constexpr uintptr_t kRvaShockOverlayOnMinus50 = kRvaShockOverlayRects - (50 * sizeof(int32_t));
constexpr uintptr_t kRvaShockOverlayOnMinus30 = kRvaShockOverlayRects - (30 * sizeof(int32_t));
constexpr uintptr_t kPositionDataOffset       = 0x11C;
constexpr uintptr_t kObjectYawShortOffset     = 0x58;
constexpr uintptr_t kPitchShortOffset         = 0x12;
constexpr float     kDarkUnitsToDeg           = 360.0f / 65536.0f;
constexpr float     kPI                       = 3.14159265358979f;
constexpr size_t    kShockOverlayCount        = 50;
constexpr int       kShockOverlayCrosshair    = 22;
constexpr COLORREF  kOverlayColorKey          = 0x00FF00FF; // magenta, transparent in the layered overlay
constexpr int       kFreelookPressToggle      = 0;
constexpr int       kFreelookPressHold        = 1;
constexpr int       kEdgePanPressAlways       = 0;
constexpr int       kEdgePanPressOff          = 1;
constexpr int       kEdgePanPressToggle       = 2;
constexpr int       kEdgePanPressHoldLock     = 3;

constexpr uint8_t kPlayerTurnTiltPrologue[] = {
    0x48, 0x89, 0x5C, 0x24, 0x10, 0x55, 0x56, 0x57, 0x41, 0x56, 0x41, 0x57, 0x48, 0x83, 0xEC, 0x30
};
constexpr uint8_t kKexSetConfigRawPrologue[] = {
    0x40, 0x53, 0xB8, 0x20, 0x20, 0x00, 0x00, 0xE8, 0xB4, 0xDF, 0x11, 0x00, 0x48, 0x2B, 0xE0, 0x4D
};
constexpr uint8_t kHoverCandidatePrologue[] = {
    0x48, 0x89, 0x5C, 0x24, 0x10, 0x48, 0x89, 0x74, 0x24, 0x18, 0x57, 0x48, 0x83, 0xEC, 0x40
};

struct ShockOverlayRectRaw {
    int16_t left;
    int16_t top;
    int16_t right;
    int16_t bottom;
};
static_assert(sizeof(ShockOverlayRectRaw) == 8, "Shock overlay rects are packed shorts");

using PlayerTurnTiltFn  = uint64_t(__fastcall*)(int*, int);
using KexSetConfigRawFn = void(__fastcall*)(const char*, int, char*);
using HoverCandidateFn  = void(__fastcall*)(uint32_t, void*, uint32_t);

PlayerTurnTiltFn g_realTurnTilt = nullptr;
KexSetConfigRawFn g_realKexSetConfigRaw = nullptr;
HoverCandidateFn g_realHoverCandidate = nullptr;
uint8_t* g_base = nullptr;
bool g_configOk = false;
bool g_configHookInstalled = false;

std::atomic<bool> g_freeAim{false};
bool g_wasActive = false;
float g_cx = 0.0f, g_cy = 0.0f;
bool  g_cxInit = false;
bool  g_loggedAimPublish = false;
bool  g_loggedAccumReadFailure = false;
bool  g_loggedAngleReadFailure = false;
ULONGLONG g_lastActiveLogMs = 0;
ULONGLONG g_lastSelectionLogMs = 0;
int32_t g_lastLoggedObject = -1;
int32_t g_lastLoggedFrob = -1;
std::atomic<int32_t> g_semanticTarget{0};
std::atomic<ULONGLONG> g_semanticTargetMs{0};
std::atomic<ULONGLONG> g_squirrelAliveMs{0};
std::atomic<int> g_squirrelCanvasW{0};
std::atomic<int> g_squirrelCanvasH{0};
std::atomic<ULONGLONG> g_squirrelCanvasMs{0};
ULONGLONG g_lastSemanticLogMs = 0;
int32_t g_lastLoggedSemanticTarget = -1;
int32_t g_lastWrittenSemanticTarget = -1;
ULONGLONG g_lastBridgeWaitLogMs = 0;
ULONGLONG g_lastConfigBridgeDisabledLogMs = 0;
ULONGLONG g_lastNativeCursorLogMs = 0;
int g_lastLoggedNativeCursorX = -1;
int g_lastLoggedNativeCursorY = -1;
std::atomic<bool> g_needPublishInvalidAim{true};
ULONGLONG g_lastNativeBracketProbeLogMs = 0;
uint32_t g_lastNativeBracketProbeCandidate = 0xFFFFFFFFu;
int32_t g_lastNativeBracketProbeObject = -1;
int32_t g_lastNativeBracketProbeStaging = -1;
int32_t g_lastNativeBracketProbeFrob = -1;
ULONGLONG g_lastEdgePanLogMs = 0;
ULONGLONG g_lastNativeCrosshairRectProbeLogMs = 0;

// ---- tunables (flataim.ini, [flataim]) ----
int   g_toggleVk = VK_F5;
int   g_freelookPressType = kFreelookPressToggle;
int   g_autoDisplay = 1;
float g_fovDeg = 74.0f;
float g_screenW = 1920.0f;
float g_screenH = 1080.0f;
float g_sensX = 12.0f;
float g_sensY = 12.0f;
float g_yawSign = 1.0f;        // crosshair X follow direction
float g_pitchSign = 1.0f;      // crosshair Y follow direction
float g_worldYawSign = 1.0f;   // fallback ray heading offset sign
float g_worldPitchSign = -1.0f; // fallback ray pitch offset sign
float g_worldYawOffsetDeg = 0.0f;
float g_worldPitchOffsetDeg = 0.0f;
int   g_edgePanEnabled = 1;
int   g_edgePanVk = VK_F6;
int   g_edgePanPressType = kEdgePanPressAlways;
bool  g_edgePanToggleActive = true;
bool  g_edgePanPrevDown = false;
float g_edgePanMarginX = 0.12f;
float g_edgePanMarginY = 0.12f;
float g_edgePanMaxYawAccum = 0.75f;
float g_edgePanMaxPitchAccum = 0.55f;
float g_edgePanCurve = 2.0f;
float g_edgePanYawSign = 1.0f;
float g_edgePanPitchSign = 1.0f;
int   g_edgePanLog = 0;
int   g_projectileMode = 2;
int   g_projectileNativeSkipCreate = 1;
int   g_projViewFrame = 1;
int   g_projSkipFacing = 0;
int   g_projSkipVel = 0;
int   g_projFacingMode = 1;
int   g_aimVelocityMode = 7;
int   g_aimLog = 0;
float g_projectileHeadingSign = 1.0f;
float g_projectilePitchSign = -1.0f;
float g_projectileHeadingOffsetDeg = 0.0f;
float g_projectilePitchOffsetDeg = 0.0f;
float g_weaponHeadingSign = -1.0f;
float g_weaponPitchSign = -1.0f;
float g_weaponBankDeg = 0.0f;
int   g_weaponLockHeading = 0;
int   g_weaponLockPitch = 0;
int   g_weaponLockBank = 0;
int   g_weaponFollowMode = 7; // 1=CameraObj angle, 2=offset diagnostic, 3=pitch-compensated angle, 4=hybrid, 5=rig aimPoint, 6=screen-axis decomposition, 7=world-space proxy
int   g_weaponScreenAxisVariant = 0;
int   g_weaponProxyHideNative = 1;
int   g_weaponProxyFacingMode = 8;
float g_weaponProxyScale = 1.0f;
float g_weaponProxyNativeHideScale = 0.001f;
float g_weaponProxyForward = 0.0f;
float g_weaponProxyLeft = 0.0f;
float g_weaponProxyUp = 0.0f;
float g_weaponProxyHeadingOffset = 0.0f;
float g_weaponProxyPitchOffset = 0.0f;
float g_weaponProxyBankOffset = 0.0f;
float g_weaponProxyLookDistance = 40.0f;
float g_weaponProxyRollSign = -1.0f;
int   g_weaponProxyFlipX = 0;
int   g_weaponProxyAxisLog = 0;
int   g_weaponProxyAxisDraw = 0;
float g_weaponProxyAxisLen = 1.25f;
int   g_weaponEffectFollow = 1;
int   g_weaponEffectRecreate = 1;
int   g_weaponEffectLog = 0;
int   g_weaponProxyPivotEnable = 1;
int   g_weaponViewRotate = 1;  // 0 = gun model holds its neutral (view-centered) pose; aim/projectiles still track
int   g_weaponProxyPivotAllWeapons = 1;
float g_weaponProxyPivotLongForward = -0.75f;
float g_weaponProxyPivotLongLeft = 0.0f;
float g_weaponProxyPivotLongUp = 0.0f;
int   g_meleeEnable = 1;
int   g_meleeOrientationMode = 3;
float g_meleeHeadingSign = -1.0f;
float g_meleePitchSign = 1.0f;
float g_meleeBankSign = 1.0f;
float g_meleeLookDistance = 40.0f;
float g_meleeForwardOffset = 0.0f;
float g_meleeLeftOffset = 0.0f;
float g_meleeUpOffset = 0.0f;
float g_meleeLeftPerDeg = -0.015f;
float g_meleeUpPerDeg = 0.015f;
float g_meleeForwardPerDeg = 0.0f;
float g_meleeHeadingOffset = 0.0f;
float g_meleePitchOffset = 0.0f;
float g_meleeBankOffset = 0.0f;
int   g_meleePoseLog = 0;
float g_weaponOffsetLeftPerDeg = -0.015f;
float g_weaponOffsetUpPerDeg = 0.015f;
float g_weaponOffsetForward = 0.0f;
float g_weaponPitchCompHeadingScale = 1.0f;
float g_weaponPitchCompBankSign = -1.0f;
float g_weaponScreenMinCos = 0.25f;
bool  g_reticle = false;
int   g_reticleSizePx = 14;
int   g_reticleGapPx = 5;
int   g_reticleThicknessPx = 3;
int   g_reticleColorR = 0;
int   g_reticleColorG = 220;
int   g_reticleColorB = 95;
bool  g_reticleCenterDot = true;
int   g_reticleCenterSizePx = 4;
bool  g_hideOriginal = false;
int   g_hideOriginalSizePx = 36;
int   g_hideOriginalColorR = 0;
int   g_hideOriginalColorG = 0;
int   g_hideOriginalColorB = 0;
bool  g_nativeHudReticle = true;
bool  g_nativeHudHideOriginal = true;
float g_nativeHudReticleOffsetX = 0.0f;
float g_nativeHudReticleOffsetY = 0.0f;
int   g_nativeCrosshairRectProbe = 1;
int   g_nativeCrosshairRectProbeIntervalMs = 1000;
bool  g_selection = false;
bool  g_selectionLog = false;
bool  g_selectionSemantic = true;
bool  g_selectionSemanticLog = false;
bool  g_selectionDebugMarker = true;
bool  g_selectionDebugMarkerLog = false;
int   g_selectionDebugMarkerStyle = 2; // 1=legacy debug glyphs, 2=stock BRACK0-3 corner bitmaps
int   g_selectionDebugMarkerHalfW = 48;
int   g_selectionDebugMarkerHalfH = 32;
bool  g_nativeCursor = false;
bool  g_nativeCursorLog = false;
bool  g_nativeBracketProbe = false;
bool  g_nativeBracketProbeHook = false;
int   g_nativeBracketProbeIntervalMs = 250;
float g_selectionSemanticReach = 8.0f;
float g_selectionSemanticRadius = 1.8f;
int   g_selectionSemanticMode = 2; // 1=world ray cylinder, 2=screen-projected object position
float g_selectionScreenRadiusPx = 64.0f;
float g_selectionScreenProbeMarginPx = 96.0f;
int   g_selectionScreenUseReticleBias = 1;
int   g_selectionScreenRequireRendered = 0;
int   g_selectionSemanticIntervalMs = 80;
int   g_selectionSemanticPublishIntervalMs = 160;
int   g_selectionSemanticMaxObj = 10000;
int   g_selectionSemanticLogTop = 5;
int   g_selectionSemanticRequire = 1;
int   g_selectionSemanticMaxAgeMs = 350;
bool  g_requireSquirrelBridge = true;
bool  g_blockWithoutBridge = true;
int   g_squirrelAliveMaxAgeMs = 750;
bool  g_configHookEnabled = true;
int   g_allowCheatTuning = 0;
bool  g_selectionFlipX = false;
bool  g_selectionFlipY = false;
bool  g_selectionSwapXY = false;
float g_selectionScaleX = 1.0f;
float g_selectionScaleY = 1.0f;
float g_selectionOffsetX = 0.0f;
float g_selectionOffsetY = 0.0f;
bool  g_log = false;

std::atomic<bool> g_overlayReady{false};
std::atomic<bool> g_overlayActive{false};
std::atomic<int> g_overlayCursorX{960};
std::atomic<int> g_overlayCursorY{540};
std::atomic<int> g_overlayScreenW{1920};
std::atomic<int> g_overlayScreenH{1080};
std::atomic<bool> g_overlayDrawReticle{false};
std::atomic<int> g_overlaySizePx{14};
std::atomic<int> g_overlayGapPx{5};
std::atomic<int> g_overlayThicknessPx{3};
std::atomic<int> g_overlayColorR{0};
std::atomic<int> g_overlayColorG{220};
std::atomic<int> g_overlayColorB{95};
std::atomic<bool> g_overlayCenterDot{true};
std::atomic<int> g_overlayCenterSizePx{4};
std::atomic<bool> g_overlayHideOriginal{false};
std::atomic<int> g_overlayHideSizePx{36};
std::atomic<int> g_overlayHideColorR{0};
std::atomic<int> g_overlayHideColorG{0};
std::atomic<int> g_overlayHideColorB{0};
std::atomic<DWORD> g_processId{0};
HWND g_overlayHwnd = nullptr;
HWND g_gameHwnd = nullptr;
HANDLE g_overlayThread = nullptr;

char g_iniPath[MAX_PATH] = {0};
char g_logPath[MAX_PATH] = {0};

void DeriveGameDirPaths() {
    wchar_t exe[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    // strip filename
    for (int i = (int)wcslen(exe) - 1; i >= 0; --i) {
        if (exe[i] == L'\\' || exe[i] == L'/') { exe[i + 1] = 0; break; }
    }
    char dir[MAX_PATH] = {0};
    WideCharToMultiByte(CP_ACP, 0, exe, -1, dir, MAX_PATH, nullptr, nullptr);
    _snprintf_s(g_iniPath, sizeof(g_iniPath), _TRUNCATE, "%sflataim.ini", dir);
    _snprintf_s(g_logPath, sizeof(g_logPath), _TRUNCATE, "%sflataim.log", dir);
}

void LogLine(const char* fmt, ...) {
    if (!g_log && fmt[0] != '!') return; // lines starting with '!' always log (init/errors)
    FILE* f = nullptr;
    if (fopen_s(&f, g_logPath, "a") != 0 || !f) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt[0] == '!' ? fmt + 1 : fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

float IniF(const char* key, float def) {
    char buf[64] = {0};
    GetPrivateProfileStringA("flataim", key, "", buf, sizeof(buf), g_iniPath);
    if (buf[0] == 0) return def;
    return (float)atof(buf);
}
int IniI(const char* key, int def) { return GetPrivateProfileIntA("flataim", key, def, g_iniPath); }

// Strip an inline comment (';' or '#' at start or after whitespace) and any
// surrounding whitespace, in place. GetPrivateProfileString does NOT remove
// trailing "; comment" text, so without this the press-type strings come back
// as e.g. "hold     ; toggle or hold" and exact-match parsing silently fails.
void TrimIniValueInPlace(char* s) {
    if (!s) return;
    for (char* p = s; *p; ++p) {
        if ((*p == ';' || *p == '#') && (p == s || p[-1] == ' ' || p[-1] == '\t')) { *p = 0; break; }
    }
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == ' ' || s[n-1] == '\t' || s[n-1] == '\r' || s[n-1] == '\n')) s[--n] = 0;
    char* p = s;
    while (*p == ' ' || *p == '\t') ++p;
    if (p != s) memmove(s, p, strlen(p) + 1);
}

void IniS(const char* key, const char* def, char* out, size_t outSize) {
    if (!out || outSize == 0) return;
    GetPrivateProfileStringA("flataim", key, def ? def : "", out, static_cast<DWORD>(outSize), g_iniPath);
    TrimIniValueInPlace(out);
}

bool TryReadGameClientSize(float& w, float& h);

int ParseFreelookPressType(const char* text, int fallback) {
    if (!text || text[0] == 0) return fallback;
    if (_stricmp(text, "hold") == 0 || _stricmp(text, "press_hold") == 0) return kFreelookPressHold;
    if (_stricmp(text, "toggle") == 0) return kFreelookPressToggle;
    return fallback;
}

int ParseEdgePanPressType(const char* text, int fallback) {
    if (!text || text[0] == 0) return fallback;
    if (_stricmp(text, "always") == 0 || _stricmp(text, "on") == 0 || _stricmp(text, "enabled") == 0) return kEdgePanPressAlways;
    if (_stricmp(text, "off") == 0 || _stricmp(text, "disabled") == 0) return kEdgePanPressOff;
    if (_stricmp(text, "toggle") == 0) return kEdgePanPressToggle;
    if (_stricmp(text, "hold") == 0 || _stricmp(text, "hold_lock") == 0 || _stricmp(text, "lock_hold") == 0) return kEdgePanPressHoldLock;
    return fallback;
}

const char* FreelookPressTypeName(int mode) {
    return mode == kFreelookPressHold ? "hold" : "toggle";
}

const char* EdgePanPressTypeName(int mode) {
    switch (mode) {
    case kEdgePanPressAlways: return "always";
    case kEdgePanPressOff: return "off";
    case kEdgePanPressToggle: return "toggle";
    case kEdgePanPressHoldLock: return "hold_lock";
    default: return "unknown";
    }
}

void ApplyDisplaySize(float w, float h, bool preserveCursor) {
    const float oldW = std::max(1.0f, g_screenW);
    const float oldH = std::max(1.0f, g_screenH);
    const float newW = std::max(320.0f, std::min(w, 16384.0f));
    const float newH = std::max(200.0f, std::min(h, 16384.0f));
    if (preserveCursor && g_cxInit && (fabsf(newW - oldW) > 0.5f || fabsf(newH - oldH) > 0.5f)) {
        const float rawU = (oldW > 1.0f) ? (g_cx / (oldW - 1.0f)) : 0.5f;
        const float rawV = (oldH > 1.0f) ? (g_cy / (oldH - 1.0f)) : 0.5f;
        const float u = std::max(0.0f, std::min(rawU, 1.0f));
        const float v = std::max(0.0f, std::min(rawV, 1.0f));
        g_cx = u * (newW - 1.0f);
        g_cy = v * (newH - 1.0f);
    }
    g_screenW = newW;
    g_screenH = newH;
    g_overlayScreenW.store(std::max(1, static_cast<int>(g_screenW)), std::memory_order_relaxed);
    g_overlayScreenH.store(std::max(1, static_cast<int>(g_screenH)), std::memory_order_relaxed);
}

void RefreshDisplayFromSquirrelCanvas(bool preserveCursor) {
    if (!g_autoDisplay) return;
    const int canvasW = g_squirrelCanvasW.load(std::memory_order_acquire);
    const int canvasH = g_squirrelCanvasH.load(std::memory_order_acquire);
    if (canvasW >= 320 && canvasH >= 200) {
        ApplyDisplaySize(static_cast<float>(canvasW), static_cast<float>(canvasH), preserveCursor);
    }
}

void ResolveDisplayConfig(float manualW, float manualH) {
    float resolvedW = 1920.0f;
    float resolvedH = 1080.0f;
    if (std::isfinite(manualW) && std::isfinite(manualH) && manualW >= 320.0f && manualH >= 200.0f) {
        resolvedW = manualW;
        resolvedH = manualH;
    } else if (g_autoDisplay) {
        const int canvasW = g_squirrelCanvasW.load(std::memory_order_acquire);
        const int canvasH = g_squirrelCanvasH.load(std::memory_order_acquire);
        if (canvasW >= 320 && canvasH >= 200) {
            resolvedW = static_cast<float>(canvasW);
            resolvedH = static_cast<float>(canvasH);
        } else {
            float clientW = 0.0f;
            float clientH = 0.0f;
            if (TryReadGameClientSize(clientW, clientH)) {
                resolvedW = clientW;
                resolvedH = clientH;
            }
        }
    }
    ApplyDisplaySize(resolvedW, resolvedH, false);
}

void LoadIni() {
    g_toggleVk = IniI("toggle_vk", g_toggleVk);
    char pressBuf[64] = {0};
    IniS("freelook_press_type", "toggle", pressBuf, sizeof(pressBuf));
    g_freelookPressType = ParseFreelookPressType(pressBuf, g_freelookPressType);
    g_autoDisplay = IniI("auto_display", g_autoDisplay) ? 1 : 0;
    const float iniFov = IniF("fov_deg", 0.0f);
    g_fovDeg = iniFov > 1.0f ? iniFov : 74.0f;
    const float iniScreenW = IniF("screen_w", 0.0f);
    const float iniScreenH = IniF("screen_h", 0.0f);
    ResolveDisplayConfig(iniScreenW, iniScreenH);
    g_sensX = IniF("sens_x", g_sensX);
    g_sensY = IniF("sens_y", g_sensY);
    g_yawSign = IniF("yaw_sign", g_yawSign);
    g_pitchSign = IniF("pitch_sign", g_pitchSign);
    g_worldYawSign = IniF("world_yaw_sign", g_worldYawSign);
    g_worldPitchSign = IniF("world_pitch_sign", g_worldPitchSign);
    g_worldYawOffsetDeg = IniF("world_yaw_offset_deg", g_worldYawOffsetDeg);
    g_worldPitchOffsetDeg = IniF("world_pitch_offset_deg", g_worldPitchOffsetDeg);
    g_edgePanEnabled = IniI("edge_pan_enabled", g_edgePanEnabled);
    g_edgePanVk = IniI("edge_pan_vk", g_edgePanVk);
    IniS("edge_pan_press_type", "always", pressBuf, sizeof(pressBuf));
    g_edgePanPressType = ParseEdgePanPressType(pressBuf, g_edgePanPressType);
    g_edgePanMarginX = IniF("edge_pan_margin_x", g_edgePanMarginX);
    g_edgePanMarginY = IniF("edge_pan_margin_y", g_edgePanMarginY);
    g_edgePanMaxYawAccum = IniF("edge_pan_max_yaw_accum", g_edgePanMaxYawAccum);
    g_edgePanMaxPitchAccum = IniF("edge_pan_max_pitch_accum", g_edgePanMaxPitchAccum);
    g_edgePanCurve = IniF("edge_pan_curve", g_edgePanCurve);
    g_edgePanYawSign = IniF("edge_pan_yaw_sign", g_edgePanYawSign);
    g_edgePanPitchSign = IniF("edge_pan_pitch_sign", g_edgePanPitchSign);
    g_edgePanLog = IniI("edge_pan_log", g_edgePanLog);
    g_allowCheatTuning = IniI("allow_cheat_tuning", 0) ? 1 : 0;
    if (!g_allowCheatTuning) {
        g_weaponProxyScale = 1.0f;
        g_selectionSemanticReach = 8.0f;
        g_selectionSemanticRadius = 1.8f;
        g_selectionScreenRadiusPx = 64.0f;
    }
    g_projectileMode = IniI("projectile_mode", g_projectileMode);
    g_projectileNativeSkipCreate = IniI("projectile_native_skip_create", g_projectileNativeSkipCreate);
    g_projViewFrame = IniI("proj_viewframe", g_projViewFrame);
    g_projSkipFacing = IniI("proj_skip_facing", g_projSkipFacing);
    g_projSkipVel = IniI("proj_skip_vel", g_projSkipVel);
    g_projFacingMode = IniI("proj_facing_mode", g_projFacingMode);
    g_aimVelocityMode = IniI("aim_velocity_mode", g_aimVelocityMode);
    g_aimLog = IniI("aim_log", g_aimLog);
    g_projectileHeadingSign = IniF("projectile_heading_sign", g_projectileHeadingSign);
    g_projectilePitchSign = IniF("projectile_pitch_sign", g_projectilePitchSign);
    g_projectileHeadingOffsetDeg = IniF("projectile_heading_offset_deg", g_projectileHeadingOffsetDeg);
    g_projectilePitchOffsetDeg = IniF("projectile_pitch_offset_deg", g_projectilePitchOffsetDeg);
    g_weaponHeadingSign = IniF("weapon_heading_sign", g_weaponHeadingSign);
    g_weaponPitchSign = IniF("weapon_pitch_sign", g_weaponPitchSign);
    g_weaponBankDeg = IniF("weapon_bank_deg", g_weaponBankDeg);
    g_weaponLockHeading = IniI("weapon_lock_heading", g_weaponLockHeading);
    g_weaponLockPitch = IniI("weapon_lock_pitch", g_weaponLockPitch);
    g_weaponLockBank = IniI("weapon_lock_bank", g_weaponLockBank);
    g_weaponFollowMode = IniI("weapon_follow_mode", g_weaponFollowMode);
    g_weaponScreenAxisVariant = IniI("weapon_screen_axis_variant", g_weaponScreenAxisVariant);
    g_weaponProxyHideNative = IniI("weapon_proxy_hide_native", g_weaponProxyHideNative);
    g_weaponProxyFacingMode = IniI("weapon_proxy_facing_mode", g_weaponProxyFacingMode);
    if (g_allowCheatTuning) g_weaponProxyScale = IniF("weapon_proxy_scale", g_weaponProxyScale);
    g_weaponProxyNativeHideScale = IniF("weapon_proxy_native_hide_scale", g_weaponProxyNativeHideScale);
    g_weaponProxyForward = IniF("weapon_proxy_forward", g_weaponProxyForward);
    g_weaponProxyLeft = IniF("weapon_proxy_left", g_weaponProxyLeft);
    g_weaponProxyUp = IniF("weapon_proxy_up", g_weaponProxyUp);
    g_weaponProxyHeadingOffset = IniF("weapon_proxy_heading_offset_deg", g_weaponProxyHeadingOffset);
    g_weaponProxyPitchOffset = IniF("weapon_proxy_pitch_offset_deg", g_weaponProxyPitchOffset);
    g_weaponProxyBankOffset = IniF("weapon_proxy_bank_offset_deg", g_weaponProxyBankOffset);
    g_weaponProxyLookDistance = IniF("weapon_proxy_look_distance", g_weaponProxyLookDistance);
    g_weaponProxyRollSign = IniF("weapon_proxy_roll_sign", g_weaponProxyRollSign);
    g_weaponProxyFlipX = IniI("weapon_proxy_flip_x", g_weaponProxyFlipX);
    g_weaponProxyAxisLog = IniI("weapon_proxy_axis_log", g_weaponProxyAxisLog);
    g_weaponProxyAxisDraw = IniI("weapon_proxy_axis_draw", g_weaponProxyAxisDraw);
    g_weaponProxyAxisLen = IniF("weapon_proxy_axis_len", g_weaponProxyAxisLen);
    g_weaponEffectFollow = IniI("weapon_effect_follow", g_weaponEffectFollow);
    g_weaponEffectRecreate = IniI("weapon_effect_recreate", g_weaponEffectRecreate);
    g_weaponEffectLog = IniI("weapon_effect_log", g_weaponEffectLog);
    g_weaponProxyPivotEnable = IniI("weapon_proxy_pivot_enable", g_weaponProxyPivotEnable);
    g_weaponViewRotate = IniI("weapon_view_rotate", g_weaponViewRotate);
    g_weaponProxyPivotAllWeapons = IniI("weapon_proxy_pivot_all_weapons", g_weaponProxyPivotAllWeapons);
    g_weaponProxyPivotLongForward = IniF("weapon_proxy_pivot_long_forward", g_weaponProxyPivotLongForward);
    g_weaponProxyPivotLongLeft = IniF("weapon_proxy_pivot_long_left", g_weaponProxyPivotLongLeft);
    g_weaponProxyPivotLongUp = IniF("weapon_proxy_pivot_long_up", g_weaponProxyPivotLongUp);
    g_meleeEnable = IniI("melee_enable", g_meleeEnable);
    g_meleeOrientationMode = IniI("melee_orientation_mode", g_meleeOrientationMode);
    g_meleeHeadingSign = IniF("melee_heading_sign", g_meleeHeadingSign);
    g_meleePitchSign = IniF("melee_pitch_sign", g_meleePitchSign);
    g_meleeBankSign = IniF("melee_bank_sign", g_meleeBankSign);
    g_meleeLookDistance = IniF("melee_look_distance", g_meleeLookDistance);
    g_meleeForwardOffset = IniF("melee_forward_offset", g_meleeForwardOffset);
    g_meleeLeftOffset = IniF("melee_left_offset", g_meleeLeftOffset);
    g_meleeUpOffset = IniF("melee_up_offset", g_meleeUpOffset);
    g_meleeLeftPerDeg = IniF("melee_left_per_deg", g_meleeLeftPerDeg);
    g_meleeUpPerDeg = IniF("melee_up_per_deg", g_meleeUpPerDeg);
    g_meleeForwardPerDeg = IniF("melee_forward_per_deg", g_meleeForwardPerDeg);
    g_meleeHeadingOffset = IniF("melee_heading_offset", g_meleeHeadingOffset);
    g_meleePitchOffset = IniF("melee_pitch_offset", g_meleePitchOffset);
    g_meleeBankOffset = IniF("melee_bank_offset", g_meleeBankOffset);
    g_meleePoseLog = IniI("melee_pose_log", g_meleePoseLog);
    g_weaponOffsetLeftPerDeg = IniF("weapon_offset_left_per_deg", g_weaponOffsetLeftPerDeg);
    g_weaponOffsetUpPerDeg = IniF("weapon_offset_up_per_deg", g_weaponOffsetUpPerDeg);
    g_weaponOffsetForward = IniF("weapon_offset_forward", g_weaponOffsetForward);
    g_weaponPitchCompHeadingScale = IniF("weapon_pitch_comp_heading_scale", g_weaponPitchCompHeadingScale);
    g_weaponPitchCompBankSign = IniF("weapon_pitch_comp_bank_sign", g_weaponPitchCompBankSign);
    g_weaponScreenMinCos = IniF("weapon_screen_min_cos", g_weaponScreenMinCos);
    g_reticle = IniI("reticle", g_reticle ? 1 : 0) != 0;
    g_reticleSizePx = IniI("reticle_size_px", g_reticleSizePx);
    g_reticleGapPx = IniI("reticle_gap_px", g_reticleGapPx);
    g_reticleThicknessPx = IniI("reticle_thickness_px", g_reticleThicknessPx);
    g_reticleColorR = IniI("reticle_color_r", g_reticleColorR);
    g_reticleColorG = IniI("reticle_color_g", g_reticleColorG);
    g_reticleColorB = IniI("reticle_color_b", g_reticleColorB);
    g_reticleCenterDot = IniI("reticle_center_dot", g_reticleCenterDot ? 1 : 0) != 0;
    g_reticleCenterSizePx = IniI("reticle_center_size_px", g_reticleCenterSizePx);
    g_hideOriginal = IniI("hide_original", g_hideOriginal ? 1 : 0) != 0;
    g_hideOriginalSizePx = IniI("hide_original_size_px", g_hideOriginalSizePx);
    g_hideOriginalColorR = IniI("hide_original_color_r", g_hideOriginalColorR);
    g_hideOriginalColorG = IniI("hide_original_color_g", g_hideOriginalColorG);
    g_hideOriginalColorB = IniI("hide_original_color_b", g_hideOriginalColorB);
    g_nativeHudReticle = IniI("native_hud_reticle", g_nativeHudReticle ? 1 : 0) != 0;
    g_nativeHudHideOriginal = IniI("native_hud_hide_original", g_nativeHudHideOriginal ? 1 : 0) != 0;
    g_nativeHudReticleOffsetX = IniF("native_hud_reticle_offset_x", g_nativeHudReticleOffsetX);
    g_nativeHudReticleOffsetY = IniF("native_hud_reticle_offset_y", g_nativeHudReticleOffsetY);
    g_nativeCrosshairRectProbe = IniI("native_crosshair_rect_probe", g_nativeCrosshairRectProbe) ? 1 : 0;
    g_nativeCrosshairRectProbeIntervalMs = IniI("native_crosshair_rect_probe_interval_ms", g_nativeCrosshairRectProbeIntervalMs);
    g_selection = IniI("selection", g_selection ? 1 : 0) != 0;
    g_selectionLog = IniI("selection_log", g_selectionLog ? 1 : 0) != 0;
    g_selectionSemantic = IniI("selection_semantic", g_selectionSemantic ? 1 : 0) != 0;
    g_selectionSemanticLog = IniI("selection_semantic_log", g_selectionSemanticLog ? 1 : 0) != 0;
    g_selectionDebugMarker = IniI("selection_debug_marker", g_selectionDebugMarker ? 1 : 0) != 0;
    g_selectionDebugMarkerLog = IniI("selection_debug_marker_log", g_selectionDebugMarkerLog ? 1 : 0) != 0;
    g_selectionDebugMarkerStyle = IniI("selection_debug_marker_style", g_selectionDebugMarkerStyle);
    g_selectionDebugMarkerHalfW = IniI("selection_debug_marker_half_w_px", g_selectionDebugMarkerHalfW);
    g_selectionDebugMarkerHalfH = IniI("selection_debug_marker_half_h_px", g_selectionDebugMarkerHalfH);
    g_nativeCursor = IniI("native_cursor", g_nativeCursor ? 1 : 0) != 0;
    g_nativeCursorLog = IniI("native_cursor_log", g_nativeCursorLog ? 1 : 0) != 0;
    g_nativeBracketProbe = IniI("native_bracket_probe", g_nativeBracketProbe ? 1 : 0) != 0;
    g_nativeBracketProbeHook = IniI("native_bracket_probe_hook", g_nativeBracketProbeHook ? 1 : 0) != 0;
    g_nativeBracketProbeIntervalMs = IniI("native_bracket_probe_interval_ms", g_nativeBracketProbeIntervalMs);
    if (g_allowCheatTuning) g_selectionSemanticReach = IniF("selection_semantic_reach", g_selectionSemanticReach);
    if (g_allowCheatTuning) g_selectionSemanticRadius = IniF("selection_semantic_radius", g_selectionSemanticRadius);
    g_selectionSemanticMode = IniI("selection_semantic_mode", g_selectionSemanticMode);
    if (g_allowCheatTuning) g_selectionScreenRadiusPx = IniF("selection_screen_radius_px", g_selectionScreenRadiusPx);
    g_selectionScreenProbeMarginPx = IniF("selection_screen_probe_margin_px", g_selectionScreenProbeMarginPx);
    g_selectionScreenUseReticleBias = IniI("selection_screen_use_reticle_bias", g_selectionScreenUseReticleBias);
    g_selectionScreenRequireRendered = IniI("selection_screen_require_rendered", g_selectionScreenRequireRendered);
    g_selectionSemanticIntervalMs = IniI("selection_semantic_interval_ms", g_selectionSemanticIntervalMs);
    g_selectionSemanticPublishIntervalMs = IniI("selection_semantic_publish_interval_ms", g_selectionSemanticPublishIntervalMs);
    g_selectionSemanticMaxObj = IniI("selection_semantic_max_obj", g_selectionSemanticMaxObj);
    g_selectionSemanticLogTop = IniI("selection_semantic_log_top", g_selectionSemanticLogTop);
    g_selectionSemanticRequire = IniI("selection_semantic_require", g_selectionSemanticRequire);
    g_selectionSemanticMaxAgeMs = IniI("selection_semantic_max_age_ms", g_selectionSemanticMaxAgeMs);
    g_requireSquirrelBridge = IniI("require_squirrel_bridge", g_requireSquirrelBridge ? 1 : 0) != 0;
    g_blockWithoutBridge = IniI("block_without_bridge", g_blockWithoutBridge ? 1 : 0) != 0;
    g_squirrelAliveMaxAgeMs = IniI("squirrel_alive_max_age_ms", g_squirrelAliveMaxAgeMs);
    g_configHookEnabled = IniI("config_hook", 1) != 0;
    g_selectionFlipX = IniI("selection_flip_x", g_selectionFlipX ? 1 : 0) != 0;
    g_selectionFlipY = IniI("selection_flip_y", g_selectionFlipY ? 1 : 0) != 0;
    g_selectionSwapXY = IniI("selection_swap_xy", g_selectionSwapXY ? 1 : 0) != 0;
    g_selectionScaleX = IniF("selection_scale_x", g_selectionScaleX);
    g_selectionScaleY = IniF("selection_scale_y", g_selectionScaleY);
    g_selectionOffsetX = IniF("selection_offset_x", g_selectionOffsetX);
    g_selectionOffsetY = IniF("selection_offset_y", g_selectionOffsetY);
    g_log = IniI("log", 0) != 0;

    g_toggleVk = std::max(1, std::min(g_toggleVk, 0xFE));
    g_freelookPressType = g_freelookPressType == kFreelookPressHold ? kFreelookPressHold : kFreelookPressToggle;
    g_autoDisplay = g_autoDisplay ? 1 : 0;
    if (!std::isfinite(g_fovDeg)) g_fovDeg = 74.0f;
    g_fovDeg = std::max(30.0f, std::min(g_fovDeg, 140.0f));
    g_edgePanVk = std::max(1, std::min(g_edgePanVk, 0xFE));
    if (g_edgePanPressType < kEdgePanPressAlways || g_edgePanPressType > kEdgePanPressHoldLock) {
        g_edgePanPressType = kEdgePanPressAlways;
    }
    if (!g_edgePanEnabled) {
        g_edgePanPressType = kEdgePanPressOff;
    }
    if (g_edgePanPressType == kEdgePanPressAlways) {
        g_edgePanToggleActive = true;
    } else if (g_edgePanPressType == kEdgePanPressOff) {
        g_edgePanToggleActive = false;
    }
    g_allowCheatTuning = g_allowCheatTuning ? 1 : 0;
    g_reticleSizePx = std::max(4, std::min(g_reticleSizePx, 96));
    g_reticleGapPx = std::max(0, std::min(g_reticleGapPx, 48));
    g_reticleThicknessPx = std::max(1, std::min(g_reticleThicknessPx, 12));
    g_reticleColorR = std::max(0, std::min(g_reticleColorR, 255));
    g_reticleColorG = std::max(0, std::min(g_reticleColorG, 255));
    g_reticleColorB = std::max(0, std::min(g_reticleColorB, 255));
    g_reticleCenterSizePx = std::max(0, std::min(g_reticleCenterSizePx, 24));
    g_hideOriginalSizePx = std::max(0, std::min(g_hideOriginalSizePx, 128));
    g_hideOriginalColorR = std::max(0, std::min(g_hideOriginalColorR, 255));
    g_hideOriginalColorG = std::max(0, std::min(g_hideOriginalColorG, 255));
    g_hideOriginalColorB = std::max(0, std::min(g_hideOriginalColorB, 255));
    if (!std::isfinite(g_nativeHudReticleOffsetX)) g_nativeHudReticleOffsetX = 0.0f;
    if (!std::isfinite(g_nativeHudReticleOffsetY)) g_nativeHudReticleOffsetY = 0.0f;
    g_nativeHudReticleOffsetX = std::max(-256.0f, std::min(g_nativeHudReticleOffsetX, 256.0f));
    g_nativeHudReticleOffsetY = std::max(-256.0f, std::min(g_nativeHudReticleOffsetY, 256.0f));
    g_nativeCrosshairRectProbe = g_nativeCrosshairRectProbe ? 1 : 0;
    g_nativeCrosshairRectProbeIntervalMs = std::max(100, std::min(g_nativeCrosshairRectProbeIntervalMs, 5000));
    if (!std::isfinite(g_selectionScaleX)) g_selectionScaleX = 1.0f;
    if (!std::isfinite(g_selectionScaleY)) g_selectionScaleY = 1.0f;
    if (!std::isfinite(g_selectionOffsetX)) g_selectionOffsetX = 0.0f;
    if (!std::isfinite(g_selectionOffsetY)) g_selectionOffsetY = 0.0f;
    if (!std::isfinite(g_edgePanMarginX)) g_edgePanMarginX = 0.12f;
    if (!std::isfinite(g_edgePanMarginY)) g_edgePanMarginY = 0.12f;
    if (!std::isfinite(g_edgePanMaxYawAccum)) g_edgePanMaxYawAccum = 0.75f;
    if (!std::isfinite(g_edgePanMaxPitchAccum)) g_edgePanMaxPitchAccum = 0.55f;
    if (!std::isfinite(g_edgePanCurve)) g_edgePanCurve = 2.0f;
    if (!std::isfinite(g_edgePanYawSign)) g_edgePanYawSign = 1.0f;
    if (!std::isfinite(g_edgePanPitchSign)) g_edgePanPitchSign = 1.0f;
    if (!std::isfinite(g_weaponBankDeg)) g_weaponBankDeg = 0.0f;
    if (!std::isfinite(g_weaponProxyScale)) g_weaponProxyScale = 1.0f;
    if (!std::isfinite(g_weaponProxyNativeHideScale)) g_weaponProxyNativeHideScale = 0.001f;
    if (!std::isfinite(g_weaponProxyForward)) g_weaponProxyForward = 0.0f;
    if (!std::isfinite(g_weaponProxyLeft)) g_weaponProxyLeft = 0.0f;
    if (!std::isfinite(g_weaponProxyUp)) g_weaponProxyUp = 0.0f;
    if (!std::isfinite(g_weaponProxyHeadingOffset)) g_weaponProxyHeadingOffset = 0.0f;
    if (!std::isfinite(g_weaponProxyPitchOffset)) g_weaponProxyPitchOffset = 0.0f;
    if (!std::isfinite(g_weaponProxyBankOffset)) g_weaponProxyBankOffset = 0.0f;
    if (!std::isfinite(g_weaponProxyLookDistance)) g_weaponProxyLookDistance = 40.0f;
    if (!std::isfinite(g_weaponProxyRollSign)) g_weaponProxyRollSign = -1.0f;
    if (!std::isfinite(g_weaponProxyAxisLen)) g_weaponProxyAxisLen = 1.25f;
    if (!std::isfinite(g_weaponProxyPivotLongForward)) g_weaponProxyPivotLongForward = -1.25f;
    if (!std::isfinite(g_weaponProxyPivotLongLeft)) g_weaponProxyPivotLongLeft = 0.0f;
    if (!std::isfinite(g_weaponProxyPivotLongUp)) g_weaponProxyPivotLongUp = 0.0f;
    if (!std::isfinite(g_meleeHeadingSign)) g_meleeHeadingSign = -1.0f;
    if (!std::isfinite(g_meleePitchSign)) g_meleePitchSign = 1.0f;
    if (!std::isfinite(g_meleeBankSign)) g_meleeBankSign = 1.0f;
    if (!std::isfinite(g_meleeLookDistance)) g_meleeLookDistance = 40.0f;
    if (!std::isfinite(g_meleeForwardOffset)) g_meleeForwardOffset = 0.0f;
    if (!std::isfinite(g_meleeLeftOffset)) g_meleeLeftOffset = 0.0f;
    if (!std::isfinite(g_meleeUpOffset)) g_meleeUpOffset = 0.0f;
    if (!std::isfinite(g_meleeLeftPerDeg)) g_meleeLeftPerDeg = -0.015f;
    if (!std::isfinite(g_meleeUpPerDeg)) g_meleeUpPerDeg = 0.015f;
    if (!std::isfinite(g_meleeForwardPerDeg)) g_meleeForwardPerDeg = 0.0f;
    if (!std::isfinite(g_meleeHeadingOffset)) g_meleeHeadingOffset = 0.0f;
    if (!std::isfinite(g_meleePitchOffset)) g_meleePitchOffset = 0.0f;
    if (!std::isfinite(g_meleeBankOffset)) g_meleeBankOffset = 0.0f;
    if (!std::isfinite(g_weaponOffsetLeftPerDeg)) g_weaponOffsetLeftPerDeg = -0.015f;
    if (!std::isfinite(g_weaponOffsetUpPerDeg)) g_weaponOffsetUpPerDeg = 0.015f;
    if (!std::isfinite(g_weaponOffsetForward)) g_weaponOffsetForward = 0.0f;
    if (!std::isfinite(g_weaponPitchCompHeadingScale)) g_weaponPitchCompHeadingScale = 1.0f;
    if (!std::isfinite(g_weaponPitchCompBankSign)) g_weaponPitchCompBankSign = -1.0f;
    if (!std::isfinite(g_weaponScreenMinCos)) g_weaponScreenMinCos = 0.25f;
    if (!std::isfinite(g_selectionSemanticReach)) g_selectionSemanticReach = 8.0f;
    if (!std::isfinite(g_selectionSemanticRadius)) g_selectionSemanticRadius = 1.8f;
    if (!std::isfinite(g_selectionScreenRadiusPx)) g_selectionScreenRadiusPx = 64.0f;
    if (!std::isfinite(g_selectionScreenProbeMarginPx)) g_selectionScreenProbeMarginPx = 96.0f;
    g_selectionScaleX = std::max(-4.0f, std::min(g_selectionScaleX, 4.0f));
    g_selectionScaleY = std::max(-4.0f, std::min(g_selectionScaleY, 4.0f));
    g_selectionOffsetX = std::max(-4096.0f, std::min(g_selectionOffsetX, 4096.0f));
    g_selectionOffsetY = std::max(-4096.0f, std::min(g_selectionOffsetY, 4096.0f));
    g_edgePanEnabled = g_edgePanEnabled ? 1 : 0;
    g_edgePanMarginX = std::max(0.01f, std::min(g_edgePanMarginX, 0.49f));
    g_edgePanMarginY = std::max(0.01f, std::min(g_edgePanMarginY, 0.49f));
    g_edgePanMaxYawAccum = std::max(0.0f, std::min(g_edgePanMaxYawAccum, 10.0f));
    g_edgePanMaxPitchAccum = std::max(0.0f, std::min(g_edgePanMaxPitchAccum, 10.0f));
    g_edgePanCurve = std::max(0.25f, std::min(g_edgePanCurve, 6.0f));
    g_edgePanYawSign = std::max(-2.0f, std::min(g_edgePanYawSign, 2.0f));
    g_edgePanPitchSign = std::max(-2.0f, std::min(g_edgePanPitchSign, 2.0f));
    g_edgePanLog = g_edgePanLog ? 1 : 0;
    g_weaponBankDeg = std::max(-180.0f, std::min(g_weaponBankDeg, 180.0f));
    if (g_weaponFollowMode < 1 || g_weaponFollowMode > 7) g_weaponFollowMode = 1;
    if (g_weaponScreenAxisVariant < 0 || g_weaponScreenAxisVariant > 4) g_weaponScreenAxisVariant = 0;
    g_weaponProxyHideNative = g_weaponProxyHideNative ? 1 : 0;
    if (g_weaponProxyFacingMode < 0 || g_weaponProxyFacingMode > 8) g_weaponProxyFacingMode = 8;
    g_weaponProxyScale = std::max(0.05f, std::min(g_weaponProxyScale, 10.0f));
    g_weaponProxyNativeHideScale = std::max(0.0001f, std::min(g_weaponProxyNativeHideScale, 1.0f));
    g_weaponProxyForward = std::max(-10.0f, std::min(g_weaponProxyForward, 10.0f));
    g_weaponProxyLeft = std::max(-10.0f, std::min(g_weaponProxyLeft, 10.0f));
    g_weaponProxyUp = std::max(-10.0f, std::min(g_weaponProxyUp, 10.0f));
    g_weaponProxyHeadingOffset = std::max(-360.0f, std::min(g_weaponProxyHeadingOffset, 360.0f));
    g_weaponProxyPitchOffset = std::max(-360.0f, std::min(g_weaponProxyPitchOffset, 360.0f));
    g_weaponProxyBankOffset = std::max(-360.0f, std::min(g_weaponProxyBankOffset, 360.0f));
    g_weaponProxyLookDistance = std::max(1.0f, std::min(g_weaponProxyLookDistance, 200.0f));
    g_weaponProxyRollSign = std::max(-2.0f, std::min(g_weaponProxyRollSign, 2.0f));
    g_weaponProxyFlipX = g_weaponProxyFlipX ? 1 : 0;
    g_weaponProxyAxisLog = g_weaponProxyAxisLog ? 1 : 0;
    g_weaponProxyAxisDraw = g_weaponProxyAxisDraw ? 1 : 0;
    g_weaponProxyAxisLen = std::max(0.1f, std::min(g_weaponProxyAxisLen, 20.0f));
    g_weaponProxyPivotEnable = g_weaponProxyPivotEnable ? 1 : 0;
    g_weaponViewRotate = g_weaponViewRotate ? 1 : 0;
    g_weaponProxyPivotAllWeapons = g_weaponProxyPivotAllWeapons ? 1 : 0;
    g_weaponProxyPivotLongForward = std::max(-5.0f, std::min(g_weaponProxyPivotLongForward, 5.0f));
    g_weaponProxyPivotLongLeft = std::max(-5.0f, std::min(g_weaponProxyPivotLongLeft, 5.0f));
    g_weaponProxyPivotLongUp = std::max(-5.0f, std::min(g_weaponProxyPivotLongUp, 5.0f));
    g_projViewFrame = g_projViewFrame ? 1 : 0;
    g_projSkipFacing = g_projSkipFacing ? 1 : 0;
    g_projSkipVel = g_projSkipVel ? 1 : 0;
    g_projFacingMode = std::max(0, std::min(g_projFacingMode, 2));
    g_weaponEffectFollow = g_weaponEffectFollow ? 1 : 0;
    g_weaponEffectRecreate = g_weaponEffectRecreate ? 1 : 0;
    g_weaponEffectLog = g_weaponEffectLog ? 1 : 0;
    g_meleeEnable = g_meleeEnable ? 1 : 0;
    g_meleeOrientationMode = std::max(0, std::min(g_meleeOrientationMode, 3));
    g_meleeHeadingSign = std::max(-2.0f, std::min(g_meleeHeadingSign, 2.0f));
    g_meleePitchSign = std::max(-2.0f, std::min(g_meleePitchSign, 2.0f));
    g_meleeBankSign = std::max(-2.0f, std::min(g_meleeBankSign, 2.0f));
    g_meleeLookDistance = std::max(1.0f, std::min(g_meleeLookDistance, 200.0f));
    g_meleeForwardOffset = std::max(-10.0f, std::min(g_meleeForwardOffset, 10.0f));
    g_meleeLeftOffset = std::max(-10.0f, std::min(g_meleeLeftOffset, 10.0f));
    g_meleeUpOffset = std::max(-10.0f, std::min(g_meleeUpOffset, 10.0f));
    g_meleeLeftPerDeg = std::max(-1.0f, std::min(g_meleeLeftPerDeg, 1.0f));
    g_meleeUpPerDeg = std::max(-1.0f, std::min(g_meleeUpPerDeg, 1.0f));
    g_meleeForwardPerDeg = std::max(-1.0f, std::min(g_meleeForwardPerDeg, 1.0f));
    g_meleeHeadingOffset = std::max(-360.0f, std::min(g_meleeHeadingOffset, 360.0f));
    g_meleePitchOffset = std::max(-360.0f, std::min(g_meleePitchOffset, 360.0f));
    g_meleeBankOffset = std::max(-360.0f, std::min(g_meleeBankOffset, 360.0f));
    g_meleePoseLog = g_meleePoseLog ? 1 : 0;
    g_weaponOffsetLeftPerDeg = std::max(-0.25f, std::min(g_weaponOffsetLeftPerDeg, 0.25f));
    g_weaponOffsetUpPerDeg = std::max(-0.25f, std::min(g_weaponOffsetUpPerDeg, 0.25f));
    g_weaponOffsetForward = std::max(-5.0f, std::min(g_weaponOffsetForward, 5.0f));
    g_weaponPitchCompHeadingScale = std::max(0.0f, std::min(g_weaponPitchCompHeadingScale, 2.0f));
    g_weaponPitchCompBankSign = std::max(-2.0f, std::min(g_weaponPitchCompBankSign, 2.0f));
    g_weaponScreenMinCos = std::max(0.05f, std::min(g_weaponScreenMinCos, 1.0f));
    g_selectionSemanticReach = std::max(0.5f, std::min(g_selectionSemanticReach, 50.0f));
    g_selectionSemanticRadius = std::max(0.05f, std::min(g_selectionSemanticRadius, 10.0f));
    if (g_selectionSemanticMode < 1 || g_selectionSemanticMode > 2) g_selectionSemanticMode = 1;
    g_selectionScreenRadiusPx = std::max(4.0f, std::min(g_selectionScreenRadiusPx, 512.0f));
    g_selectionScreenProbeMarginPx = std::max(0.0f, std::min(g_selectionScreenProbeMarginPx, 512.0f));
    g_selectionScreenUseReticleBias = g_selectionScreenUseReticleBias ? 1 : 0;
    g_selectionScreenRequireRendered = g_selectionScreenRequireRendered ? 1 : 0;
    g_selectionSemanticIntervalMs = std::max(0, std::min(g_selectionSemanticIntervalMs, 2000));
    g_selectionSemanticPublishIntervalMs = std::max(0, std::min(g_selectionSemanticPublishIntervalMs, 2000));
    g_selectionSemanticMaxObj = std::max(1, std::min(g_selectionSemanticMaxObj, 50000));
    g_selectionSemanticLogTop = std::max(0, std::min(g_selectionSemanticLogTop, 20));
    g_selectionSemanticRequire = g_selectionSemanticRequire ? 1 : 0;
    g_selectionSemanticMaxAgeMs = std::max(1, std::min(g_selectionSemanticMaxAgeMs, 5000));
    if (g_selectionDebugMarkerStyle < 1 || g_selectionDebugMarkerStyle > 2) g_selectionDebugMarkerStyle = 2;
    g_selectionDebugMarkerHalfW = std::max(8, std::min(g_selectionDebugMarkerHalfW, 256));
    g_selectionDebugMarkerHalfH = std::max(8, std::min(g_selectionDebugMarkerHalfH, 256));
    g_nativeBracketProbeIntervalMs = std::max(40, std::min(g_nativeBracketProbeIntervalMs, 5000));
    g_weaponLockHeading = g_weaponLockHeading ? 1 : 0;
    g_weaponLockPitch = g_weaponLockPitch ? 1 : 0;
    g_weaponLockBank = g_weaponLockBank ? 1 : 0;
    g_squirrelAliveMaxAgeMs = std::max(100, std::min(g_squirrelAliveMaxAgeMs, 5000));

    g_overlayScreenW.store(std::max(1, static_cast<int>(g_screenW)), std::memory_order_relaxed);
    g_overlayScreenH.store(std::max(1, static_cast<int>(g_screenH)), std::memory_order_relaxed);
    g_overlayDrawReticle.store(g_reticle, std::memory_order_relaxed);
    g_overlaySizePx.store(g_reticleSizePx, std::memory_order_relaxed);
    g_overlayGapPx.store(g_reticleGapPx, std::memory_order_relaxed);
    g_overlayThicknessPx.store(g_reticleThicknessPx, std::memory_order_relaxed);
    g_overlayColorR.store(g_reticleColorR, std::memory_order_relaxed);
    g_overlayColorG.store(g_reticleColorG, std::memory_order_relaxed);
    g_overlayColorB.store(g_reticleColorB, std::memory_order_relaxed);
    g_overlayCenterDot.store(g_reticleCenterDot, std::memory_order_relaxed);
    g_overlayCenterSizePx.store(g_reticleCenterSizePx, std::memory_order_relaxed);
    g_overlayHideOriginal.store(g_hideOriginal, std::memory_order_relaxed);
    g_overlayHideSizePx.store(g_hideOriginalSizePx, std::memory_order_relaxed);
    g_overlayHideColorR.store(g_hideOriginalColorR, std::memory_order_relaxed);
    g_overlayHideColorG.store(g_hideOriginalColorG, std::memory_order_relaxed);
    g_overlayHideColorB.store(g_hideOriginalColorB, std::memory_order_relaxed);
}

float WrapDeg(float d) { while (d > 180.0f) d -= 360.0f; while (d < -180.0f) d += 360.0f; return d; }
float Clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

struct WindowSearch {
    HWND best = nullptr;
    LONG bestArea = 0;
};

BOOL CALLBACK EnumGameWindowsProc(HWND hwnd, LPARAM param) {
    if (!IsWindowVisible(hwnd) || hwnd == g_overlayHwnd) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != g_processId.load(std::memory_order_relaxed)) return TRUE;
    if ((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return TRUE;
    RECT rc {};
    if (!GetWindowRect(hwnd, &rc)) return TRUE;
    const LONG w = rc.right - rc.left;
    const LONG h = rc.bottom - rc.top;
    if (w < 320 || h < 200) return TRUE;
    auto* search = reinterpret_cast<WindowSearch*>(param);
    const LONG area = w * h;
    if (area > search->bestArea) {
        search->best = hwnd;
        search->bestArea = area;
    }
    return TRUE;
}

HWND FindGameWindow() {
    WindowSearch search;
    EnumWindows(EnumGameWindowsProc, reinterpret_cast<LPARAM>(&search));
    return search.best;
}

bool TryReadGameClientSize(float& w, float& h) {
    if (g_processId.load(std::memory_order_relaxed) == 0) {
        g_processId.store(GetCurrentProcessId(), std::memory_order_relaxed);
    }
    if (!g_gameHwnd || !IsWindow(g_gameHwnd) || IsIconic(g_gameHwnd)) {
        g_gameHwnd = FindGameWindow();
    }
    if (!g_gameHwnd || !IsWindow(g_gameHwnd) || IsIconic(g_gameHwnd)) {
        return false;
    }
    RECT client {};
    if (!GetClientRect(g_gameHwnd, &client)) return false;
    const LONG cw = client.right - client.left;
    const LONG ch = client.bottom - client.top;
    if (cw < 320 || ch < 200) return false;
    w = static_cast<float>(cw);
    h = static_cast<float>(ch);
    return true;
}

bool IsGameWindowForeground() {
    HWND fg = GetForegroundWindow();
    if (!fg) return false;
    if (!g_gameHwnd || !IsWindow(g_gameHwnd) || IsIconic(g_gameHwnd)) {
        g_gameHwnd = FindGameWindow();
    }
    if (!g_gameHwnd || !IsWindow(g_gameHwnd) || IsIconic(g_gameHwnd)) {
        DWORD pid = 0;
        GetWindowThreadProcessId(fg, &pid);
        return pid == g_processId.load(std::memory_order_relaxed);
    }
    HWND fgRoot = GetAncestor(fg, GA_ROOT);
    HWND gameRoot = GetAncestor(g_gameHwnd, GA_ROOT);
    return fg == g_gameHwnd || fgRoot == gameRoot;
}

bool UpdateOverlayBounds(HWND overlay) {
    if (!IsGameWindowForeground()) {
        return false;
    }
    if (!g_gameHwnd || !IsWindow(g_gameHwnd) || IsIconic(g_gameHwnd)) {
        g_gameHwnd = FindGameWindow();
    }
    if (!g_gameHwnd || !IsWindow(g_gameHwnd) || IsIconic(g_gameHwnd)) {
        return false;
    }
    RECT client {};
    if (!GetClientRect(g_gameHwnd, &client)) return false;
    POINT topLeft {0, 0};
    if (!ClientToScreen(g_gameHwnd, &topLeft)) return false;
    const int w = std::max(1L, client.right - client.left);
    const int h = std::max(1L, client.bottom - client.top);
    SetWindowPos(
        overlay,
        HWND_TOP,
        topLeft.x,
        topLeft.y,
        w,
        h,
        SWP_NOACTIVATE | SWP_SHOWWINDOW);
    return true;
}

LRESULT CALLBACK OverlayWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_ERASEBKGND:
        return 1;
    case WM_TIMER:
        if (g_overlayActive.load(std::memory_order_relaxed) && UpdateOverlayBounds(hwnd)) {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            InvalidateRect(hwnd, nullptr, FALSE);
        } else {
            ShowWindow(hwnd, SW_HIDE);
        }
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps {};
        HDC dc = BeginPaint(hwnd, &ps);
        RECT rc {};
        GetClientRect(hwnd, &rc);
        HBRUSH bg = CreateSolidBrush(kOverlayColorKey);
        FillRect(dc, &rc, bg);
        DeleteObject(bg);

        if (g_overlayActive.load(std::memory_order_relaxed)) {
            const int clientW = std::max(1L, rc.right - rc.left);
            const int clientH = std::max(1L, rc.bottom - rc.top);
            const int srcW = std::max(1, g_overlayScreenW.load(std::memory_order_relaxed));
            const int srcH = std::max(1, g_overlayScreenH.load(std::memory_order_relaxed));
            const int x = std::clamp(
                static_cast<int>((static_cast<int64_t>(g_overlayCursorX.load(std::memory_order_relaxed)) * clientW) / srcW),
                0,
                clientW - 1);
            const int y = std::clamp(
                static_cast<int>((static_cast<int64_t>(g_overlayCursorY.load(std::memory_order_relaxed)) * clientH) / srcH),
                0,
                clientH - 1);
            const int size = g_overlaySizePx.load(std::memory_order_relaxed);
            const int gap = g_overlayGapPx.load(std::memory_order_relaxed);
            const int thickness = g_overlayThicknessPx.load(std::memory_order_relaxed);
            const COLORREF color = RGB(
                g_overlayColorR.load(std::memory_order_relaxed),
                g_overlayColorG.load(std::memory_order_relaxed),
                g_overlayColorB.load(std::memory_order_relaxed));

            if (g_overlayHideOriginal.load(std::memory_order_relaxed)) {
                const int hideSize = g_overlayHideSizePx.load(std::memory_order_relaxed);
                if (hideSize > 0) {
                    const int centerX = clientW / 2;
                    const int centerY = clientH / 2;
                    const int half = hideSize / 2;
                    RECT cover { centerX - half, centerY - half, centerX - half + hideSize, centerY - half + hideSize };
                    HBRUSH coverBrush = CreateSolidBrush(RGB(
                        g_overlayHideColorR.load(std::memory_order_relaxed),
                        g_overlayHideColorG.load(std::memory_order_relaxed),
                        g_overlayHideColorB.load(std::memory_order_relaxed)));
                    FillRect(dc, &cover, coverBrush);
                    DeleteObject(coverBrush);
                }
            }

            if (g_overlayDrawReticle.load(std::memory_order_relaxed)) {
                HPEN pen = CreatePen(PS_SOLID, thickness, color);
                HGDIOBJ oldPen = SelectObject(dc, pen);
                MoveToEx(dc, x - gap - size, y, nullptr); LineTo(dc, x - gap, y);
                MoveToEx(dc, x + gap, y, nullptr); LineTo(dc, x + gap + size, y);
                MoveToEx(dc, x, y - gap - size, nullptr); LineTo(dc, x, y - gap);
                MoveToEx(dc, x, y + gap, nullptr); LineTo(dc, x, y + gap + size);
                SelectObject(dc, oldPen);
                DeleteObject(pen);

                if (g_overlayCenterDot.load(std::memory_order_relaxed)) {
                    const int dotSize = g_overlayCenterSizePx.load(std::memory_order_relaxed);
                    if (dotSize > 0) {
                        const int half = dotSize / 2;
                        RECT dot { x - half, y - half, x - half + dotSize, y - half + dotSize };
                        HBRUSH dotBrush = CreateSolidBrush(color);
                        FillRect(dc, &dot, dotBrush);
                        DeleteObject(dotBrush);
                    }
                }
            }
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

DWORD WINAPI OverlayThreadProc(LPVOID) {
    WNDCLASSW wc {};
    wc.lpfnWndProc = OverlayWndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"FreelookOverlayWindow";
    wc.hCursor = nullptr;
    RegisterClassW(&wc);

    HWND hwnd = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        wc.lpszClassName,
        L"Freelook Reticle",
        WS_POPUP,
        0,
        0,
        1,
        1,
        nullptr,
        nullptr,
        wc.hInstance,
        nullptr);
    if (!hwnd) return 0;
    g_overlayHwnd = hwnd;
    SetLayeredWindowAttributes(hwnd, kOverlayColorKey, 0, LWA_COLORKEY);
    SetTimer(hwnd, 1, 16, nullptr);
    g_overlayReady.store(true, std::memory_order_release);

    MSG msg {};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    g_overlayReady.store(false, std::memory_order_release);
    return 0;
}

bool ReadCodeBytesMatch(uint8_t* target, const uint8_t* bytes, size_t size) {
    __try { return std::memcmp(target, bytes, size) == 0; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool ReadInt32Raw(const int32_t* ptr, int32_t& out) {
    if (!ptr) return false;
    __try {
        out = *ptr;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadInt32ArrayRaw(const int32_t* ptr, int32_t* out, size_t count) {
    if (!ptr || !out) return false;
    __try {
        for (size_t i = 0; i < count; ++i) out[i] = ptr[i];
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadShockOverlayRectRaw(const ShockOverlayRectRaw* ptr, ShockOverlayRectRaw& out) {
    if (!ptr) return false;
    __try {
        out = *ptr;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ShockOverlayOrderSignatureMatches(const int32_t* order) {
    constexpr int32_t kExpected[kShockOverlayCount] = {
        22, 27, 28, 29, 30, 31, 17, 47, 41, 14,
        12, 9, 2, 16, 15, 1, 0, 32, 34, 49,
        3, 4, 5, 6, 7, 11, 18, 19, 20, 13,
        46, 35, 36, 37, 38, 8, 23, 24, 25, 21,
        33, 39, 40, 42, 43, 26, 45, 48, 10, 44,
    };
    if (!order) return false;
    for (size_t i = 0; i < kShockOverlayCount; ++i) {
        if (order[i] != kExpected[i]) return false;
    }
    return true;
}

bool IsUsableOverlayRect(const ShockOverlayRectRaw& rect) {
    return rect.right > rect.left && rect.bottom > rect.top &&
        rect.right > 0 && rect.bottom > 0 &&
        rect.left > -4096 && rect.top > -4096 &&
        rect.right < 8192 && rect.bottom < 8192;
}

void ProbeNativeCrosshairOverlay(const char* phase, bool force = false) {
    if (!g_nativeCrosshairRectProbe || !g_base) return;
    const ULONGLONG nowMs = GetTickCount64();
    if (!force && g_lastNativeCrosshairRectProbeLogMs != 0 &&
        nowMs - g_lastNativeCrosshairRectProbeLogMs < static_cast<ULONGLONG>(g_nativeCrosshairRectProbeIntervalMs)) {
        return;
    }
    g_lastNativeCrosshairRectProbeLogMs = nowMs;

    const auto* orderPtr = reinterpret_cast<const int32_t*>(g_base + kRvaShockOverlayOrder);
    const auto* rectPtr = reinterpret_cast<const ShockOverlayRectRaw*>(g_base + kRvaShockOverlayRects);
    const auto* onGhidraPtr = reinterpret_cast<const int32_t*>(g_base + kRvaShockOverlayOnGhidra);
    const auto* onMinus50Ptr = reinterpret_cast<const int32_t*>(g_base + kRvaShockOverlayOnMinus50);
    const auto* onMinus30Ptr = reinterpret_cast<const int32_t*>(g_base + kRvaShockOverlayOnMinus30);

    int32_t order[kShockOverlayCount] {};
    const bool orderRead = ReadInt32ArrayRaw(orderPtr, order, kShockOverlayCount);
    const bool orderOk = orderRead && ShockOverlayOrderSignatureMatches(order);

    ShockOverlayRectRaw rect {};
    const bool rectOk = ReadShockOverlayRectRaw(rectPtr + kShockOverlayCrosshair, rect);
    const bool rectUsable = rectOk && IsUsableOverlayRect(rect);
    const int rectW = static_cast<int>(rect.right) - static_cast<int>(rect.left);
    const int rectH = static_cast<int>(rect.bottom) - static_cast<int>(rect.top);
    const float rectCx = (static_cast<float>(rect.left) + static_cast<float>(rect.right)) * 0.5f;
    const float rectCy = (static_cast<float>(rect.top) + static_cast<float>(rect.bottom)) * 0.5f;

    int32_t onGhidra = -9999;
    int32_t onMinus50 = -9999;
    int32_t onMinus30 = -9999;
    const bool onGhidraOk = ReadInt32Raw(onGhidraPtr + kShockOverlayCrosshair, onGhidra);
    const bool onMinus50Ok = ReadInt32Raw(onMinus50Ptr + kShockOverlayCrosshair, onMinus50);
    const bool onMinus30Ok = ReadInt32Raw(onMinus30Ptr + kShockOverlayCrosshair, onMinus30);

    const float u = (g_screenW > 1.0f) ? (g_cx / (g_screenW - 1.0f)) : 0.5f;
    const float v = (g_screenH > 1.0f) ? (g_cy / (g_screenH - 1.0f)) : 0.5f;
    const int canvasW = g_squirrelCanvasW.load(std::memory_order_acquire);
    const int canvasH = g_squirrelCanvasH.load(std::memory_order_acquire);
    const ULONGLONG canvasAge = g_squirrelCanvasMs.load(std::memory_order_acquire) != 0
        ? nowMs - g_squirrelCanvasMs.load(std::memory_order_acquire)
        : 0;

    LogLine("!native_crosshair_rect phase=%s sig=%d orderRead=%d orderHead=%d,%d,%d,%d,%d rectOk=%d usable=%d rect=(%d,%d,%d,%d) size=%dx%d center=(%.1f,%.1f) cursor=(%.1f,%.1f) screen=%.0fx%.0f uv=(%.6f,%.6f) deltaRectCursor=(%.1f,%.1f) screenCenter=(%.1f,%.1f) deltaRectScreenCenter=(%.1f,%.1f) onGhidra=%d/%d onMinus50=%d/%d onMinus30=%d/%d squirrelCanvas=%dx%d canvasAgeMs=%llu",
        phase ? phase : "?",
        orderOk ? 1 : 0,
        orderRead ? 1 : 0,
        order[0], order[1], order[2], order[3], order[4],
        rectOk ? 1 : 0,
        rectUsable ? 1 : 0,
        rect.left, rect.top, rect.right, rect.bottom,
        rectW, rectH,
        rectCx, rectCy,
        g_cx, g_cy,
        g_screenW, g_screenH,
        u, v,
        rectCx - g_cx, rectCy - g_cy,
        g_screenW * 0.5f, g_screenH * 0.5f,
        rectCx - g_screenW * 0.5f, rectCy - g_screenH * 0.5f,
        onGhidraOk ? 1 : 0, onGhidra,
        onMinus50Ok ? 1 : 0, onMinus50,
        onMinus30Ok ? 1 : 0, onMinus30,
        canvasW, canvasH,
        canvasAge);
}

bool ReadPlayerAngles(float& yawDeg, float& pitchDeg) {
    __try {
        const auto posObj = *reinterpret_cast<uintptr_t*>(g_base + kRvaCurrentPositionObject);
        if (posObj == 0) return false;
        const uint32_t flags = *reinterpret_cast<uint32_t*>(posObj + 0x30);
        if ((flags & 0x200) != 0) return false;
        const auto posData = *reinterpret_cast<uintptr_t*>(posObj + kPositionDataOffset);
        if (posData == 0) return false;
        const short yawU = *reinterpret_cast<short*>(posObj + kObjectYawShortOffset);
        const short pitchU = *reinterpret_cast<short*>(posData + kPitchShortOffset);
        yawDeg = WrapDeg((float)yawU * kDarkUnitsToDeg);
        pitchDeg = (float)pitchU * kDarkUnitsToDeg;
        return std::isfinite(yawDeg) && std::isfinite(pitchDeg);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool ReadCamOrigin(float& x, float& y, float& z) {
    __try {
        const float* o = reinterpret_cast<const float*>(g_base + kRvaPickCamOrigin);
        x = o[0]; y = o[1]; z = o[2];
        return std::isfinite(x) && std::isfinite(y) && std::isfinite(z);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// Capture this frame's mouse turn delta and zero the accumulators so the view
// does not rotate. Accumulators are treated as float; zeroing is type-agnostic
// (0 is 0), so view suppression holds even if the delta scaling needs calibration.
bool ReadZeroAccum(float& dYaw, float& dPitch) {
    __try {
        float* yaw = reinterpret_cast<float*>(g_base + kRvaMouseTurnAccumulator);
        float* pit = reinterpret_cast<float*>(g_base + kRvaMouseLookAccumulator);
        dYaw = *yaw; dPitch = *pit;
        *yaw = 0.0f; *pit = 0.0f;
        if (!std::isfinite(dYaw)) dYaw = 0.0f;
        if (!std::isfinite(dPitch)) dPitch = 0.0f;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { dYaw = dPitch = 0.0f; return false; }
}

bool WriteAccum(float yawDelta, float pitchDelta) {
    __try {
        float* yaw = reinterpret_cast<float*>(g_base + kRvaMouseTurnAccumulator);
        float* pit = reinterpret_cast<float*>(g_base + kRvaMouseLookAccumulator);
        *yaw = std::isfinite(yawDelta) ? yawDelta : 0.0f;
        *pit = std::isfinite(pitchDelta) ? pitchDelta : 0.0f;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

float EdgePressure(float cursor, float screenSize, float marginFrac, float curve) {
    if (screenSize <= 1.0f || marginFrac <= 0.0f) return 0.0f;
    const float marginPx = std::max(1.0f, screenSize * marginFrac);
    const float maxPos = std::max(0.0f, screenSize - 1.0f);
    float pressure = 0.0f;
    if (cursor < marginPx) {
        pressure = -((marginPx - cursor) / marginPx);
    } else {
        const float rightStart = maxPos - marginPx;
        if (cursor > rightStart) pressure = (cursor - rightStart) / marginPx;
    }
    pressure = Clampf(pressure, -1.0f, 1.0f);
    if (pressure == 0.0f) return 0.0f;
    const float shaped = powf(fabsf(pressure), curve);
    return pressure < 0.0f ? -shaped : shaped;
}

bool IsGameplayCursorMode() {
    if (!g_base) return false;
    __try {
        return *reinterpret_cast<uint8_t*>(g_base + kRvaCursorModeFlag) == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ShouldDriveGameplaySelection() {
    if (!g_base || !g_selection || !g_freeAim.load(std::memory_order_relaxed)) return false;
    return IsGameplayCursorMode() && IsGameWindowForeground();
}

bool ShouldDriveSemanticSelection() {
    if (!g_base || !g_selectionSemantic || !g_freeAim.load(std::memory_order_relaxed)) return false;
    return IsGameplayCursorMode() && IsGameWindowForeground();
}

bool ShouldDriveNativeCursor() {
    if (!g_base || !g_nativeCursor || !g_freeAim.load(std::memory_order_relaxed)) return false;
    return IsGameplayCursorMode() && IsGameWindowForeground();
}

struct NativePickState {
    bool ok = false;
    int cursorMode = -1;
    int32_t object = 0;
    int32_t staging = 0;
    int32_t frob = 0;
    int cursorX = -1;
    int cursorY = -1;
};

bool ReadNativePickState(NativePickState& state) {
    if (!g_base) return false;
    __try {
        state.cursorMode = *reinterpret_cast<uint8_t*>(g_base + kRvaCursorModeFlag);
        state.object = *reinterpret_cast<int32_t*>(g_base + kRvaObjectUnderCursor);
        state.staging = *reinterpret_cast<int32_t*>(g_base + kRvaStagingHoverObject);
        state.frob = *reinterpret_cast<int32_t*>(g_base + kRvaFrobTargetCache);
        state.cursorX = *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorXFixed) >> 16;
        state.cursorY = *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorYFixed) >> 16;
        state.ok = true;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        state.ok = false;
        return false;
    }
}

void LogNativeBracketProbeState(const char* phase, uint32_t candidateObj, const NativePickState& before,
                               const NativePickState& after, bool wroteCursor, int reticleX,
                               int reticleY, int readBackX, int readBackY, const char* reason) {
    if (!g_nativeBracketProbe) return;

    const int32_t semanticTarget = g_semanticTarget.load(std::memory_order_relaxed);
    const bool nativeChanged =
        before.ok != after.ok ||
        before.object != after.object ||
        before.staging != after.staging ||
        before.frob != after.frob ||
        before.cursorMode != after.cursorMode;
    const bool interestingCandidate = semanticTarget > 0 && static_cast<int32_t>(candidateObj) == semanticTarget;
    const bool targetStateChanged =
        candidateObj != g_lastNativeBracketProbeCandidate ||
        after.object != g_lastNativeBracketProbeObject ||
        after.staging != g_lastNativeBracketProbeStaging ||
        after.frob != g_lastNativeBracketProbeFrob;
    const ULONGLONG nowMs = GetTickCount64();
    if (!nativeChanged && !interestingCandidate && !targetStateChanged &&
        nowMs - g_lastNativeBracketProbeLogMs < static_cast<ULONGLONG>(g_nativeBracketProbeIntervalMs)) {
        return;
    }
    if (!nativeChanged && !interestingCandidate &&
        nowMs - g_lastNativeBracketProbeLogMs < static_cast<ULONGLONG>(g_nativeBracketProbeIntervalMs)) {
        return;
    }

    g_lastNativeBracketProbeLogMs = nowMs;
    g_lastNativeBracketProbeCandidate = candidateObj;
    g_lastNativeBracketProbeObject = after.object;
    g_lastNativeBracketProbeStaging = after.staging;
    g_lastNativeBracketProbeFrob = after.frob;

    LogLine("!native_bracket_probe phase=%s candidate=0x%X semantic=0x%X lastWrite=0x%X freeAim=%d wroteCursor=%d cursorMode=%d->%d cursorBefore=(%d %d) cursorAfter=(%d %d) pick=(%d %d)->(%d %d) nativeBefore=(object=0x%X staging=0x%X frob=0x%X ok=%d) nativeAfter=(object=0x%X staging=0x%X frob=0x%X ok=%d) reason=%s",
        phase ? phase : "?",
        candidateObj,
        semanticTarget,
        g_lastWrittenSemanticTarget,
        g_freeAim.load(std::memory_order_relaxed) ? 1 : 0,
        wroteCursor ? 1 : 0,
        before.cursorMode,
        after.cursorMode,
        before.cursorX,
        before.cursorY,
        after.cursorX,
        after.cursorY,
        reticleX,
        reticleY,
        readBackX,
        readBackY,
        before.object,
        before.staging,
        before.frob,
        before.ok ? 1 : 0,
        after.object,
        after.staging,
        after.frob,
        after.ok ? 1 : 0,
        reason ? reason : "?");
}

void LogNativeBracketSemanticProbe(const char* phase, int32_t target, const char* reason) {
    if (!g_nativeBracketProbe) return;
    NativePickState state;
    ReadNativePickState(state);
    NativePickState before = state;
    const ULONGLONG nowMs = GetTickCount64();
    const bool changed =
        target != g_lastNativeBracketProbeObject ||
        state.object != g_lastNativeBracketProbeObject ||
        state.staging != g_lastNativeBracketProbeStaging ||
        state.frob != g_lastNativeBracketProbeFrob;
    if (!changed && nowMs - g_lastNativeBracketProbeLogMs < static_cast<ULONGLONG>(g_nativeBracketProbeIntervalMs)) {
        return;
    }
    LogNativeBracketProbeState(phase, static_cast<uint32_t>(target > 0 ? target : 0), before, state,
                               false, -1, -1, -1, -1, reason);
}

bool WriteFlatAimCursorForNativeCrosshair(const char* phase, int& reticleX, int& reticleY, int& readBackX, int& readBackY) {
    if (!ShouldDriveNativeCursor()) return false;
    const int screenW = static_cast<int>(std::max(1.0f, g_screenW));
    const int screenH = static_cast<int>(std::max(1.0f, g_screenH));
    reticleX = std::clamp(static_cast<int>(g_cx + 0.5f), 0, screenW - 1);
    reticleY = std::clamp(static_cast<int>(g_cy + 0.5f), 0, screenH - 1);
    __try {
        *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorXFixed) = static_cast<int32_t>(reticleX) << 16;
        *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorYFixed) = static_cast<int32_t>(reticleY) << 16;
        readBackX = *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorXFixed) >> 16;
        readBackY = *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorYFixed) >> 16;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    if (g_nativeCursorLog) {
        const ULONGLONG nowMs = GetTickCount64();
        const bool changed = reticleX != g_lastLoggedNativeCursorX || reticleY != g_lastLoggedNativeCursorY;
        if ((changed && nowMs - g_lastNativeCursorLogMs >= 250) || nowMs - g_lastNativeCursorLogMs >= 1000) {
            g_lastNativeCursorLogMs = nowMs;
            g_lastLoggedNativeCursorX = reticleX;
            g_lastLoggedNativeCursorY = reticleY;
            LogLine("!native cursor phase=%s reticle=(%d %d) readback=(%d %d)",
                phase ? phase : "?",
                reticleX,
                reticleY,
                readBackX,
                readBackY);
        }
    }
    return true;
}

void PublishCenteredReticleForNormalGameplay() {
    g_overlayActive.store(false, std::memory_order_release);
}

void WriteSemanticSelectionGlobals(const char* phase, int32_t target, const char* reason, ULONGLONG ageMs) {
    int32_t objectUnderCursor = 0;
    int32_t stagingHover = 0;
    int32_t frobTarget = 0;
    __try {
        *reinterpret_cast<int32_t*>(g_base + kRvaObjectUnderCursor) = target;
        *reinterpret_cast<int32_t*>(g_base + kRvaStagingHoverObject) = target;
        *reinterpret_cast<int32_t*>(g_base + kRvaFrobTargetCache) = target;
        objectUnderCursor = *reinterpret_cast<int32_t*>(g_base + kRvaObjectUnderCursor);
        stagingHover = *reinterpret_cast<int32_t*>(g_base + kRvaStagingHoverObject);
        frobTarget = *reinterpret_cast<int32_t*>(g_base + kRvaFrobTargetCache);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return;
    }

    g_lastWrittenSemanticTarget = target;
    LogNativeBracketSemanticProbe("semantic_write", target, reason);

    if (!g_selectionSemanticLog) return;
    const ULONGLONG nowMs = GetTickCount64();
    const bool changed = target != g_lastLoggedSemanticTarget;
    if (!changed && nowMs - g_lastSemanticLogMs < 500) return;
    g_lastSemanticLogMs = nowMs;
    g_lastLoggedSemanticTarget = target;
    LogLine("!semantic selection phase=%s target=0x%X object=0x%X staging=0x%X frob=0x%X ageMs=%llu reason=%s",
        phase ? phase : "?",
        target,
        objectUnderCursor,
        stagingHover,
        frobTarget,
        static_cast<unsigned long long>(ageMs),
        reason ? reason : "?");
}

void ForceSemanticTargetForNativeSelection(const char* phase) {
    if (!ShouldDriveSemanticSelection()) return;
    const int32_t target = g_semanticTarget.load(std::memory_order_relaxed);
    const ULONGLONG nowMs = GetTickCount64();
    const ULONGLONG targetMs = g_semanticTargetMs.load(std::memory_order_acquire);

    if (target <= 0) {
        WriteSemanticSelectionGlobals(phase, 0, "empty", 0);
        return;
    }

    const ULONGLONG ageMs = targetMs == 0 ? 0 : nowMs - targetMs;
    if (targetMs == 0 || ageMs > static_cast<ULONGLONG>(g_selectionSemanticMaxAgeMs)) {
        WriteSemanticSelectionGlobals(phase, 0, "stale", ageMs);
        return;
    }

    WriteSemanticSelectionGlobals(phase, target, "active", ageMs);
}

bool WriteFlatAimCursorForNativePick(int& reticleX, int& reticleY, int& readBackX, int& readBackY) {
    if (!ShouldDriveGameplaySelection()) return false;
    const int screenW = static_cast<int>(std::max(1.0f, g_screenW));
    const int screenH = static_cast<int>(std::max(1.0f, g_screenH));
    reticleX = std::clamp(static_cast<int>(g_cx + 0.5f), 0, screenW - 1);
    reticleY = std::clamp(static_cast<int>(g_cy + 0.5f), 0, screenH - 1);
    float pickX = static_cast<float>(reticleX);
    float pickY = static_cast<float>(reticleY);
    if (g_selectionFlipX) pickX = static_cast<float>(screenW - 1) - pickX;
    if (g_selectionFlipY) pickY = static_cast<float>(screenH - 1) - pickY;
    if (g_selectionSwapXY) {
        const float tmp = pickX;
        pickX = pickY;
        pickY = tmp;
    }
    const float centerX = (static_cast<float>(screenW) - 1.0f) * 0.5f;
    const float centerY = (static_cast<float>(screenH) - 1.0f) * 0.5f;
    pickX = centerX + (pickX - centerX) * g_selectionScaleX + g_selectionOffsetX;
    pickY = centerY + (pickY - centerY) * g_selectionScaleY + g_selectionOffsetY;
    const int x = std::clamp(static_cast<int>(pickX + 0.5f), 0, screenW - 1);
    const int y = std::clamp(static_cast<int>(pickY + 0.5f), 0, screenH - 1);
    __try {
        *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorXFixed) = static_cast<int32_t>(x) << 16;
        *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorYFixed) = static_cast<int32_t>(y) << 16;
        readBackX = *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorXFixed) >> 16;
        readBackY = *reinterpret_cast<int32_t*>(g_base + kRvaKexCursorYFixed) >> 16;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

void LogSelectionState(uint32_t candidateObj, int reticleX, int reticleY, int pickX, int pickY) {
    if (!g_selectionLog || !g_base) return;
    int32_t objectUnderCursor = 0;
    int32_t stagingHover = 0;
    int32_t frobTarget = 0;
    __try {
        objectUnderCursor = *reinterpret_cast<int32_t*>(g_base + kRvaObjectUnderCursor);
        stagingHover = *reinterpret_cast<int32_t*>(g_base + kRvaStagingHoverObject);
        frobTarget = *reinterpret_cast<int32_t*>(g_base + kRvaFrobTargetCache);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return;
    }

    const ULONGLONG nowMs = GetTickCount64();
    const bool changed = objectUnderCursor != g_lastLoggedObject || frobTarget != g_lastLoggedFrob;
    if (!changed && nowMs - g_lastSelectionLogMs < 500) return;
    g_lastSelectionLogMs = nowMs;
    g_lastLoggedObject = objectUnderCursor;
    g_lastLoggedFrob = frobTarget;
    LogLine("!selection reticle=(%d %d) pick=(%d %d) candidate=0x%X object=0x%X staging=0x%X frob=0x%X",
        reticleX,
        reticleY,
        pickX,
        pickY,
        candidateObj,
        objectUnderCursor,
        stagingHover,
        frobTarget);
}

void __fastcall Hook_HoverCandidate(uint32_t objId, void* arg2, uint32_t arg3) {
    NativePickState before;
    if (g_nativeBracketProbe) {
        ReadNativePickState(before);
    }

    int reticleX = -1;
    int reticleY = -1;
    int readBackX = -1;
    int readBackY = -1;
    const bool wroteCursor = WriteFlatAimCursorForNativePick(reticleX, reticleY, readBackX, readBackY);

    if (g_realHoverCandidate) {
        g_realHoverCandidate(objId, arg2, arg3);
    }

    if (g_nativeBracketProbe) {
        NativePickState after;
        ReadNativePickState(after);
        LogNativeBracketProbeState("hover_candidate", objId, before, after, wroteCursor,
                                   reticleX, reticleY, readBackX, readBackY,
                                   wroteCursor ? "legacy_selection_cursor_write" : "log_only");
    }

    if (wroteCursor) {
        LogSelectionState(objId, reticleX, reticleY, readBackX, readBackY);
    }
}

bool SafeConfigNameEquals(const char* name, const char* expected) {
    if (!name || !expected) return false;
    __try {
        return std::strcmp(name, expected) == 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool IsSquirrelBridgeFresh() {
    if (!g_requireSquirrelBridge) return true;
    const ULONGLONG aliveMs = g_squirrelAliveMs.load(std::memory_order_acquire);
    if (aliveMs == 0) return false;
    return GetTickCount64() - aliveMs <= static_cast<ULONGLONG>(g_squirrelAliveMaxAgeMs);
}

bool ShouldBlockFreeAimForBridge() {
    return g_blockWithoutBridge && g_requireSquirrelBridge && !IsSquirrelBridgeFresh();
}

void LogSquirrelBridgeWait(const char* context) {
    const ULONGLONG nowMs = GetTickCount64();
    if (nowMs - g_lastBridgeWaitLogMs < 1000) return;
    g_lastBridgeWaitLogMs = nowMs;
    const ULONGLONG aliveMs = g_squirrelAliveMs.load(std::memory_order_acquire);
    const ULONGLONG ageMs = aliveMs == 0 ? 0 : nowMs - aliveMs;
    LogLine("!Freelook: waiting for SS2FA Squirrel bridge (%s, ageMs=%llu, maxAgeMs=%d)",
        context ? context : "unknown",
        static_cast<unsigned long long>(ageMs),
        g_squirrelAliveMaxAgeMs);
}

void LogConfigBridgeDisabled(const char* context) {
    const ULONGLONG nowMs = GetTickCount64();
    if (nowMs - g_lastConfigBridgeDisabledLogMs < 1000) return;
    g_lastConfigBridgeDisabledLogMs = nowMs;
    LogLine("!Freelook: config bridge disabled; skipped %s", context ? context : "publish");
}

bool CaptureFlatAimPrivateConfig(const char* name, const char* value) {
    if (SafeConfigNameEquals(name, "ss2fa_alive")) {
        g_squirrelAliveMs.store(GetTickCount64(), std::memory_order_release);
        return true;
    }
    if (SafeConfigNameEquals(name, "ss2fa_canvas")) {
        int w = 0;
        int h = 0;
        __try {
            if (value) {
                std::sscanf(value, "%d %d", &w, &h);
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            w = 0;
            h = 0;
        }
        if (w >= 320 && h >= 200) {
            g_squirrelCanvasW.store(w, std::memory_order_release);
            g_squirrelCanvasH.store(h, std::memory_order_release);
            g_squirrelCanvasMs.store(GetTickCount64(), std::memory_order_release);
        }
        return true;
    }
    if (!SafeConfigNameEquals(name, "ss2fa_hl")) return false;
    int target = 0;
    __try {
        target = value ? std::atoi(value) : 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        target = 0;
    }
    g_semanticTarget.store(target, std::memory_order_relaxed);
    g_semanticTargetMs.store(target > 0 ? GetTickCount64() : 0, std::memory_order_release);
    return true;
}

void __fastcall Hook_KexSetConfigRaw(const char* name, int flags, char* value) {
    if (CaptureFlatAimPrivateConfig(name, value)) {
        return;
    }
    if (g_realKexSetConfigRaw) {
        g_realKexSetConfigRaw(name, flags, value);
    }
}

bool CanPublishFlatAimConfig() {
    if (!g_base || !g_configOk || !g_configHookInstalled) return false;
    return !g_requireSquirrelBridge || IsSquirrelBridgeFresh();
}

void SetRawConfig(const char* name, const char* value) {
    if (!g_base || !g_configOk) return;
    if (!g_configHookInstalled) {
        LogConfigBridgeDisabled(name);
        return;
    }
    if (g_requireSquirrelBridge && name && std::strncmp(name, "ss2fa_", 6) == 0 && !IsSquirrelBridgeFresh()) {
        LogSquirrelBridgeWait(name);
        return;
    }
    __try {
        if (g_realKexSetConfigRaw) {
            g_realKexSetConfigRaw(name, 0, const_cast<char*>(value));
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
}

void SetAimConfig(const char* value) {
    SetRawConfig("ss2fa_aim", value);
}

void SetRawConfigInt(const char* name, int value) {
    char buf[32];
    _snprintf_s(buf, sizeof(buf), _TRUNCATE, "%d", value);
    SetRawConfig(name, buf);
}

void SetRawConfigFloat(const char* name, float value) {
    char buf[64];
    _snprintf_s(buf, sizeof(buf), _TRUNCATE, "%.6f", value);
    SetRawConfig(name, buf);
}

void PublishSquirrelTunables() {
    SetRawConfigInt("ss2fa_projectile_mode", g_projectileMode);
    SetRawConfigInt("ss2fa_projectile_native_skip_create", g_projectileNativeSkipCreate);
    SetRawConfigInt("ss2fa_proj_viewframe", g_projViewFrame);
    SetRawConfigInt("ss2fa_proj_skip_facing", g_projSkipFacing);
    SetRawConfigInt("ss2fa_proj_skip_vel", g_projSkipVel);
    SetRawConfigInt("ss2fa_proj_facing_mode", g_projFacingMode);
    SetRawConfigInt("ss2fa_aim_velocity_mode", g_aimVelocityMode);
    SetRawConfigInt("ss2fa_aim_log", g_aimLog);
    SetRawConfigFloat("ss2fa_projectile_heading_sign", g_projectileHeadingSign);
    SetRawConfigFloat("ss2fa_projectile_pitch_sign", g_projectilePitchSign);
    SetRawConfigFloat("ss2fa_projectile_heading_offset", g_projectileHeadingOffsetDeg);
    SetRawConfigFloat("ss2fa_projectile_pitch_offset", g_projectilePitchOffsetDeg);
    SetRawConfigFloat("ss2fa_weapon_heading_sign", g_weaponHeadingSign);
    SetRawConfigFloat("ss2fa_weapon_pitch_sign", g_weaponPitchSign);
    SetRawConfigFloat("ss2fa_weapon_bank_deg", g_weaponBankDeg);
    SetRawConfigInt("ss2fa_weapon_lock_heading", g_weaponLockHeading);
    SetRawConfigInt("ss2fa_weapon_lock_pitch", g_weaponLockPitch);
    SetRawConfigInt("ss2fa_weapon_lock_bank", g_weaponLockBank);
    SetRawConfigInt("ss2fa_weapon_follow_mode", g_weaponFollowMode);
    SetRawConfigInt("ss2fa_weapon_screen_axis_variant", g_weaponScreenAxisVariant);
    SetRawConfigInt("ss2fa_weapon_proxy_hide_native", g_weaponProxyHideNative);
    SetRawConfigInt("ss2fa_weapon_proxy_facing_mode", g_weaponProxyFacingMode);
    SetRawConfigFloat("ss2fa_weapon_proxy_scale", g_weaponProxyScale);
    SetRawConfigFloat("ss2fa_weapon_proxy_native_hide_scale", g_weaponProxyNativeHideScale);
    SetRawConfigFloat("ss2fa_weapon_proxy_forward", g_weaponProxyForward);
    SetRawConfigFloat("ss2fa_weapon_proxy_left", g_weaponProxyLeft);
    SetRawConfigFloat("ss2fa_weapon_proxy_up", g_weaponProxyUp);
    SetRawConfigFloat("ss2fa_weapon_proxy_heading_offset", g_weaponProxyHeadingOffset);
    SetRawConfigFloat("ss2fa_weapon_proxy_pitch_offset", g_weaponProxyPitchOffset);
    SetRawConfigFloat("ss2fa_weapon_proxy_bank_offset", g_weaponProxyBankOffset);
    SetRawConfigFloat("ss2fa_weapon_proxy_look_distance", g_weaponProxyLookDistance);
    SetRawConfigFloat("ss2fa_weapon_proxy_roll_sign", g_weaponProxyRollSign);
    SetRawConfigInt("ss2fa_weapon_proxy_flip_x", g_weaponProxyFlipX);
    SetRawConfigInt("ss2fa_weapon_proxy_axis_log", g_weaponProxyAxisLog);
    SetRawConfigInt("ss2fa_weapon_proxy_axis_draw", g_weaponProxyAxisDraw);
    SetRawConfigFloat("ss2fa_weapon_proxy_axis_len", g_weaponProxyAxisLen);
    SetRawConfigInt("ss2fa_weapon_effect_follow", g_weaponEffectFollow);
    SetRawConfigInt("ss2fa_weapon_effect_recreate", g_weaponEffectRecreate);
    SetRawConfigInt("ss2fa_weapon_effect_log", g_weaponEffectLog);
    SetRawConfigInt("ss2fa_weapon_proxy_pivot_enable", g_weaponProxyPivotEnable);
    SetRawConfigInt("ss2fa_weapon_view_rotate", g_weaponViewRotate);
    SetRawConfigInt("ss2fa_weapon_proxy_pivot_all_weapons", g_weaponProxyPivotAllWeapons);
    SetRawConfigFloat("ss2fa_weapon_proxy_pivot_long_forward", g_weaponProxyPivotLongForward);
    SetRawConfigFloat("ss2fa_weapon_proxy_pivot_long_left", g_weaponProxyPivotLongLeft);
    SetRawConfigFloat("ss2fa_weapon_proxy_pivot_long_up", g_weaponProxyPivotLongUp);
    SetRawConfigInt("ss2fa_melee_enable", g_meleeEnable);
    SetRawConfigInt("ss2fa_melee_orientation_mode", g_meleeOrientationMode);
    SetRawConfigFloat("ss2fa_melee_heading_sign", g_meleeHeadingSign);
    SetRawConfigFloat("ss2fa_melee_pitch_sign", g_meleePitchSign);
    SetRawConfigFloat("ss2fa_melee_bank_sign", g_meleeBankSign);
    SetRawConfigFloat("ss2fa_melee_look_distance", g_meleeLookDistance);
    SetRawConfigFloat("ss2fa_melee_forward_offset", g_meleeForwardOffset);
    SetRawConfigFloat("ss2fa_melee_left_offset", g_meleeLeftOffset);
    SetRawConfigFloat("ss2fa_melee_up_offset", g_meleeUpOffset);
    SetRawConfigFloat("ss2fa_melee_left_per_deg", g_meleeLeftPerDeg);
    SetRawConfigFloat("ss2fa_melee_up_per_deg", g_meleeUpPerDeg);
    SetRawConfigFloat("ss2fa_melee_forward_per_deg", g_meleeForwardPerDeg);
    SetRawConfigFloat("ss2fa_melee_heading_offset", g_meleeHeadingOffset);
    SetRawConfigFloat("ss2fa_melee_pitch_offset", g_meleePitchOffset);
    SetRawConfigFloat("ss2fa_melee_bank_offset", g_meleeBankOffset);
    SetRawConfigInt("ss2fa_melee_pose_log", g_meleePoseLog);
    SetRawConfigFloat("ss2fa_weapon_offset_left_per_deg", g_weaponOffsetLeftPerDeg);
    SetRawConfigFloat("ss2fa_weapon_offset_up_per_deg", g_weaponOffsetUpPerDeg);
    SetRawConfigFloat("ss2fa_weapon_offset_forward", g_weaponOffsetForward);
    SetRawConfigFloat("ss2fa_weapon_pitch_comp_heading_scale", g_weaponPitchCompHeadingScale);
    SetRawConfigFloat("ss2fa_weapon_pitch_comp_bank_sign", g_weaponPitchCompBankSign);
    SetRawConfigFloat("ss2fa_weapon_screen_min_cos", g_weaponScreenMinCos);
    SetRawConfigInt("ss2fa_native_hud_reticle", g_nativeHudReticle ? 1 : 0);
    SetRawConfigInt("ss2fa_native_hud_hide_original", g_nativeHudHideOriginal ? 1 : 0);
    SetRawConfigFloat("ss2fa_native_hud_reticle_offset_x", g_nativeHudReticleOffsetX);
    SetRawConfigFloat("ss2fa_native_hud_reticle_offset_y", g_nativeHudReticleOffsetY);
    SetRawConfigInt("ss2fa_selection_semantic", g_selectionSemantic ? 1 : 0);
    SetRawConfigInt("ss2fa_selection_semantic_log", g_selectionSemanticLog ? 1 : 0);
    SetRawConfigInt("ss2fa_selection_debug_marker", g_selectionDebugMarker ? 1 : 0);
    SetRawConfigInt("ss2fa_selection_debug_marker_log", g_selectionDebugMarkerLog ? 1 : 0);
    SetRawConfigInt("ss2fa_selection_debug_marker_style", g_selectionDebugMarkerStyle);
    SetRawConfigInt("ss2fa_selection_debug_marker_half_w_px", g_selectionDebugMarkerHalfW);
    SetRawConfigInt("ss2fa_selection_debug_marker_half_h_px", g_selectionDebugMarkerHalfH);
    SetRawConfigFloat("ss2fa_selection_semantic_reach", g_selectionSemanticReach);
    SetRawConfigFloat("ss2fa_selection_semantic_radius", g_selectionSemanticRadius);
    SetRawConfigInt("ss2fa_selection_semantic_mode", g_selectionSemanticMode);
    SetRawConfigFloat("ss2fa_selection_screen_radius_px", g_selectionScreenRadiusPx);
    SetRawConfigFloat("ss2fa_selection_screen_probe_margin_px", g_selectionScreenProbeMarginPx);
    SetRawConfigInt("ss2fa_selection_screen_use_reticle_bias", g_selectionScreenUseReticleBias);
    SetRawConfigInt("ss2fa_selection_screen_require_rendered", g_selectionScreenRequireRendered);
    SetRawConfigInt("ss2fa_selection_semantic_interval_ms", g_selectionSemanticIntervalMs);
    SetRawConfigInt("ss2fa_selection_semantic_publish_interval_ms", g_selectionSemanticPublishIntervalMs);
    SetRawConfigInt("ss2fa_selection_semantic_max_obj", g_selectionSemanticMaxObj);
    SetRawConfigInt("ss2fa_selection_semantic_log_top", g_selectionSemanticLogTop);
    SetRawConfigInt("ss2fa_selection_semantic_require", g_selectionSemanticRequire);
}

bool PublishAimInvalid(const char* reason = nullptr) {
    if (!CanPublishFlatAimConfig()) return false;
    SetAimConfig("0 0 0 0 0 0 1 0 0 0.5 0.5"); // valid=0 -> Squirrel reverts to normal play
    if (reason) LogLine("aim invalid published (%s)", reason);
    return true;
}

void ClearFreeAimRuntimeState() {
    g_overlayActive.store(false, std::memory_order_release);
    g_semanticTarget.store(0, std::memory_order_relaxed);
    g_semanticTargetMs.store(0, std::memory_order_release);
    g_lastWrittenSemanticTarget = -1;
    g_wasActive = false;
    g_cxInit = false;
}

void DeactivateFreeAim(const char* reason) {
    const bool wasActive = g_freeAim.exchange(false, std::memory_order_acq_rel);
    if (wasActive || g_wasActive) {
        const bool published = PublishAimInvalid(reason);
        g_needPublishInvalidAim.store(!published, std::memory_order_release);
    }
    ClearFreeAimRuntimeState();
    if (wasActive) {
        LogLine("!Freelook OFF (%s)", reason ? reason : "unknown");
    }
}

void ResetFreelookSessionState() {
    g_cxInit = false;
    g_loggedAimPublish = false;
    g_loggedAccumReadFailure = false;
    g_loggedAngleReadFailure = false;
    g_lastActiveLogMs = 0;
    g_lastSelectionLogMs = 0;
    g_lastLoggedObject = -1;
    g_lastLoggedFrob = -1;
    g_lastSemanticLogMs = 0;
    g_lastLoggedSemanticTarget = -1;
    g_lastBridgeWaitLogMs = 0;
    g_lastNativeCursorLogMs = 0;
    g_lastLoggedNativeCursorX = -1;
    g_lastLoggedNativeCursorY = -1;
    g_lastNativeBracketProbeLogMs = 0;
    g_lastNativeBracketProbeCandidate = 0xFFFFFFFFu;
    g_lastNativeBracketProbeObject = -1;
    g_lastNativeBracketProbeStaging = -1;
    g_lastNativeBracketProbeFrob = -1;
    g_lastEdgePanLogMs = 0;
    g_lastNativeCrosshairRectProbeLogMs = 0;
    if (g_edgePanPressType == kEdgePanPressAlways || g_edgePanPressType == kEdgePanPressToggle) {
        g_edgePanToggleActive = true;
    } else {
        g_edgePanToggleActive = false;
    }
    g_edgePanPrevDown = (GetAsyncKeyState(g_edgePanVk) & 0x8000) != 0;
}

bool BeginFreelookSession(const char* reason) {
    ResetFreelookSessionState();
    const bool bridgeFresh = IsSquirrelBridgeFresh();
    LogLine("ini loaded display=(auto=%d %.0fx%.0f fov=%.1f) freelook=(vk=0x%X press=%s) sens=(%.3f %.3f) cursorSign=(%.1f %.1f) worldSign=(%.1f %.1f) worldOffset=(%.1f %.1f) projectile_mode=%d projectileSign=(%.1f %.1f) weaponSign=(%.1f %.1f) weaponBank=%.1f weaponLock=(%d,%d,%d) weaponMode=%d weaponAxisVariant=%d weaponProxy=(hide=%d facingMode=%d scale=%.2f nativeHideScale=%.4f local=%.2f,%.2f,%.2f rotOff=%.1f,%.1f,%.1f lookDist=%.1f rollSign=%.1f flipX=%d axis=(log=%d draw=%d len=%.2f)) weaponOffset=(%.4f,%.4f,%.2f) weaponPitchComp=(headingScale=%.2f bankSign=%.2f screenMinCos=%.2f) nativeHud=(reticle=%d hide=%d offset=%.1f,%.1f) selection=%d semantic=%d marker=(%d style=%d box=%d,%d) nativeCursor=%d nativeBracketProbe=(%d hook=%d interval=%d) semanticScan=(mode=%d reach=%.1f radius=%.2f screenRadius=%.1f screenProbe=%.1f screenBias=%d rendered=%d interval=%d publish=%d maxObj=%d require=%d maxAge=%d) bridge=(require=%d block=%d aliveFresh=%d aliveMax=%d configHook=%d configInstalled=%d) selectionMap=(flipX=%d flipY=%d swap=%d scale=%.2f,%.2f offset=%.1f,%.1f) reticle=%d hideOriginal=%d cheats=%d",
        g_autoDisplay, g_screenW, g_screenH, g_fovDeg, g_toggleVk, FreelookPressTypeName(g_freelookPressType),
        g_sensX, g_sensY, g_yawSign, g_pitchSign, g_worldYawSign, g_worldPitchSign,
        g_worldYawOffsetDeg, g_worldPitchOffsetDeg, g_projectileMode,
        g_projectileHeadingSign, g_projectilePitchSign,
        g_weaponHeadingSign, g_weaponPitchSign,
        g_weaponBankDeg, g_weaponLockHeading, g_weaponLockPitch, g_weaponLockBank,
        g_weaponFollowMode, g_weaponScreenAxisVariant,
        g_weaponProxyHideNative, g_weaponProxyFacingMode, g_weaponProxyScale,
        g_weaponProxyNativeHideScale,
        g_weaponProxyForward, g_weaponProxyLeft, g_weaponProxyUp,
        g_weaponProxyHeadingOffset, g_weaponProxyPitchOffset, g_weaponProxyBankOffset,
        g_weaponProxyLookDistance, g_weaponProxyRollSign,
        g_weaponProxyFlipX, g_weaponProxyAxisLog, g_weaponProxyAxisDraw, g_weaponProxyAxisLen,
        g_weaponOffsetLeftPerDeg, g_weaponOffsetUpPerDeg, g_weaponOffsetForward,
        g_weaponPitchCompHeadingScale, g_weaponPitchCompBankSign, g_weaponScreenMinCos,
        g_nativeHudReticle ? 1 : 0, g_nativeHudHideOriginal ? 1 : 0,
        g_nativeHudReticleOffsetX, g_nativeHudReticleOffsetY,
        g_selection ? 1 : 0, g_selectionSemantic ? 1 : 0,
        g_selectionDebugMarker ? 1 : 0, g_selectionDebugMarkerStyle,
        g_selectionDebugMarkerHalfW, g_selectionDebugMarkerHalfH,
        g_nativeCursor ? 1 : 0,
        g_nativeBracketProbe ? 1 : 0, g_nativeBracketProbeHook ? 1 : 0,
        g_nativeBracketProbeIntervalMs,
        g_selectionSemanticMode, g_selectionSemanticReach, g_selectionSemanticRadius,
        g_selectionScreenRadiusPx, g_selectionScreenProbeMarginPx,
        g_selectionScreenUseReticleBias, g_selectionScreenRequireRendered,
        g_selectionSemanticIntervalMs,
        g_selectionSemanticPublishIntervalMs,
        g_selectionSemanticMaxObj, g_selectionSemanticRequire, g_selectionSemanticMaxAgeMs,
        g_requireSquirrelBridge ? 1 : 0, g_blockWithoutBridge ? 1 : 0,
        bridgeFresh ? 1 : 0, g_squirrelAliveMaxAgeMs,
        g_configHookEnabled ? 1 : 0, g_configHookInstalled ? 1 : 0,
        g_selectionFlipX ? 1 : 0, g_selectionFlipY ? 1 : 0, g_selectionSwapXY ? 1 : 0,
        g_selectionScaleX, g_selectionScaleY, g_selectionOffsetX, g_selectionOffsetY,
        g_reticle ? 1 : 0, g_hideOriginal ? 1 : 0, g_allowCheatTuning);
    LogLine("projectile defaults proj_viewframe=%d proj_skip_facing=%d proj_skip_vel=%d proj_facing_mode=%d weapon_effect=(follow=%d recreate=%d log=%d) pivot=(enable=%d all=%d long=%.2f,%.2f,%.2f) melee=(enable=%d orient=%d signs=%.1f,%.1f,%.1f offset=%.2f,%.2f,%.2f perDeg=%.4f,%.4f,%.4f poseLog=%d) edgePan=(enable=%d vk=0x%X press=%s active=%d margin=%.2f,%.2f max=%.2f,%.2f curve=%.2f sign=%.1f,%.1f log=%d) nativeCrosshairRectProbe=(%d interval=%d)",
        g_projViewFrame, g_projSkipFacing, g_projSkipVel, g_projFacingMode,
        g_weaponEffectFollow, g_weaponEffectRecreate, g_weaponEffectLog,
        g_weaponProxyPivotEnable, g_weaponProxyPivotAllWeapons,
        g_weaponProxyPivotLongForward, g_weaponProxyPivotLongLeft, g_weaponProxyPivotLongUp,
        g_meleeEnable, g_meleeOrientationMode, g_meleeHeadingSign, g_meleePitchSign, g_meleeBankSign,
        g_meleeForwardOffset, g_meleeLeftOffset, g_meleeUpOffset,
        g_meleeLeftPerDeg, g_meleeUpPerDeg, g_meleeForwardPerDeg, g_meleePoseLog,
        g_edgePanEnabled, g_edgePanVk, EdgePanPressTypeName(g_edgePanPressType), g_edgePanToggleActive ? 1 : 0,
        g_edgePanMarginX, g_edgePanMarginY,
        g_edgePanMaxYawAccum, g_edgePanMaxPitchAccum, g_edgePanCurve,
        g_edgePanYawSign, g_edgePanPitchSign, g_edgePanLog,
        g_nativeCrosshairRectProbe, g_nativeCrosshairRectProbeIntervalMs);
    if (ShouldBlockFreeAimForBridge()) {
        g_freeAim.store(false, std::memory_order_release);
        ClearFreeAimRuntimeState();
        LogSquirrelBridgeWait(reason ? reason : "activate");
        LogLine("!Freelook blocked (squirrel_bridge_missing)");
        return false;
    }
    g_freeAim.store(true, std::memory_order_release);
    PublishSquirrelTunables();
    LogLine("!Freelook ON (%s press=%s edgePan=%s)",
        reason ? reason : "hotkey",
        FreelookPressTypeName(g_freelookPressType),
        EdgePanPressTypeName(g_edgePanPressType));
    return true;
}

void PollEdgePanControl() {
    if (!g_freeAim.load(std::memory_order_relaxed)) return;
    if (g_edgePanPressType != kEdgePanPressToggle && g_edgePanPressType != kEdgePanPressHoldLock) return;
    const bool down = (GetAsyncKeyState(g_edgePanVk) & 0x8000) != 0;
    if (g_edgePanPressType == kEdgePanPressToggle) {
        if (down && !g_edgePanPrevDown) {
            g_edgePanToggleActive = !g_edgePanToggleActive;
            LogLine("!Freelook edge-pan %s", g_edgePanToggleActive ? "unlocked" : "locked");
        }
    } else {
        const bool active = !down;
        if (active != g_edgePanToggleActive) {
            g_edgePanToggleActive = active;
            LogLine("!Freelook edge-pan %s", g_edgePanToggleActive ? "unlocked" : "locked");
        }
    }
    g_edgePanPrevDown = down;
}

bool IsEdgePanActive() {
    if (!g_edgePanEnabled || g_edgePanPressType == kEdgePanPressOff) return false;
    if (g_edgePanPressType == kEdgePanPressAlways) return true;
    return g_edgePanToggleActive;
}

void PollFreelookInput() {
    static bool prev = false;
    const bool down = (GetAsyncKeyState(g_toggleVk) & 0x8000) != 0;
    if (down && !prev) {
        LoadIni();
        if (g_freelookPressType == kFreelookPressHold) {
            if (!g_freeAim.load(std::memory_order_relaxed)) {
                BeginFreelookSession("hold");
            }
        } else {
            const bool activate = !g_freeAim.load(std::memory_order_relaxed);
            if (activate) {
                BeginFreelookSession("toggle");
            } else {
                DeactivateFreeAim("hotkey");
            }
        }
    } else if (!down && prev && g_freelookPressType == kFreelookPressHold &&
               g_freeAim.load(std::memory_order_relaxed)) {
        DeactivateFreeAim("key_release");
    }
    prev = down;
}

uint64_t __fastcall Hook_PlayerTurnTilt(int* cameraState, int dt) {
    PollFreelookInput();
    PollEdgePanControl();
    if (g_freeAim.load(std::memory_order_relaxed) && !IsGameWindowForeground()) {
        DeactivateFreeAim("focus_lost");
    }
    if (g_freeAim.load(std::memory_order_relaxed) && !IsGameplayCursorMode()) {
        DeactivateFreeAim("cursor_mode");
    }

    const bool freeAimActive = g_freeAim.load(std::memory_order_relaxed);
    const bool bridgeFresh = !freeAimActive || IsSquirrelBridgeFresh();
    uint64_t result = 0;
    bool realTurnCalled = false;
    if (freeAimActive && !bridgeFresh) {
        if (g_blockWithoutBridge && g_requireSquirrelBridge) {
            LogSquirrelBridgeWait("turn");
            DeactivateFreeAim("squirrel_bridge_missing");
        } else {
            LogSquirrelBridgeWait("turn");
            g_overlayActive.store(false, std::memory_order_release);
            g_semanticTarget.store(0, std::memory_order_relaxed);
            g_semanticTargetMs.store(0, std::memory_order_release);
            g_wasActive = false;
        }
    } else if (freeAimActive) {
        float dYaw = 0.0f, dPitch = 0.0f;
        if (!ReadZeroAccum(dYaw, dPitch) && !g_loggedAccumReadFailure) {
            g_loggedAccumReadFailure = true;
            LogLine("!Freelook: failed to read/zero mouse accumulators");
        }

        RefreshDisplayFromSquirrelCanvas(true);
        if (!g_cxInit) { g_cx = g_screenW * 0.5f; g_cy = g_screenH * 0.5f; g_cxInit = true; }
        g_cx = Clampf(g_cx + dYaw * g_sensX * g_yawSign, 0.0f, g_screenW - 1.0f);
        g_cy = Clampf(g_cy + dPitch * g_sensY * g_pitchSign, 0.0f, g_screenH - 1.0f);
        g_overlayCursorX.store(static_cast<int>(g_cx + 0.5f), std::memory_order_relaxed);
        g_overlayCursorY.store(static_cast<int>(g_cy + 0.5f), std::memory_order_relaxed);
        g_overlayActive.store(g_reticle || g_hideOriginal, std::memory_order_release);
        ProbeNativeCrosshairOverlay("turn");
        int nativeCursorX = -1;
        int nativeCursorY = -1;
        int nativeReadBackX = -1;
        int nativeReadBackY = -1;
        WriteFlatAimCursorForNativeCrosshair("turn_pre", nativeCursorX, nativeCursorY, nativeReadBackX, nativeReadBackY);

        const bool edgePanActive = IsEdgePanActive();
        const float edgePressureX = edgePanActive ? EdgePressure(g_cx, g_screenW, g_edgePanMarginX, g_edgePanCurve) : 0.0f;
        const float edgePressureY = edgePanActive ? EdgePressure(g_cy, g_screenH, g_edgePanMarginY, g_edgePanCurve) : 0.0f;
        const float edgePanYaw = edgePressureX * g_edgePanMaxYawAccum * g_edgePanYawSign;
        const float edgePanPitch = edgePressureY * g_edgePanMaxPitchAccum * g_edgePanPitchSign;
        if (edgePanActive && (fabsf(edgePanYaw) > 0.0001f || fabsf(edgePanPitch) > 0.0001f)) {
            if (!WriteAccum(edgePanYaw, edgePanPitch) && !g_loggedAccumReadFailure) {
                g_loggedAccumReadFailure = true;
                LogLine("!Freelook: failed to write edge-pan accumulators");
            }
            const ULONGLONG nowMs = GetTickCount64();
            if (g_edgePanLog && nowMs - g_lastEdgePanLogMs >= 500) {
                g_lastEdgePanLogMs = nowMs;
                LogLine("!edge pan pressure=(%.3f %.3f) accum=(%.3f %.3f) cursor=(%.1f %.1f)",
                    edgePressureX, edgePressureY, edgePanYaw, edgePanPitch, g_cx, g_cy);
            }
        }

        result = g_realTurnTilt(cameraState, dt);
        realTurnCalled = true;

        float yawDeg = 0.0f, pitchDeg = 0.0f;
        if (ReadPlayerAngles(yawDeg, pitchDeg)) {
            const float halfTanV = tanf(0.5f * g_fovDeg * kPI / 180.0f);
            const float halfTanH = halfTanV * (g_screenW / g_screenH);
            const float u = g_cx / (g_screenW - 1.0f);
            const float v = g_cy / (g_screenH - 1.0f);
            const float xTan = (2.0f * u - 1.0f) * halfTanH;
            const float yTan = (1.0f - 2.0f * v) * halfTanV;
            const float dyaw = atanf(xTan) * 180.0f / kPI;     // crosshair offset from centre
            const float dpitch = atanf(yTan) * 180.0f / kPI;
            const float worldYaw = yawDeg + dyaw * g_worldYawSign + g_worldYawOffsetDeg;
            const float worldPitch = pitchDeg + dpitch * g_worldPitchSign + g_worldPitchOffsetDeg;
            const float wy = worldYaw * kPI / 180.0f;
            const float wp = worldPitch * kPI / 180.0f;
            // Dark heading/pitch -> unit vector. Dark pitch is positive downward.
            const float wdx = sinf(wy) * cosf(wp);
            const float wdy = cosf(wy) * cosf(wp);
            const float wdz = -sinf(wp);
            float wox = 0.0f, woy = 0.0f, woz = 0.0f;
            ReadCamOrigin(wox, woy, woz);

            char buf[256];
            _snprintf_s(buf, sizeof(buf), _TRUNCATE,
                "1 %.3f %.3f %.3f %.5f %.5f %.5f %.3f %.3f %.4f %.4f",
                wox, woy, woz, wdx, wdy, wdz, dyaw, dpitch, u, v);
            SetAimConfig(buf);
            if (!g_loggedAimPublish) {
                g_loggedAimPublish = true;
                LogLine("aim publish active u=%.3f v=%.3f dyaw=%.2f dpitch=%.2f dAccum=(%.3f %.3f) edgeAccum=(%.3f %.3f)",
                    u, v, dyaw, dpitch, dYaw, dPitch, edgePanYaw, edgePanPitch);
            }
            const ULONGLONG nowMs = GetTickCount64();
            if (nowMs - g_lastActiveLogMs >= 1000) {
                g_lastActiveLogMs = nowMs;
                LogLine("aim active u=%.3f v=%.3f dyaw=%.2f dpitch=%.2f dAccum=(%.3f %.3f) edgeAccum=(%.3f %.3f) cursor=(%.1f %.1f)",
                    u, v, dyaw, dpitch, dYaw, dPitch, edgePanYaw, edgePanPitch, g_cx, g_cy);
            }
            if (g_log) LogLine("aim u=%.3f v=%.3f dyaw=%.2f dpitch=%.2f wd=(%.3f %.3f %.3f)",
                u, v, dyaw, dpitch, wdx, wdy, wdz);
        } else if (!g_loggedAngleReadFailure) {
            g_loggedAngleReadFailure = true;
            LogLine("!Freelook: could not read player yaw/pitch; aim publish skipped");
        }
        g_wasActive = true;
    } else if (g_wasActive) {
        DeactivateFreeAim("inactive");
    } else {
        if (g_needPublishInvalidAim.load(std::memory_order_acquire) && PublishAimInvalid("startup_clear")) {
            g_needPublishInvalidAim.store(false, std::memory_order_release);
        }
        PublishCenteredReticleForNormalGameplay();
    }
    if (!realTurnCalled) {
        result = g_realTurnTilt(cameraState, dt);
    }
    if (g_freeAim.load(std::memory_order_relaxed) && IsSquirrelBridgeFresh()) {
        int nativeCursorX = -1;
        int nativeCursorY = -1;
        int nativeReadBackX = -1;
        int nativeReadBackY = -1;
        WriteFlatAimCursorForNativeCrosshair("turn_post", nativeCursorX, nativeCursorY, nativeReadBackX, nativeReadBackY);
        ForceSemanticTargetForNativeSelection("turn");
    }
    return result;
}

DWORD WINAPI InitThread(LPVOID) {
    DeriveGameDirPaths();
    g_processId.store(GetCurrentProcessId(), std::memory_order_relaxed);
    LoadIni();
    if ((g_reticle || g_hideOriginal) && !g_overlayThread) {
        g_overlayThread = CreateThread(nullptr, 0, OverlayThreadProc, nullptr, 0, nullptr);
        if (!g_overlayThread) {
            LogLine("!Freelook: reticle overlay thread failed to start");
        }
    } else if (!g_reticle && !g_hideOriginal) {
        LogLine("Freelook: diagnostic overlay disabled; native crosshair left untouched");
    }
    g_base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    if (!g_base) { LogLine("!Freelook: no main module"); return 0; }

    if (MH_Initialize() != MH_OK) { LogLine("!Freelook: MH_Initialize failed"); return 0; }

    // Wait for the target prologue to be present (injection can precede mapping).
    void* tt = g_base + kRvaPlayerTurnTilt;
    for (int tries = 0; tries < 200; ++tries) {
        if (ReadCodeBytesMatch((uint8_t*)tt, kPlayerTurnTiltPrologue, sizeof(kPlayerTurnTiltPrologue))) break;
        Sleep(50);
    }
    if (!ReadCodeBytesMatch((uint8_t*)tt, kPlayerTurnTiltPrologue, sizeof(kPlayerTurnTiltPrologue))) {
        LogLine("!Freelook: PlayerTurnTilt prologue mismatch at %p; SS2:AE build changed?", tt);
        return 0;
    }

    g_configOk = ReadCodeBytesMatch(g_base + kRvaKexSetConfigRaw, kKexSetConfigRawPrologue, sizeof(kKexSetConfigRawPrologue));
    if (!g_configOk) LogLine("!Freelook: KexSetConfigRaw prologue mismatch; ss2fa_aim publish disabled");
    if (!g_configHookEnabled) {
        LogLine("!Freelook: KexSetConfigRaw hook disabled by config_hook=0; Squirrel bridge capture/publish disabled");
    } else if (g_configOk) {
        void* configSet = g_base + kRvaKexSetConfigRaw;
        if (MH_CreateHook(configSet, &Hook_KexSetConfigRaw, reinterpret_cast<void**>(&g_realKexSetConfigRaw)) != MH_OK ||
            MH_EnableHook(configSet) != MH_OK) {
            LogLine("!Freelook: failed to hook KexSetConfigRaw; semantic selection publish-back disabled");
            g_realKexSetConfigRaw = nullptr;
            g_configHookInstalled = false;
        } else {
            g_configHookInstalled = true;
            LogLine("Freelook: KexSetConfigRaw hook installed for semantic selection publish-back");
        }
    }

    if (MH_CreateHook(tt, &Hook_PlayerTurnTilt, reinterpret_cast<void**>(&g_realTurnTilt)) != MH_OK ||
        MH_EnableHook(tt) != MH_OK) {
        LogLine("!Freelook: failed to hook PlayerTurnTilt");
        return 0;
    }

    void* hover = g_base + kRvaHoverCandidate;
    const bool wantsHoverHook = g_selection || (g_nativeBracketProbe && g_nativeBracketProbeHook);
    if (!wantsHoverHook) {
        LogLine("Freelook: hover-candidate hook skipped (selection=0 nativeBracketProbe=%d hook=%d)",
            g_nativeBracketProbe ? 1 : 0,
            g_nativeBracketProbeHook ? 1 : 0);
    } else if (!ReadCodeBytesMatch(reinterpret_cast<uint8_t*>(hover), kHoverCandidatePrologue, sizeof(kHoverCandidatePrologue))) {
        LogLine("!Freelook: hover-candidate prologue mismatch at %p; native selection/probe hook disabled", hover);
    } else if (MH_CreateHook(hover, &Hook_HoverCandidate, reinterpret_cast<void**>(&g_realHoverCandidate)) != MH_OK ||
               MH_EnableHook(hover) != MH_OK) {
        LogLine("!Freelook: failed to hook hover-candidate picker; native selection/probe hook disabled");
    } else {
        LogLine("!Freelook: hover-candidate hook installed mode=%s nativeBracketProbe=%d (log-only when selection=0)",
            g_selection ? "legacy_selection" : "native_bracket_probe",
            g_nativeBracketProbe ? 1 : 0);
    }

    LogLine("!Freelook ready. toggle_vk=0x%X press=%s edge_pan=%s/0x%X fov=%.1f screen=%.0fx%.0f auto_display=%d bridge=%d semantic=%d marker=%d reach=%.1f ini=%s",
        g_toggleVk, FreelookPressTypeName(g_freelookPressType), EdgePanPressTypeName(g_edgePanPressType), g_edgePanVk,
        g_fovDeg, g_screenW, g_screenH, g_autoDisplay,
        g_configHookInstalled ? 1 : 0,
        g_selectionSemantic ? 1 : 0,
        g_selectionDebugMarker ? 1 : 0,
        g_selectionSemanticReach,
        g_iniPath);
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hModule);
        CreateThread(nullptr, 0, InitThread, nullptr, 0, nullptr);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_overlayActive.store(false, std::memory_order_release);
        if (g_overlayHwnd) {
            PostMessageW(g_overlayHwnd, WM_CLOSE, 0, 0);
        }
    }
    return TRUE;
}

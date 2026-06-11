// FreelookLoader.exe — launches SS2R (or wraps a Steam %command% line) and
// injects FlatAim.dll from the loader's own folder. Usage:
//   FreelookLoader.exe                       (launches SystemShock2Remastered.exe beside it)
//   "...\FreelookLoader.exe" %command%       (Steam Launch Options wrapper)
//
// Robustness notes (v1.0.1):
//  - Steam may relaunch the game exe via SteamAPI_RestartAppIfNecessary, which
//    spawns a NEW process and exits the one we started. Injecting into our
//    original child handle then fails ("alloc/write"). So instead of trusting
//    our child PID, we POLL BY PROCESS NAME for the real, injectable game.
//  - If the game runs elevated but the loader does not (e.g. Steam launched as
//    Administrator), OpenProcess/VirtualAllocEx return ACCESS_DENIED — we detect
//    that and tell the user to match elevation, rather than a vague failure.
//  - Everything is logged to freelookloader.log next to the loader.
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdarg.h>

#define GAME_EXE "SystemShock2Remastered.exe"

static FILE* g_log = NULL;

static void Logf(const char* fmt, ...) {
    if (!g_log) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(g_log, "[%02d:%02d:%02d] ", t.wHour, t.wMinute, t.wSecond);
    va_list a; va_start(a, fmt); vfprintf(g_log, fmt, a); va_end(a);
    fputc('\n', g_log); fflush(g_log);
}

static void Fail(const char* m) {
    Logf("FATAL: %s (GetLastError=%lu)", m, GetLastError());
    MessageBoxA(NULL, m, "Freelook Loader", MB_ICONERROR);
    ExitProcess(1);
}

// --- find SS2R process IDs ----------------------------------------------------
static int FindGamePids(DWORD* out, int max) {
    int n = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32 pe = { sizeof pe };
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, GAME_EXE) == 0 && n < max)
                out[n++] = pe.th32ProcessID;
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return n;
}

static int PidInList(DWORD pid, const DWORD* list, int n) {
    for (int i = 0; i < n; i++) if (list[i] == pid) return 1;
    return 0;
}

// --- does this PID own a visible top-level window? (game is up, not a stub) ---
typedef struct { DWORD pid; BOOL found; } WinSearch;
static BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lp) {
    WinSearch* w = (WinSearch*)lp;
    DWORD pid = 0; GetWindowThreadProcessId(hwnd, &pid);
    if (pid == w->pid && IsWindowVisible(hwnd) && GetWindow(hwnd, GW_OWNER) == NULL) {
        w->found = TRUE; return FALSE;
    }
    return TRUE;
}
static BOOL PidHasWindow(DWORD pid) {
    WinSearch w = { pid, FALSE };
    EnumWindows(EnumProc, (LPARAM)&w);
    return w.found;
}

#define INJ_ACCESS (PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | \
                    PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ)

int WINAPI WinMain(HINSTANCE h, HINSTANCE p, LPSTR cmd, int show) {
    (void)h; (void)p; (void)show;
    char dir[MAX_PATH], dll[MAX_PATH], exe[MAX_PATH], logpath[MAX_PATH];
    GetModuleFileNameA(NULL, dir, MAX_PATH);
    char* s = strrchr(dir, '\\'); if (s) *s = 0;

    _snprintf_s(logpath, MAX_PATH, _TRUNCATE, "%s\\freelookloader.log", dir);
    g_log = fopen(logpath, "w");
    Logf("FreelookLoader v1.0.1 starting; dir=%s", dir);

    _snprintf_s(dll, MAX_PATH, _TRUNCATE, "%s\\FlatAim.dll", dir);
    if (GetFileAttributesA(dll) == INVALID_FILE_ATTRIBUTES) Fail("FlatAim.dll not found next to FreelookLoader.exe");

    char cmdline[4096];
    if (cmd && cmd[0]) {
        _snprintf_s(cmdline, sizeof cmdline, _TRUNCATE, "%s", cmd);
        Logf("Steam wrapper mode; cmdline=%s", cmdline);
    } else {
        _snprintf_s(exe, MAX_PATH, _TRUNCATE, "%s\\%s", dir, GAME_EXE);
        if (GetFileAttributesA(exe) == INVALID_FILE_ATTRIBUTES) Fail("SystemShock2Remastered.exe not found; put the loader in the game folder or use Steam launch options.");
        _snprintf_s(cmdline, sizeof cmdline, _TRUNCATE, "\"%s\"", exe);
        Logf("direct-launch mode; cmdline=%s", cmdline);
    }

    // Snapshot any game instances that exist BEFORE we launch, so we can tell
    // our freshly-spawned game (incl. Steam's relaunch) from a pre-existing one.
    DWORD before[64]; int beforeN = FindGamePids(before, 64);
    Logf("pre-existing %s instances: %d", GAME_EXE, beforeN);

    STARTUPINFOA si = { sizeof si };
    PROCESS_INFORMATION pi = { 0 };
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi))
        Fail("Could not launch the game.");
    Logf("CreateProcess OK; child pid=%lu", pi.dwProcessId);

    // Poll by name for the real, injectable game process. Handles Steam's
    // restart (new PID) and the no-restart case (our child is the game).
    HANDLE target = NULL; DWORD targetPid = 0, lastErr = 0;
    const int maxTries = 120;          // 120 * 500ms = 60s budget
    for (int tries = 0; tries < maxTries && !target; tries++) {
        DWORD now[64]; int nowN = FindGamePids(now, 64);
        BOOL graceOver = (tries >= 30); // first 15s: require a window (skip the transient restart stub)
        for (int i = 0; i < nowN && !target; i++) {
            DWORD pid = now[i];
            BOOL isChild = (pid == pi.dwProcessId);
            BOOL isNew   = !PidInList(pid, before, beforeN);
            if (!isChild && !isNew) continue;             // a pre-existing instance — leave it alone
            if (!graceOver && !PidHasWindow(pid)) continue; // not ready yet / restart stub

            HANDLE hp = OpenProcess(INJ_ACCESS, FALSE, pid);
            if (!hp) { lastErr = GetLastError(); Logf("OpenProcess pid=%lu failed err=%lu", pid, lastErr); continue; }
            LPVOID probe = VirtualAllocEx(hp, NULL, 16, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (!probe) { lastErr = GetLastError(); Logf("alloc-probe pid=%lu failed err=%lu", pid, lastErr); CloseHandle(hp); continue; }
            VirtualFreeEx(hp, probe, 0, MEM_RELEASE);
            target = hp; targetPid = pid;
            Logf("selected injectable target pid=%lu (child=%d new=%d)", pid, isChild, isNew);
        }
        if (!target) Sleep(500);
    }

    if (!target) {
        if (lastErr == ERROR_ACCESS_DENIED)
            Fail("Injection failed: access denied.\n\n"
                 "This usually means the game is running elevated but the loader is not "
                 "(or the reverse) - most often because Steam was started as Administrator.\n\n"
                 "Fix: run BOTH the same way. Either launch Steam normally (not as admin), "
                 "or run FreelookLoader.exe as administrator too.");
        Fail("Injection failed: could not find the game process to inject into.\n\n"
             "If you double-clicked the .bat, Steam may have relaunched the game on its own. "
             "Use the Steam Launch Options method instead (see the README - Troubleshooting).");
    }

    // Give KEX a moment to finish loading its modules before hooking.
    WaitForInputIdle(target, 10000);
    Sleep(2000);

    SIZE_T len = strlen(dll) + 1;
    LPVOID mem = VirtualAllocEx(target, NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!mem || !WriteProcessMemory(target, mem, dll, len, NULL))
        Fail("Injection failed (alloc/write).");
    HANDLE t = CreateRemoteThread(target, NULL, 0,
        (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA"), mem, 0, NULL);
    if (!t) Fail("Injection failed (thread).");
    WaitForSingleObject(t, 10000);
    Logf("injected FlatAim.dll into pid=%lu OK", targetPid);

    CloseHandle(t); CloseHandle(target);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    if (g_log) fclose(g_log);
    return 0;
}

// FreelookLoader.exe — launches SS2R (or wraps a Steam %command% line) and
// injects FlatAim.dll from the loader's own folder. Usage:
//   FreelookLoader.exe                       (launches SystemShock2Remastered.exe beside it)
//   "...\FreelookLoader.exe" %command%       (Steam Launch Options wrapper)
#include <windows.h>
#include <stdio.h>

static void Fail(const char* m) { MessageBoxA(NULL, m, "Freelook Loader", MB_ICONERROR); ExitProcess(1); }

int WINAPI WinMain(HINSTANCE h, HINSTANCE p, LPSTR cmd, int show) {
    (void)h; (void)p; (void)show;
    char dir[MAX_PATH], dll[MAX_PATH], exe[MAX_PATH];
    GetModuleFileNameA(NULL, dir, MAX_PATH);
    char* s = strrchr(dir, '\\'); if (s) *s = 0;
    _snprintf_s(dll, MAX_PATH, _TRUNCATE, "%s\\FlatAim.dll", dir);
    if (GetFileAttributesA(dll) == INVALID_FILE_ATTRIBUTES) Fail("FlatAim.dll not found next to FreelookLoader.exe");

    char cmdline[4096];
    if (cmd && cmd[0]) {
        _snprintf_s(cmdline, sizeof cmdline, _TRUNCATE, "%s", cmd);
    } else {
        _snprintf_s(exe, MAX_PATH, _TRUNCATE, "%s\\SystemShock2Remastered.exe", dir);
        if (GetFileAttributesA(exe) == INVALID_FILE_ATTRIBUTES) Fail("SystemShock2Remastered.exe not found; put the loader in the game folder or use Steam launch options.");
        _snprintf_s(cmdline, sizeof cmdline, _TRUNCATE, "\"%s\"", exe);
    }

    STARTUPINFOA si = { sizeof si };
    PROCESS_INFORMATION pi = { 0 };
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, dir, &si, &pi))
        Fail("Could not launch the game.");

    WaitForInputIdle(pi.hProcess, 30000);
    Sleep(3000); // let KEX finish loading its modules before hooking

    SIZE_T len = strlen(dll) + 1;
    LPVOID mem = VirtualAllocEx(pi.hProcess, NULL, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!mem || !WriteProcessMemory(pi.hProcess, mem, dll, len, NULL))
        Fail("Injection failed (alloc/write).");
    HANDLE t = CreateRemoteThread(pi.hProcess, NULL, 0,
        (LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA"), mem, 0, NULL);
    if (!t) Fail("Injection failed (thread).");
    WaitForSingleObject(t, 10000);
    CloseHandle(t); CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return 0;
}

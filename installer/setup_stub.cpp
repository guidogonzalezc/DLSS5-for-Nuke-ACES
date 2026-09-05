// Self-extracting installer stub for DLSS5Live (ACES fork).
//
// The whole release package is embedded as a resource. Running the .exe unpacks
// it into a temporary directory and hands over to install.bat, so the end user
// downloads one file, double-clicks it, and is done - no ZIP to extract, no
// compiler, no CMake, no Nuke NDK.
//
// Why a hand-rolled stub rather than IExpress: IExpress ships with Windows and
// was the obvious choice, but its AppLaunched step fails with 0x80070002 on
// current Windows builds even for a minimal one-file package, so the payload
// extracts and nothing ever runs. This is ~200 lines, has no dependency beyond
// the Win32 API, and its failures are legible.
//
// Deliberately free of any dependency the user might not have: Win32 only, no
// PowerShell, no tar.exe, no shell out to unzip, and linked against the static
// CRT so there is no Visual C++ redistributable to install first.
//
// Archive format, written by tools/make_installer_exe.ps1:
//
//   "DL5A"                     magic, 4 bytes
//   uint32                     entry count
//   per entry:
//     uint32                   path length in bytes
//     char[]                   relative path, UTF-8, '/' separators
//     uint32                   payload length
//     byte[]                   file contents
//
// Stored uncompressed. The package is a few hundred KB; compression would buy
// little and add a dependency or a decompressor to get wrong.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlwapi.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "shlwapi.lib")

#define PAYLOAD_RESOURCE_ID 1

namespace {

void Fail(const char* what, DWORD err = GetLastError()) {
    std::printf("\n[ERROR] %s", what);
    if (err) {
        char* msg = nullptr;
        FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                       nullptr, err, 0, (LPSTR)&msg, 0, nullptr);
        std::printf(" (0x%08lX", err);
        if (msg) {
            std::string m(msg);
            while (!m.empty() && (m.back() == '\n' || m.back() == '\r')) m.pop_back();
            std::printf(": %s", m.c_str());
            LocalFree(msg);
        }
        std::printf(")");
    }
    std::printf("\n\nPress Enter to close.\n");
    (void)std::getchar();
}

// Create every missing directory along a path. Windows has SHCreateDirectoryEx
// for this, but it drags in shell32 and its own error semantics; walking the
// components is shorter and the failure mode is obvious.
bool EnsureDirectories(const std::string& path) {
    std::string acc;
    for (size_t i = 0; i < path.size(); ++i) {
        const char c = path[i];
        acc.push_back(c == '/' ? '\\' : c);
        if (c == '/' || c == '\\') {
            if (acc.size() > 3 && !CreateDirectoryA(acc.c_str(), nullptr)) {
                const DWORD e = GetLastError();
                if (e != ERROR_ALREADY_EXISTS) return false;
            }
        }
    }
    return true;
}

bool WriteWholeFile(const std::string& path, const unsigned char* data, DWORD size) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const BOOL ok = WriteFile(h, data, size, &written, nullptr);
    CloseHandle(h);
    return ok && written == size;
}

void RemoveTree(const std::string& dir) {
    WIN32_FIND_DATAA fd;
    const std::string pattern = dir + "\\*";
    HANDLE h = FindFirstFileA(pattern.c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        const std::string name = fd.cFileName;
        if (name == "." || name == "..") continue;
        const std::string full = dir + "\\" + name;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) RemoveTree(full);
        else DeleteFileA(full.c_str());
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    RemoveDirectoryA(dir.c_str());
}

// Read a little-endian uint32 without assuming the payload is aligned.
bool ReadU32(const unsigned char*& p, const unsigned char* end, DWORD& out) {
    if (end - p < 4) return false;
    out = (DWORD)p[0] | ((DWORD)p[1] << 8) | ((DWORD)p[2] << 16) | ((DWORD)p[3] << 24);
    p += 4;
    return true;
}

} // namespace

int main(int argc, char** argv) {
    // install.bat writes straight to the console we hand it, so anything still
    // sitting in our own buffer would surface after the child's output and read
    // as though the stub ran second. Unbuffered keeps the transcript in order.
    setvbuf(stdout, nullptr, _IONBF, 0);

    std::printf("===================================================\n");
    std::printf("  DLSS 5 for Foundry Nuke - ACES fork\n");
    std::printf("  Setup\n");
    std::printf("===================================================\n\n");

    // ---- locate the embedded package ---------------------------------------
    HRSRC res = FindResourceA(nullptr, MAKEINTRESOURCEA(PAYLOAD_RESOURCE_ID), RT_RCDATA);
    if (!res) { Fail("This installer has no embedded payload. The build is broken."); return 1; }

    HGLOBAL resData = LoadResource(nullptr, res);
    const DWORD resSize = SizeofResource(nullptr, res);
    const unsigned char* p = (const unsigned char*)LockResource(resData);
    if (!p || resSize < 8) { Fail("The embedded payload could not be read."); return 1; }
    const unsigned char* const end = p + resSize;

    if (std::memcmp(p, "DL5A", 4) != 0) { Fail("The embedded payload is corrupt (bad magic)."); return 1; }
    p += 4;

    DWORD count = 0;
    if (!ReadU32(p, end, count)) { Fail("The embedded payload is truncated."); return 1; }

    // ---- unpack ------------------------------------------------------------
    char tempRoot[MAX_PATH] = {0};
    if (!GetTempPathA(MAX_PATH, tempRoot)) { Fail("Could not locate the temp directory."); return 1; }

    char stamp[64];
    std::snprintf(stamp, sizeof(stamp), "DLSS5Live-ACES-setup-%lu", GetCurrentProcessId());
    std::string dest = std::string(tempRoot) + stamp;

    RemoveTree(dest);
    if (!CreateDirectoryA(dest.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        Fail(("Could not create " + dest).c_str());
        return 1;
    }

    std::printf("Unpacking %lu files...\n", count);

    for (DWORD i = 0; i < count; ++i) {
        DWORD pathLen = 0;
        if (!ReadU32(p, end, pathLen) || (DWORD)(end - p) < pathLen) {
            Fail("The embedded payload is truncated (file table)."); RemoveTree(dest); return 1;
        }
        std::string rel((const char*)p, pathLen);
        p += pathLen;

        DWORD dataLen = 0;
        if (!ReadU32(p, end, dataLen) || (DWORD)(end - p) < dataLen) {
            Fail("The embedded payload is truncated (file data)."); RemoveTree(dest); return 1;
        }

        // The packer only ever writes relative paths, but a stub that blindly
        // trusts its payload is a stub that writes outside its temp directory
        // the day the packer has a bug.
        if (rel.find("..") != std::string::npos || rel.find(':') != std::string::npos ||
            rel.empty() || rel[0] == '/' || rel[0] == '\\') {
            Fail(("Refusing to unpack a suspicious path: " + rel).c_str(), 0);
            RemoveTree(dest);
            return 1;
        }

        std::string full = dest + "\\" + rel;
        for (char& c : full) if (c == '/') c = '\\';

        const size_t slash = full.find_last_of('\\');
        if (slash != std::string::npos && !EnsureDirectories(full.substr(0, slash + 1))) {
            Fail(("Could not create the directory for " + rel).c_str()); RemoveTree(dest); return 1;
        }

        if (!WriteWholeFile(full, p, dataLen)) {
            Fail(("Could not write " + rel + "\n         Check that no antivirus is blocking %TEMP%.").c_str());
            RemoveTree(dest);
            return 1;
        }
        p += dataLen;
    }

    // ---- hand over to the real installer ------------------------------------
    const std::string installer = dest + "\\install.bat";
    if (GetFileAttributesA(installer.c_str()) == INVALID_FILE_ATTRIBUTES) {
        Fail("install.bat is missing from the payload. The build is broken.", 0);
        RemoveTree(dest);
        return 1;
    }

    // Forward our own arguments so "Setup.exe /uninstall" and "/y" work.
    std::string args = "\"" + installer + "\"";
    for (int i = 1; i < argc; ++i) args += std::string(" ") + argv[i];

    char comspec[MAX_PATH] = {0};
    if (!GetEnvironmentVariableA("COMSPEC", comspec, MAX_PATH)) {
        std::snprintf(comspec, sizeof(comspec), "cmd.exe");
    }
    std::string cmd = std::string("\"") + comspec + "\" /c " + args;

    std::vector<char> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back('\0');

    STARTUPINFOA si = {0};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {0};

    std::printf("\n");
    if (!CreateProcessA(nullptr, cmdBuf.data(), nullptr, nullptr, TRUE,
                        0, nullptr, dest.c_str(), &si, &pi)) {
        Fail("Could not start install.bat.");
        RemoveTree(dest);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD rc = 1;
    GetExitCodeProcess(pi.hProcess, &rc);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    RemoveTree(dest);
    return (int)rc;
}

#define main original_demo_main
#include "../../RustDeskTempTopMostWindow/WindowInjection/dllmain.cpp"
#undef main

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#pragma comment(lib, "dwmapi.lib")
extern "C" HRESULT WINAPI DwmFlush();

constexpr COLORREF desktopColor = RGB(15, 82, 140);
constexpr COLORREF imageColor = RGB(218, 50, 19);

void Require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

void WriteImage(const std::filesystem::path& file)
{
    // The Flutter test also checks the top-down, 32-bit BMP emitted by the app.
    BITMAPFILEHEADER fileHeader = {};
    fileHeader.bfType = 0x4d42;
    fileHeader.bfOffBits = sizeof(fileHeader) + sizeof(BITMAPINFOHEADER);
    fileHeader.bfSize = fileHeader.bfOffBits + 2 * sizeof(DWORD);
    BITMAPINFOHEADER header = {};
    header.biSize = sizeof(header);
    header.biWidth = 2;
    header.biHeight = -1;
    header.biPlanes = 1;
    header.biBitCount = 32;
    const DWORD pixels[] = { 0xda3213, 0xda3213 };
    std::ofstream stream(file, std::ios::binary);
    stream.write(reinterpret_cast<const char*>(&fileHeader), sizeof(fileHeader));
    stream.write(reinterpret_cast<const char*>(&header), sizeof(header));
    stream.write(reinterpret_cast<const char*>(pixels), sizeof(pixels));
    Require(stream.good(), "failed to write the test image");
}

COLORREF Sample(HWND overlay, bool paint, int x, int y)
{
    HDC screen = GetDC(nullptr);
    HDC buffer = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateCompatibleBitmap(screen, 120, 80);
    HGDIOBJ previous = SelectObject(buffer, bitmap);
    if (paint)
    {
        PaintPrivacyMask(overlay, buffer);
    }
    else
    {
        Require(BitBlt(buffer, 0, 0, 1, 1, screen, x, y, SRCCOPY | CAPTUREBLT) != 0,
            "could not capture the test window");
        x = y = 0;
    }
    const COLORREF pixel = GetPixel(buffer, x, y);
    SelectObject(buffer, previous);
    DeleteObject(bitmap);
    DeleteDC(buffer);
    ReleaseDC(nullptr, screen);
    return pixel;
}

void CheckFrame(HWND overlay, const RECT& rect, COLORREF color)
{
    SetPrivacyWindowsVisible(true);
    RedrawWindow(overlay, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
    Require(SUCCEEDED(DwmFlush()), "DWM did not flush the test frame");
    Require(Sample(overlay, true, 60, 40) == color, "unexpected mask center color");
    Require(Sample(overlay, true, 60, 2) == RGB(0, 0, 0), "mask background is not black");

    const int x = rect.left + 60;
    const int y = rect.top + 40;
    DWORD affinity = 0;
    Require(GetWindowDisplayAffinity(overlay, &affinity) && affinity == WDA_EXCLUDEFROMCAPTURE,
        "overlay was not marked to exclude from capture");
    Require(Sample(overlay, false, x, y) == desktopColor, "capture contained the privacy mask");
    Require(SetWindowDisplayAffinity(overlay, WDA_NONE), "could not calibrate the capture");
    Require(SUCCEEDED(DwmFlush()), "DWM did not flush the calibration frame");
    Require(Sample(overlay, false, x, y) == color, "capture calibration did not see the visible overlay");
    Require(SetWindowDisplayAffinity(overlay, WDA_EXCLUDEFROMCAPTURE), "could not restore affinity");
    SetPrivacyWindowsVisible(false);
}

int main()
{
    try
    {
        PWSTR local = nullptr;
        Require(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local)),
            "could not find the test account folder");
        const auto file = std::filesystem::path(local) / L"RustDesk" / L"privacy-mode-1-mask.bmp";
        CoTaskMemFree(local);
        Require(!std::filesystem::exists(file), "test requires a disposable profile");
        std::filesystem::create_directories(file.parent_path());

        const HMODULE module = GetModuleHandleW(nullptr);
        const HBRUSH brush = CreateSolidBrush(desktopColor);
        WNDCLASSW background = {};
        background.lpfnWndProc = DefWindowProcW;
        background.hInstance = module;
        background.hbrBackground = brush;
        background.lpszClassName = L"PrivacyMaskTestBackground";
        Require(RegisterClassW(&background) != 0, "could not register the test background");

        const RECT rect = { 64, 64, 184, 144 };
        const HWND desktop = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            background.lpszClassName, L"Input to privacy capture", WS_POPUP,
            rect.left, rect.top, 120, 80, nullptr, nullptr, module, nullptr);
        Require(desktop != nullptr, "could not create the test background");
        ShowWindow(desktop, SW_SHOWNA);
        UpdateWindow(desktop);
        const HWND overlay = CreateWin(module, ZBID_DESKTOP, WindowTitle, ClassName, rect);
        Require(overlay != nullptr, "could not create the privacy overlay");
        g_hwnds.push_back(overlay);
        CheckFrame(overlay, rect, RGB(0, 0, 0));
        std::puts("Default mask is black and excluded from capture");
        WriteImage(file);
        CheckFrame(overlay, rect, imageColor);
        std::puts("Selected image renders in the overlay and is excluded from capture");
        Require(std::filesystem::remove(file), "could not reset the mask");
        CheckFrame(overlay, rect, RGB(0, 0, 0));
        std::puts("Restoring the default returns to black and retains capture exclusion");

        DestroyPrivacyWindowsFrom(0);
        DestroyWindow(desktop);
        DeleteObject(brush);
        return 0;
    }
    catch (const std::exception& error)
    {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}

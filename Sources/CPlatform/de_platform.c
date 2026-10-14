#include "de_platform.h"

#include <stdlib.h>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#endif

#if defined(_WIN32)
/* UTF-8 to a malloc'd UTF-16 string, or NULL. */
static wchar_t* de_widen(const char* text)
{
    int count;
    wchar_t* wide;
    if (text == NULL) {
        return NULL;
    }
    count = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (count <= 0) {
        return NULL;
    }
    wide = (wchar_t*)malloc((size_t)count * sizeof(wchar_t));
    if (wide == NULL) {
        return NULL;
    }
    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, count) <= 0) {
        free(wide);
        return NULL;
    }
    return wide;
}
#endif

/* ---- Single instance ----------------------------------------------------- */

int de_instance_lock(const char* name, const char* lockPath, void** token)
{
    *token = NULL;
#if defined(_WIN32)
    {
        wchar_t* wideName = de_widen(name);
        HANDLE mutex;
        DWORD error;
        (void)lockPath;
        if (wideName == NULL) {
            return DE_INSTANCE_UNAVAILABLE;
        }
        mutex = CreateMutexW(NULL, FALSE, wideName);
        error = GetLastError();
        free(wideName);
        if (mutex == NULL) {
            return DE_INSTANCE_UNAVAILABLE;
        }
        if (error == ERROR_ALREADY_EXISTS) {
            CloseHandle(mutex);
            return DE_INSTANCE_TAKEN;
        }
        *token = (void*)mutex;
        return DE_INSTANCE_ACQUIRED;
    }
#else
    {
        int fd;
        int* stored;
        (void)name;
        fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fd < 0) {
            return DE_INSTANCE_UNAVAILABLE;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            int taken = (errno == EWOULDBLOCK);
            close(fd);
            return taken ? DE_INSTANCE_TAKEN : DE_INSTANCE_UNAVAILABLE;
        }
        stored = (int*)malloc(sizeof(int));
        if (stored == NULL) {
            close(fd);
            return DE_INSTANCE_UNAVAILABLE;
        }
        *stored = fd;
        *token = stored;
        return DE_INSTANCE_ACQUIRED;
    }
#endif
}

void de_instance_unlock(void* token)
{
    if (token == NULL) {
        return;
    }
#if defined(_WIN32)
    CloseHandle((HANDLE)token);
#else
    /* Closing the descriptor releases the flock. */
    close(*(int*)token);
    free(token);
#endif
}

/* ---- Windows only -------------------------------------------------------- */

int de_show_error_box(const char* title, const char* message)
{
#if defined(_WIN32)
    wchar_t* wideTitle = de_widen(title);
    wchar_t* wideMessage = de_widen(message);
    int shown = 0;
    if (wideTitle != NULL && wideMessage != NULL) {
        shown = MessageBoxW(NULL, wideMessage, wideTitle, MB_OK | MB_ICONERROR | MB_SETFOREGROUND) != 0;
    }
    free(wideTitle);
    free(wideMessage);
    return shown;
#else
    (void)title;
    (void)message;
    return 0;
#endif
}

int de_activate_window(const char* windowClass, const char* title)
{
#if defined(_WIN32)
    wchar_t* wideClass = de_widen(windowClass);
    wchar_t* wideTitle = de_widen(title);
    HWND window = NULL;
    if (wideClass != NULL && wideTitle != NULL) {
        window = FindWindowW(wideClass, wideTitle);
    }
    free(wideClass);
    free(wideTitle);
    if (window == NULL) {
        return 0;
    }
    if (IsIconic(window)) {
        ShowWindow(window, SW_RESTORE);
    }
    /* Allowed: the user just launched this process, so it may take the
       foreground and hand it on. */
    SetForegroundWindow(window);
    return 1;
#else
    (void)windowClass;
    (void)title;
    return 0;
#endif
}

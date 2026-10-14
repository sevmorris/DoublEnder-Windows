/*
 * Child processes on pipes, for ffmpeg. See de_platform.h.
 *
 * Foundation's Process would do on Linux, but on Windows it starts a console
 * program from a windowed app with a console window of its own (it passes
 * CreateProcessW no CREATE_NO_WINDOW), and an encoder that runs for a whole
 * take would sit there in a black window for the whole call. One small
 * launcher on both platforms keeps the two paths the same.
 */
#if defined(_WIN32) && !defined(_WIN32_WINNT)
#define _WIN32_WINNT 0x0601  /* PROC_THREAD_ATTRIBUTE_HANDLE_LIST: Windows 7 on */
#endif

#include "de_platform.h"

#include <stdlib.h>
#include <string.h>

/* ---- The Windows command line, built anywhere ---------------------------- */

/* Appends `c` at out[*length] when out is non-NULL; counts it either way. */
static void de_put(char* out, size_t* length, char c)
{
    if (out != NULL) {
        out[*length] = c;
    }
    *length += 1;
}

/* The C runtime's rules: an argument with a space, tab, newline, vertical tab
   or quote (or none at all) is quoted; inside quotes a run of backslashes is
   doubled before a quote or the closing quote, and a quote is escaped;
   anywhere else a backslash stands for itself. */
static size_t de_command_line(const char* const* argv, int argc, char* out)
{
    size_t length = 0;
    int i;
    for (i = 0; i < argc; i += 1) {
        const char* arg = argv[i];
        const char* p;
        if (i > 0) {
            de_put(out, &length, ' ');
        }
        if (arg[0] != '\0' && strpbrk(arg, " \t\n\v\"") == NULL) {
            for (p = arg; *p != '\0'; p += 1) {
                de_put(out, &length, *p);
            }
            continue;
        }
        de_put(out, &length, '"');
        for (p = arg; ; p += 1) {
            size_t backslashes = 0;
            size_t k;
            while (*p == '\\') {
                backslashes += 1;
                p += 1;
            }
            if (*p == '\0') {
                for (k = 0; k < backslashes * 2; k += 1) de_put(out, &length, '\\');
                break;
            }
            if (*p == '"') {
                for (k = 0; k < backslashes * 2 + 1; k += 1) de_put(out, &length, '\\');
            } else {
                for (k = 0; k < backslashes; k += 1) de_put(out, &length, '\\');
            }
            de_put(out, &length, *p);
        }
        de_put(out, &length, '"');
    }
    return length;
}

size_t de_windows_command_line(const char* const* argv, int argc, char* out, size_t capacity)
{
    size_t length = de_command_line(argv, argc, NULL);
    if (out != NULL && capacity > length) {
        de_command_line(argv, argc, out);
        out[length] = '\0';
    }
    return length;
}

#if !defined(_WIN32)

/* ---- POSIX ---------------------------------------------------------------- */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define de_environ (*_NSGetEnviron())
#else
extern char** environ;
#define de_environ environ
#endif

struct de_child {
    pid_t pid;
    int input;
    int output;
    int error;
    /* Set once the pid is reaped, under `lock`, which de_child_kill takes
       too: a reaped pid can be handed to another process, which a late
       kill must never reach. */
    pthread_mutex_t lock;
    int reaped;
};

static int de_pipe(int fds[2])
{
    if (pipe(fds) != 0) {
        fds[0] = fds[1] = -1;
        return -1;
    }
    /* Ours only: dup2 onto 0, 1 and 2 gives the child its ends. */
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
}

static void de_close(int* fd)
{
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

de_child* de_child_start(const char* const* argv, int argc)
{
    int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    char** args = NULL;
    de_child* child = NULL;
    pid_t pid;
    int spawned;
    int i;

    if (argc < 1) {
        return NULL;
    }
    /* A write to a child that has exited would raise SIGPIPE and end this
       process; ignored, the write fails with EPIPE and de_child_write says so. */
    signal(SIGPIPE, SIG_IGN);

    if (de_pipe(in) != 0 || de_pipe(out) != 0 || de_pipe(err) != 0) goto fail;
    args = (char**)calloc((size_t)argc + 1, sizeof(char*));
    child = (de_child*)calloc(1, sizeof(*child));
    if (args == NULL || child == NULL) goto fail;
    for (i = 0; i < argc; i += 1) {
        args[i] = (char*)argv[i];
    }
    if (posix_spawn_file_actions_init(&actions) != 0) goto fail;
    posix_spawn_file_actions_adddup2(&actions, in[0], 0);
    posix_spawn_file_actions_adddup2(&actions, out[1], 1);
    posix_spawn_file_actions_adddup2(&actions, err[1], 2);
    spawned = posix_spawn(&pid, argv[0], &actions, NULL, args, de_environ);
    posix_spawn_file_actions_destroy(&actions);
    if (spawned != 0) goto fail;

    pthread_mutex_init(&child->lock, NULL);
    child->pid = pid;
    child->input = in[1];
    child->output = out[0];
    child->error = err[0];
    de_close(&in[0]);
    de_close(&out[1]);
    de_close(&err[1]);
    free(args);
    return child;

fail:
    de_close(&in[0]); de_close(&in[1]);
    de_close(&out[0]); de_close(&out[1]);
    de_close(&err[0]); de_close(&err[1]);
    free(args);
    free(child);
    return NULL;
}

int de_child_write(de_child* child, const void* data, size_t size)
{
    const char* p = (const char*)data;
    if (child->input < 0) {
        return -1;
    }
    while (size > 0) {
        ssize_t written = write(child->input, p, size);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += written;
        size -= (size_t)written;
    }
    return 0;
}

void de_child_close_input(de_child* child)
{
    de_close(&child->input);
}

long de_child_read(de_child* child, int which, void* buffer, size_t capacity)
{
    int fd = (which == DE_CHILD_STDOUT) ? child->output : child->error;
    if (fd < 0) {
        return 0;
    }
    for (;;) {
        ssize_t got = read(fd, buffer, capacity);
        if (got < 0 && errno == EINTR) continue;
        return (long)got;
    }
}

int de_child_wait(de_child* child)
{
    siginfo_t info;
    int status = 0;
    int ready;
    pid_t reaped;

    /* Waits for the exit without reaping, then reaps under the lock. */
    memset(&info, 0, sizeof(info));
    do {
        ready = waitid(P_PID, (id_t)child->pid, &info, WEXITED | WNOWAIT);
    } while (ready != 0 && errno == EINTR);
    pthread_mutex_lock(&child->lock);
    do {
        reaped = waitpid(child->pid, &status, WNOHANG);
    } while (reaped < 0 && errno == EINTR);
    if (reaped == 0) {
        /* waitid failed and the child is still running: wait unlocked, so
           a kill can still end it. */
        pthread_mutex_unlock(&child->lock);
        do {
            reaped = waitpid(child->pid, &status, 0);
        } while (reaped < 0 && errno == EINTR);
        pthread_mutex_lock(&child->lock);
    }
    child->reaped = 1;
    pthread_mutex_unlock(&child->lock);
    if (reaped < 0) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

void de_child_kill(de_child* child)
{
    pthread_mutex_lock(&child->lock);
    if (!child->reaped) {
        kill(child->pid, SIGKILL);
    }
    pthread_mutex_unlock(&child->lock);
}

void de_child_free(de_child* child)
{
    if (child == NULL) {
        return;
    }
    de_close(&child->input);
    de_close(&child->output);
    de_close(&child->error);
    pthread_mutex_destroy(&child->lock);
    free(child);
}

#else

/* ---- Windows -------------------------------------------------------------- */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

struct de_child {
    HANDLE process;
    HANDLE input;
    HANDLE output;
    HANDLE error;
};

/* UTF-8 to a malloc'd UTF-16 string, or NULL. */
static wchar_t* de_child_widen(const char* text)
{
    int count = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    wchar_t* wide;
    if (count <= 0) {
        return NULL;
    }
    wide = (wchar_t*)malloc((size_t)count * sizeof(wchar_t));
    if (wide != NULL && MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, count) <= 0) {
        free(wide);
        wide = NULL;
    }
    return wide;
}

static void de_close_handle(HANDLE* handle)
{
    if (*handle != NULL) {
        CloseHandle(*handle);
        *handle = NULL;
    }
}

de_child* de_child_start(const char* const* argv, int argc)
{
    SECURITY_ATTRIBUTES inheritable;
    HANDLE inRead = NULL, inWrite = NULL;
    HANDLE outRead = NULL, outWrite = NULL;
    HANDLE errRead = NULL, errWrite = NULL;
    HANDLE inherited[3];
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    SIZE_T attributesSize = 0;
    BOOL attributesReady = FALSE;
    STARTUPINFOEXW startup;
    PROCESS_INFORMATION info;
    char* narrow = NULL;
    wchar_t* application = NULL;
    wchar_t* commandLine = NULL;
    size_t length;
    de_child* child = NULL;

    if (argc < 1) {
        return NULL;
    }

    /* The child's ends are inheritable and ours aren't. A large stdin buffer
       keeps a briefly busy encoder from holding up the writer. */
    inheritable.nLength = sizeof(inheritable);
    inheritable.lpSecurityDescriptor = NULL;
    inheritable.bInheritHandle = TRUE;
    if (!CreatePipe(&inRead, &inWrite, &inheritable, 1 << 20)
        || !CreatePipe(&outRead, &outWrite, &inheritable, 0)
        || !CreatePipe(&errRead, &errWrite, &inheritable, 0)) {
        goto done;
    }
    SetHandleInformation(inWrite, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(errRead, HANDLE_FLAG_INHERIT, 0);

    length = de_windows_command_line(argv, argc, NULL, 0);
    narrow = (char*)malloc(length + 1);
    if (narrow == NULL) goto done;
    de_windows_command_line(argv, argc, narrow, length + 1);
    commandLine = de_child_widen(narrow);
    application = de_child_widen(argv[0]);
    if (commandLine == NULL || application == NULL) goto done;

    /* Only the three pipe ends are inherited, not every inheritable handle
       the app happens to hold: another child's pipe end kept open in this
       one would hold that pipe open after its own child had exited. */
    InitializeProcThreadAttributeList(NULL, 1, 0, &attributesSize);
    attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attributesSize);
    if (attributes == NULL || !InitializeProcThreadAttributeList(attributes, 1, 0, &attributesSize)) goto done;
    attributesReady = TRUE;
    inherited[0] = inRead;
    inherited[1] = outWrite;
    inherited[2] = errWrite;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherited, sizeof(inherited), NULL, NULL)) goto done;

    ZeroMemory(&startup, sizeof(startup));
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = inRead;
    startup.StartupInfo.hStdOutput = outWrite;
    startup.StartupInfo.hStdError = errWrite;
    startup.lpAttributeList = attributes;
    ZeroMemory(&info, sizeof(info));
    if (!CreateProcessW(application, commandLine, NULL, NULL, TRUE,
                        CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                        NULL, NULL, &startup.StartupInfo, &info)) {
        goto done;
    }
    CloseHandle(info.hThread);
    child = (de_child*)calloc(1, sizeof(*child));
    if (child == NULL) {
        TerminateProcess(info.hProcess, 1);
        CloseHandle(info.hProcess);
        goto done;
    }
    child->process = info.hProcess;
    child->input = inWrite;
    child->output = outRead;
    child->error = errRead;
    inWrite = outRead = errRead = NULL;

done:
    if (attributesReady) DeleteProcThreadAttributeList(attributes);
    if (attributes != NULL) HeapFree(GetProcessHeap(), 0, attributes);
    free(narrow);
    free(commandLine);
    free(application);
    /* The child's ends are its own now; ours live on only in `child`. */
    de_close_handle(&inRead);
    de_close_handle(&outWrite);
    de_close_handle(&errWrite);
    de_close_handle(&inWrite);
    de_close_handle(&outRead);
    de_close_handle(&errRead);
    return child;
}

int de_child_write(de_child* child, const void* data, size_t size)
{
    const char* p = (const char*)data;
    if (child->input == NULL) {
        return -1;
    }
    while (size > 0) {
        DWORD chunk = size > 0x40000000 ? 0x40000000 : (DWORD)size;
        DWORD written = 0;
        if (!WriteFile(child->input, p, chunk, &written, NULL)) {
            return -1;
        }
        p += written;
        size -= written;
    }
    return 0;
}

void de_child_close_input(de_child* child)
{
    de_close_handle(&child->input);
}

long de_child_read(de_child* child, int which, void* buffer, size_t capacity)
{
    HANDLE pipe = (which == DE_CHILD_STDOUT) ? child->output : child->error;
    DWORD got = 0;
    if (pipe == NULL) {
        return 0;
    }
    if (capacity > 0x40000000) {
        capacity = 0x40000000;
    }
    if (!ReadFile(pipe, buffer, (DWORD)capacity, &got, NULL)) {
        /* A closed write end is end of file on an anonymous pipe. */
        return GetLastError() == ERROR_BROKEN_PIPE ? 0 : -1;
    }
    return (long)got;
}

int de_child_wait(de_child* child)
{
    DWORD code = 0;
    if (WaitForSingleObject(child->process, INFINITE) != WAIT_OBJECT_0
        || !GetExitCodeProcess(child->process, &code)) {
        return -1;
    }
    return (int)code;
}

void de_child_kill(de_child* child)
{
    TerminateProcess(child->process, 1);
}

void de_child_free(de_child* child)
{
    if (child == NULL) {
        return;
    }
    de_close_handle(&child->input);
    de_close_handle(&child->output);
    de_close_handle(&child->error);
    de_close_handle(&child->process);
    free(child);
}

#endif

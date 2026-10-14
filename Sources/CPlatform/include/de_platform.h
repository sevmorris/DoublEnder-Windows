/*
 * The few OS calls Swift can't make the same way on Linux and Windows: the
 * single-instance lock, a native error box for when the app has no window,
 * bringing an already-running copy's window forward, and starting a child
 * process on pipes without a console window.
 */
#ifndef DE_PLATFORM_H
#define DE_PLATFORM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DE_INSTANCE_ACQUIRED    0
#define DE_INSTANCE_TAKEN       1
#define DE_INSTANCE_UNAVAILABLE 2

/* Takes the app-wide lock: a named mutex `name` on Windows, an flock on
   `lockPath` elsewhere. Returns DE_INSTANCE_ACQUIRED and sets `*token`, which
   holds the lock until de_instance_unlock or the process ends (a crash
   releases it too); DE_INSTANCE_TAKEN when another process holds it; or
   DE_INSTANCE_UNAVAILABLE when it couldn't be checked. The lock file is
   opened close-on-exec, so a process that re-execs itself doesn't lock
   itself out. */
int de_instance_lock(const char* name, const char* lockPath, void** token);
void de_instance_unlock(void* token);

/* A modal error box (Windows). Returns 0 where there is none. */
int de_show_error_box(const char* title, const char* message);

/* Restores and focuses the top-level window with this class and title
   (Windows). Returns 1 if one was found, 0 otherwise or elsewhere. */
int de_activate_window(const char* windowClass, const char* title);

/* ---- Child processes (de_child.c) ---------------------------------------- */

/* A child process whose stdin, stdout and stderr are pipes to this one. On
   Windows it gets no console window: Foundation's Process starts a console
   program such as ffmpeg.exe from a windowed app with a console window of
   its own, which stays open for as long as the child runs. */
typedef struct de_child de_child;

#define DE_CHILD_STDOUT 1
#define DE_CHILD_STDERR 2

/* Starts argv[0], a full path, with argv[0..argc-1] (UTF-8). NULL on failure.
   On Windows the child inherits only its three pipes. */
de_child* de_child_start(const char* const* argv, int argc);

/* Writes all of `data` to the child's stdin. Returns 0, or -1 once the child
   has stopped reading. Never raises SIGPIPE. One writing thread at a time. */
int de_child_write(de_child* child, const void* data, size_t size);

/* Closes the child's stdin, so it reads end of file. Safe to repeat. Not
   while another thread is in de_child_write. */
void de_child_close_input(de_child* child);

/* Reads from the child's stdout or stderr (DE_CHILD_STDOUT / _STDERR),
   blocking: bytes read, 0 at end of file, -1 on error. One reader per pipe. */
long de_child_read(de_child* child, int which, void* buffer, size_t capacity);

/* Waits for the child to exit: its exit status, or -1 if a signal ended it
   (on Windows, de_child_kill makes it exit 1). Call once. */
int de_child_wait(de_child* child);

/* Ends the child at once; de_child_wait still reaps it. Safe from any
   thread, including while another is in de_child_wait, and does nothing once
   the child is reaped, so it can never reach a process that reused its pid. */
void de_child_kill(de_child* child);

/* Closes what is still open and frees `child`. After de_child_wait, and
   once no thread is reading or writing. */
void de_child_free(de_child* child);

/* The Windows command line for argv, quoted the way the C runtime and
   CommandLineToArgvW split it back into the same arguments. Writes it to
   `out` with a terminating NUL when it fits (capacity > length) and returns
   its length; otherwise writes nothing and returns the length needed. Plain
   string work on every platform, so it can be tested anywhere. */
size_t de_windows_command_line(const char* const* argv, int argc, char* out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* DE_PLATFORM_H */

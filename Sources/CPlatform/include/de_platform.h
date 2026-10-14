/*
 * The few OS calls Swift can't make the same way on Linux and Windows: the
 * single-instance lock, a native error box for when the app has no window,
 * and bringing an already-running copy's window forward.
 */
#ifndef DE_PLATFORM_H
#define DE_PLATFORM_H

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

#ifdef __cplusplus
}
#endif

#endif /* DE_PLATFORM_H */

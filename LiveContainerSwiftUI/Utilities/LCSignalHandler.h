//
//  LCSignalHandler.h
//  LiveContainer
//
//  P1-15: BSD signal handler that captures native crashes (SIGSEGV,
//  SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP) and dumps a report to
//  the app-group NSUserDefaults under the LCGuestCrashReport key.
//  The signal handler itself is async-signal-safe (no malloc, no
//  NSLog, no NSString) — it just writes to static variables. The
//  actual JSON dump happens from the next main-loop tick, which is
//  safe to call malloc/NSString on.
//

#ifndef LCSignalHandler_h
#define LCSignalHandler_h

#include <signal.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Install the BSD signal handlers. Idempotent — calling more than
/// once is a no-op.
void LCSignalHandlerInstall(void);

/// True if a signal has been captured since the last call to
/// LCSignalHandlerDumpAndClearReport. Must be checked on the main
/// thread (e.g. from a DispatchSourceTimer tick or runloop observer).
bool LCSignalHandlerHasPendingReport(void);

/// If a signal was captured, format a JSON report and write it to
/// the app-group UserDefaults under LCGuestCrashReport. Returns true
/// if a report was written. Safe to call from the main thread only.
bool LCSignalHandlerDumpAndClearReport(void);

#ifdef __cplusplus
}
#endif

#endif /* LCSignalHandler_h */

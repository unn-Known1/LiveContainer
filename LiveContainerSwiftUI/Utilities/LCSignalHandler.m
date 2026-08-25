//
//  LCSignalHandler.m
//  LiveContainer
//
//  P1-15: see header. The signal handler is async-signal-safe.
//

#import "LCSignalHandler.h"
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <execinfo.h>

// Async-signal-safe flag and metadata. Touched only by the signal
// handler and the main-thread dumper. We do NOT use a mutex because
// pthread_mutex_lock is not async-signal-safe in all implementations
// and signal handlers must keep their work to a strict minimum.
static volatile sig_atomic_t g_pendingSignal = 0;
static volatile sig_atomic_t g_pendingThread = 0;
static volatile void *g_pendingFaultAddress = NULL;
static volatile pid_t g_pendingPid = 0;

static bool g_installed = false;

static const char *LCSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        default:      return "UNKNOWN";
    }
}

static void LCSignalHandlerImpl(int sig, siginfo_t *info, void *ucontext) {
    // Async-signal-safe only. No malloc, no NSLog, no Objective-C
    // messaging that might allocate or take locks.
    g_pendingSignal = (sig_atomic_t)sig;
    g_pendingPid = getpid();
#if defined(__linux__)
    g_pendingThread = (sig_atomic_t)pthread_self();
#else
    g_pendingThread = (sig_atomic_t)pthread_mach_thread_np(pthread_self());
#endif
    g_pendingFaultAddress = info ? info->si_addr : NULL;
    // Re-raise with the default disposition so the process still
    // crashes. This way we don't mask the bug, we just got a chance
    // to record it for the next launch.
    signal(sig, SIG_DFL);
    raise(sig);
}

// These two functions are called from the host binary
// (LiveContainer/main.c) which links LiveContainerSwiftUI as
// a framework. iOS frameworks compile with -fvisibility=hidden
// by default, so non-static C symbols aren't exported. Mark
// these explicitly as default-visible so the host's link step
// can find them.
__attribute__((visibility("default")))
void LCSignalHandlerInstall(void) {
    if (g_installed) return;
    g_installed = true;

    struct sigaction sa = {0};
    sa.sa_sigaction = LCSignalHandlerImpl;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;

    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGFPE,  &sa, NULL);
    sigaction(SIGILL,  &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}

__attribute__((visibility("default")))
bool LCSignalHandlerHasPendingReport(void) {
    return g_pendingSignal != 0;
}

__attribute__((visibility("default")))
bool LCSignalHandlerDumpAndClearReport(void) {
    if (g_pendingSignal == 0) return false;

    int sig = (int)g_pendingSignal;
    pid_t pid = g_pendingPid;
    void *addr = (void *)g_pendingFaultAddress;
    long thread = (long)g_pendingThread;

    // Build the report. NSString + JSONSerialization is NOT
    // async-signal-safe, but we are on the main thread now (the
    // caller is the dump-tick on the main runloop), so it's fine.
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    report[@"signal"] = @(sig);
    report[@"signalName"] = [NSString stringWithUTF8String:LCSignalName(sig)];
    report[@"pid"] = @(pid);
    report[@"thread"] = @(thread);
    report[@"faultAddress"] = [NSString stringWithFormat:@"%p", addr];
    report[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);

    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                   options:0
                                                     error:&err];
    if (json) {
        NSString *jsonStr = [[NSString alloc] initWithData:json
                                                  encoding:NSUTF8StringEncoding];
        NSString *appGroup = [[NSUserDefaults standardUserDefaults] stringForKey:@"LCAppGroupID"];
        if (appGroup.length == 0) {
            // Best effort: fall back to a suiteName guess
            appGroup = @"group.com.kdt.livecontainer";
        }
        NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:appGroup];
        if (group) {
            [group setObject:jsonStr forKey:@"LCGuestCrashReport"];
        }
    }

    g_pendingSignal = 0;
    g_pendingThread = 0;
    g_pendingFaultAddress = NULL;
    g_pendingPid = 0;
    return true;
}

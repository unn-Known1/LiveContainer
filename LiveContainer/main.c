#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "LCSignalHandler.h"

void* lcShared = 0;

// P2-18 (build fix): forward declaration for the C-linkage entry
// point in LCIncrementalSigningCache.m. Calling this here means
// the host target registers the signing cache eagerly at
// process start.
extern void LCIncrementalSigningCache_register(void);

int LiveContainerMainC(int argc, char *argv[]) {
    // P1-15: install BSD signal handlers so native crashes (SIGSEGV,
    // SIGABRT, etc.) surface as a JSON report on the next launch.
    LCSignalHandlerInstall();
    // P2-18: register the incremental signing cache. Lazy init
    // would also work, but explicit registration at process
    // start avoids a one-launch delay on the first sign.
    LCIncrementalSigningCache_register();
    const char *home = getenv("HOME");

    int (*lcMain)(int argc, char *argv[]) = 0;
    
    if (!home) {
        abort();
    }
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library/preloadLibraries.txt", home);
    FILE *file = fopen(path, "r");
    if (!file) {
        goto loadlc;
    }
    char line[PATH_MAX];
    while (fgets(line, sizeof(line), file)) {
        // Remove trailing newline if present
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') {
            line[len - 1] = '\0';
        }
        dlopen(line, RTLD_LAZY|RTLD_GLOBAL);
    }
    
    fclose(file);
    remove(path);
    
loadlc:
    lcShared = dlopen("@executable_path/Frameworks/LiveContainerShared.framework/LiveContainerShared", RTLD_LAZY|RTLD_GLOBAL);
    lcMain = dlsym(lcShared, "LiveContainerMain");
    __attribute__((musttail)) return lcMain(argc, argv);
}

#ifdef DEBUG
int main(int argc, char *argv[]) {

    if(lcShared == NULL) {
        __attribute__((musttail)) return LiveContainerMainC(argc, argv);
    }
    int (*callAppMain)(int argc, char *argv[]) = dlsym(lcShared, "callAppMain");
    __attribute__((musttail)) return callAppMain(argc, argv);

}
#endif

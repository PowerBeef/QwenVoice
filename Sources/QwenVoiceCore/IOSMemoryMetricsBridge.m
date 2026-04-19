#import "IOSMemoryMetricsBridge.h"

#include <TargetConditionals.h>
#include <os/proc.h>

bool QVoiceGetOSProcAvailableMemory(uint64_t * _Nullable outBytes) {
    if (outBytes == NULL) {
        return false;
    }

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
    *outBytes = os_proc_available_memory();
    return true;
#else
    *outBytes = 0;
    return false;
#endif
}

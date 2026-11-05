// Placeholder; replaced by the driver build. Factory symbol named in Driver/Info.plist.
#include <CoreAudio/AudioServerPlugIn.h>
void *EQTargets_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
__attribute__((visibility("default")))
void *EQTargets_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) { (void)allocator; (void)requestedTypeUUID; return NULL; }

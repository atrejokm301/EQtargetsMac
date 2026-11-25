#include "EQTRingProtocol.h"
#include "EQTIdentity.h"
#include "EQTLink.h"
#import "EQTDeviceDriver.h"
#import <CoreAudio/AudioServerPlugIn.h>

/// The plug-in the driver passed to the (stubbed) registration call.
AudioServerPlugInDriverRef _Nullable EQTTestCapturedDriver(void);
int EQTTestRegistrationCount(void);
/// Pretends this many pushes are stuck on the IO thread.
void EQTTestSetPushesInFlight(uint32_t count);
/// Runs on the sender thread when the pump has just found nothing left to send.
void EQTTestSetPumpDrainedHook(void (*_Nullable hook)(EQTLinkSender *_Nonnull));
void EQTTestSetAcceptError(int error);
uint64_t EQTTestAcceptCalls(void);
/// 0 = device UUID, 1 = route name, 2 = protocol id.
const char *_Nonnull EQTTestString(int which);

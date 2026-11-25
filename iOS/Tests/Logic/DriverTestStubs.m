//
//  DriverTestStubs.m
//  EQtargets (iOS)
//
//  Replaces the system's registration call for the test bundle only, so the REAL
//  driver can be driven through its plug-in interface without an audio server.
//

#import <CoreAudio/AudioServerPlugIn.h>
#import "EQTIdentity.h"

static AudioServerPlugInDriverRef gCaptured = NULL;
static int gRegistrations = 0;

OSStatus AudioServerPlugInRegisterMediaDeviceExtension(AudioServerPlugInDriverRef inPlugIn,
                                                       void (^interruptionHandler)(void)) {
    (void)interruptionHandler;
    gCaptured = inPlugIn;
    gRegistrations += 1;
    return noErr;
}

AudioServerPlugInDriverRef EQTTestCapturedDriver(void) { return gCaptured; }
int EQTTestRegistrationCount(void) { return gRegistrations; }

const char *EQTTestString(int which) {
    switch (which) {
        case 0: return EQT_ROUTE_DEVICE_UUID;
        case 1: return EQT_ROUTE_NAME;
        default: return EQT_PROTOCOL_ID;
    }
}

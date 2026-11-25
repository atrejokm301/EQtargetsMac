//
//  EQTIdentity.h
//  EQtargets (iOS)
//
//  Every identity the system remembers about the Control Center output.
//
//  FROZEN AFTER THE FIRST INSTALL ON A DEVICE:
//  - The media sharing protocol id must match in three places: this file, the
//    extension's entitlement, and UTTypeIdentifier in the extension's Info.plist.
//    Changing it replaces the registration, and the output disappears from the picker.
//  - UTTypeDescription is registered at boot. A changed string makes every pick
//    fail until the phone is rebooted.
//  - The device UUID must be constant: discovery and activation can run in
//    separate extension processes, and the audio device UID must equal it.
//

#ifndef EQT_IDENTITY_H
#define EQT_IDENTITY_H

/// Must match the entitlement and UTTypeIdentifier in Extension/Info.plist.
#define EQT_PROTOCOL_ID       "media-device-protocol.com.eqtargets.ios"
/// Also kAudioDevicePropertyDeviceUID of the published audio device.
#define EQT_ROUTE_DEVICE_UUID "45515447-5453-494F-A000-000000000001"
/// The row shown in Control Center. The app also uses it to detect a route
/// that points at itself (a feedback loop).
#define EQT_ROUTE_NAME        "EQtargets"
#define EQT_ROUTE_MANUFACTURER "EQtargets"
#define EQT_ROUTE_MODEL_UID   "com.eqtargets.ios.model"
#define EQT_LOG_SUBSYSTEM     "com.eqtargets.ios"

#endif /* EQT_IDENTITY_H */

//
//  EQTDeviceDriver.h
//  EQtargets (iOS)
//
//  The audio device behind the Control Center row. See EQTDeviceDriver.m.
//

#import <Foundation/Foundation.h>
#import "EQTLink.h"

NS_ASSUME_NONNULL_BEGIN

@interface EQTDeviceDriver : NSObject

@property (class, readonly) EQTDeviceDriver *shared;

@property (nonatomic) float volume;
@property (nonatomic) BOOL muted;
/// Runs on an audio-server thread if the connection to it is lost.
@property (atomic, copy, nullable) void (^onAudioServerLost)(void);

/// Registers the plug-in with the audio server. `deviceUID` must equal
/// MediaOutputDevice.id.
- (OSStatus)publishWithDeviceUID:(NSString *)deviceUID;
- (void)unpublish;

/// From now on, every WriteMix is pushed into `sender` on the IO thread.
/// `sender` must stay allocated for the life of the process.
- (void)startCaptureWithSender:(EQTLinkSender *)sender;
- (void)stopCapture;

@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) uint32_t channelCount;
@property (nonatomic, readonly) uint64_t framesDelivered;

@end

NS_ASSUME_NONNULL_END

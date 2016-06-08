//
//  CastService.m
//  Connect SDK
//
//  Created by Jeremy White on 2/7/14.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <GoogleCast/GoogleCast.h>
#import "CastService.h"
#import "ConnectError.h"
#import "CastWebAppSession.h"

#define kCastServiceMuteSubscriptionName @"mute"
#define kCastServiceVolumeSubscriptionName @"volume"

@interface CastService () <ServiceCommandDelegate>

@property (nonatomic, retain) GCKCastChannel *castPrivateChannel;

@end

@implementation CastService
{
    int UID;

    NSString *_currentAppId;
    NSString *_launchingAppId;

    NSMutableDictionary *_launchSuccessBlocks;
    NSMutableDictionary *_launchFailureBlocks;

    NSMutableDictionary *_sessions; // TODO: are we using this? get rid of it if not
    NSMutableArray *_subscriptions;

    float _currentVolumeLevel;
    BOOL _currentMuteStatus;
}

- (void) commonSetup
{
    _launchSuccessBlocks = [NSMutableDictionary new];
    _launchFailureBlocks = [NSMutableDictionary new];

    _sessions = [NSMutableDictionary new];
    _subscriptions = [NSMutableArray new];

    UID = 0;
}

- (instancetype) init
{
    self = [super init];

    if (self)
        [self commonSetup];

    return self;
}

- (instancetype)initWithServiceConfig:(ServiceConfig *)serviceConfig
{
    self = [super initWithServiceConfig:serviceConfig];

    if (self)
        [self commonSetup];

    return self;
}

+ (NSDictionary *) discoveryParameters
{
    return @{
             @"serviceId":kConnectSDKCastServiceId
             };
}

- (BOOL)isConnectable
{
    return YES;
}

- (void) updateCapabilities
{
    NSArray *capabilities = [NSArray new];

    capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaPlayerCapabilities];
    capabilities = [capabilities arrayByAddingObjectsFromArray:kVolumeControlCapabilities];
    capabilities = [capabilities arrayByAddingObjectsFromArray:@[
            kMediaControlPlay,
            kMediaControlPause,
            kMediaControlStop,
            kMediaControlDuration,
            kMediaControlSeek,
            kMediaControlPosition,
            kMediaControlPlayState,
            kMediaControlPlayStateSubscribe,
            kMediaControlMetadata,
            kMediaControlMetadataSubscribe,

            kWebAppLauncherLaunch,
            kWebAppLauncherMessageSend,
            kWebAppLauncherMessageReceive,
            kWebAppLauncherMessageSendJSON,
            kWebAppLauncherMessageReceiveJSON,
            kWebAppLauncherConnect,
            kWebAppLauncherDisconnect,
            kWebAppLauncherJoin,
            kWebAppLauncherClose
    ]];

    [self setCapabilities:capabilities];
}

- (void) sendNotSupportedFailure:(FailureBlock)failure
{
    if (failure)
        failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:nil]);
}

-(NSString *)castWebAppId
{
    if(_castWebAppId == nil){
        _castWebAppId = kGCKMediaDefaultReceiverApplicationID;
    }
    return _castWebAppId;
}

#pragma mark - Connection

- (void)connect
{
    if (self.connected)
        return;

    if (!_castDevice)
    {
        UInt32 devicePort = (UInt32) self.serviceDescription.port;
        _castDevice = [[GCKDevice alloc] initWithIPAddress:self.serviceDescription.address servicePort:devicePort];
    }
    
    _castMediaControlChannel.delegate = nil;
    _castMediaControlChannel = nil;
    _castDeviceManager = nil;
    
    if (!_castDeviceManager)
    {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *clientPackageName = [info objectForKey:@"CFBundleIdentifier"];
        
        _castDeviceManager = [[GCKDeviceManager alloc] initWithDevice:_castDevice clientPackageName:clientPackageName];
    }
    
    _castDeviceManager.delegate = self;
    [_castDeviceManager connect];
}

- (void)reconnect {
    self.isReconnect = YES;
    [self connect];
}

- (void)disconnect
{
	[self disconnect:nil];
}

- (void)disconnectAndTerminateApplication {
	if (!self.connected)
		return;
	
	self.connected = NO;
    self.isReconnect = NO;
	
    _castDeviceManager.delegate = nil;
	[_castDeviceManager stopApplication];
	[_castDeviceManager disconnect];
	
	if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)])
		dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:nil]; });
}

- (void)disconnect:(NSError *)error
{
    if (!self.connected && !error)
        return;

    self.connected = NO;
    self.isReconnect = NO;

    _castDeviceManager.delegate = nil;
    [_castDeviceManager leaveApplication];
    [_castDeviceManager disconnect];

    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)])
        dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:error]; });
}

#pragma mark - Subscriptions

- (int)sendSubscription:(ServiceSubscription *)subscription type:(ServiceSubscriptionType)type payload:(id)payload toURL:(NSURL *)URL withId:(int)callId
{
    if (type == ServiceSubscriptionTypeUnsubscribe)
        [_subscriptions removeObject:subscription];
    else if (type == ServiceSubscriptionTypeSubscribe)
        [_subscriptions addObject:subscription];

    return callId;
}

- (int) getNextId
{
    UID = UID + 1;
    return UID;
}

#pragma mark - GCKDeviceManagerDelegate

- (void)deviceManagerDidConnect:(GCKDeviceManager *)deviceManager
{
    DLog(@"connected");

    self.connected = YES;
    
    if (self.isReconnect) {
        self.isReconnect = NO;
        dispatch_on_main(^{ [self.delegate deviceServiceConnectionSuccess:self]; });
        
        _castMediaControlChannel = [[GCKMediaControlChannel alloc] init];
        [_castDeviceManager addChannel:_castMediaControlChannel];
        
        Class channelClass = NSClassFromString(@"HACastChannel");
        if (channelClass) {
            _castPrivateChannel = [[channelClass alloc] initWithNamespace:@""];
            [_castDeviceManager addChannel:_castPrivateChannel];
            [self deviceChannelFix];
        }
        
        return;
    }
	
	BOOL relaunchIfRunning = NO;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		GCKLaunchOptions *lauchOptions = [[GCKLaunchOptions alloc] initWithRelaunchIfRunning:relaunchIfRunning];
		BOOL result = [_castDeviceManager launchApplication:self.castWebAppId withLaunchOptions:lauchOptions];
		if (!result) {
			dispatch_on_main(^{
				[self.delegate deviceService:self didFailConnectWithError:[NSError errorWithDomain:ConnectErrorDomain code:0 userInfo:nil]];
			});
			return;
		}
		
		_castMediaControlChannel = [[GCKMediaControlChannel alloc] init];
		[_castDeviceManager addChannel:_castMediaControlChannel];
		
		Class channelClass = NSClassFromString(@"HACastChannel");
		if (channelClass) {
			_castPrivateChannel = [[channelClass alloc] initWithNamespace:@""];
			[_castDeviceManager addChannel:_castPrivateChannel];
            [self deviceChannelFix];
		}
	});
}


- (void)deviceChannelFix {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id customManager = NSClassFromString(@"HACastDevicesManager");
    customManager = [customManager performSelector:NSSelectorFromString(@"sharedInstance")];
    [customManager performSelector:NSSelectorFromString(@"setupChromecastChannel:") withObject:_castPrivateChannel];
#pragma clang diagnostic pop
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didConnectToCastApplication:(GCKApplicationMetadata *)applicationMetadata sessionID:(NSString *)sessionID launchedApplication:(BOOL)launchedApplication
{
    DLog(@"%@ (%@)", applicationMetadata.applicationName, applicationMetadata.applicationID);

    _currentAppId = applicationMetadata.applicationID;

    WebAppLaunchSuccessBlock success = [_launchSuccessBlocks objectForKey:applicationMetadata.applicationID];

    LaunchSession *launchSession = [LaunchSession launchSessionForAppId:applicationMetadata.applicationID];
    launchSession.name = applicationMetadata.applicationName;
    launchSession.sessionId = sessionID;
    launchSession.sessionType = LaunchSessionTypeWebApp;
    launchSession.service = self;

    CastWebAppSession *webAppSession = [[CastWebAppSession alloc] initWithLaunchSession:launchSession service:self];
    webAppSession.metadata = applicationMetadata;

    [_sessions setObject:webAppSession forKey:applicationMetadata.applicationID];
    
    _castMediaControlChannel.delegate = webAppSession;

    if (success)
        dispatch_on_main(^{ success(webAppSession); });

    [_launchSuccessBlocks removeObjectForKey:applicationMetadata.applicationID];
    [_launchFailureBlocks removeObjectForKey:applicationMetadata.applicationID];
    _launchingAppId = nil;
	
	dispatch_on_main(^{
		if ([self.delegate respondsToSelector:@selector(deviceServiceConnectionSuccess:mediaControl:)]) {
			[self.delegate deviceServiceConnectionSuccess:self mediaControl:webAppSession.mediaControl];
		} else {
			[self.delegate deviceServiceConnectionSuccess:self];
		}
	});
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didDisconnectFromApplicationWithError:(NSError *)error
{
    DLog(@"%@", error.localizedDescription);
	
	NSDictionary *dict = nil;
	if (error) {
		dict = @{@"error": error};
	}
	
	[[NSNotificationCenter defaultCenter] postNotificationName:@"kCastDeviceApplicationDisconnected" object:nil userInfo:dict];
    
    self.connected = NO;
    self.isReconnect = NO;
    _castDeviceManager.delegate = nil;
    [_castDeviceManager disconnect];

    if (!_currentAppId)
        return;

    WebAppSession *webAppSession = [_sessions objectForKey:_currentAppId];

    if (!webAppSession || !webAppSession.delegate)
        return;

    [webAppSession.delegate webAppSessionDidDisconnect:webAppSession];
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didFailToConnectToApplicationWithError:(NSError *)error
{
    DLog(@"%@", error.localizedDescription);

    if (_launchingAppId)
    {
        FailureBlock failure = [_launchFailureBlocks objectForKey:_launchingAppId];

        if (failure)
            dispatch_on_main(^{ failure(error); });

        [_launchSuccessBlocks removeObjectForKey:_launchingAppId];
        [_launchFailureBlocks removeObjectForKey:_launchingAppId];
        _launchingAppId = nil;
	} else {
		dispatch_on_main(^{
			[self disconnect:[NSError errorWithDomain:ConnectErrorDomain code:0 userInfo:nil]];
		});
		return;
	}
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didFailToConnectWithError:(NSError *)error
{
    DLog(@"%@", error.localizedDescription);

    if (self.connected || error)
        [self disconnect:error];
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didFailToStopApplicationWithError:(NSError *)error
{
    DLog(@"%@", error.localizedDescription);
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didReceiveApplicationMetadata:(GCKApplicationMetadata *)applicationMetadata
{
    DLog(@"%@", applicationMetadata);

    _currentAppId = applicationMetadata.applicationID;
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager volumeDidChangeToLevel:(float)volumeLevel isMuted:(BOOL)isMuted
{
    DLog(@"volume: %f isMuted: %d", volumeLevel, isMuted);

	[[NSNotificationCenter defaultCenter] postNotificationName:@"kCastDeviceVolumeChange" object:@(volumeLevel)];
	
    _currentVolumeLevel = volumeLevel;
    _currentMuteStatus = isMuted;

    [_subscriptions enumerateObjectsUsingBlock:^(ServiceSubscription *subscription, NSUInteger idx, BOOL *stop)
    {
        NSString *eventName = (NSString *) subscription.payload;

        if (eventName)
        {
            if ([eventName isEqualToString:kCastServiceVolumeSubscriptionName])
            {
                [subscription.successCalls enumerateObjectsUsingBlock:^(id success, NSUInteger successIdx, BOOL *successStop)
                {
                    VolumeSuccessBlock volumeSuccess = (VolumeSuccessBlock) success;

                    if (volumeSuccess)
                        dispatch_on_main(^{ volumeSuccess(volumeLevel); });
                }];
            }

            if ([eventName isEqualToString:kCastServiceMuteSubscriptionName])
            {
                [subscription.successCalls enumerateObjectsUsingBlock:^(id success, NSUInteger successIdx, BOOL *successStop)
                {
                    MuteSuccessBlock muteSuccess = (MuteSuccessBlock) success;

                    if (muteSuccess)
                        dispatch_on_main(^{ muteSuccess(isMuted); });
                }];
            }
        }
    }];
}

- (void)deviceManager:(GCKDeviceManager *)deviceManager didDisconnectWithError:(NSError *)error
{
    DLog(@"%@", error.localizedDescription);

    self.connected = NO;
    self.isReconnect = NO;
    
    _castMediaControlChannel.delegate = nil;
    _castMediaControlChannel = nil;
    _castDeviceManager = nil;

    dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:error]; });
}

#pragma mark - Media Player

- (id<MediaPlayer>)mediaPlayer
{
    return self;
}

- (CapabilityPriorityLevel)mediaPlayerPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)displayImage:(NSURL *)imageURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
//
}

- (void) displayImage:(MediaInfo *)mediaInfo
              success:(MediaPlayerDisplaySuccessBlock)success
              failure:(FailureBlock)failure
{
//
}

- (void) displayImageWithMediaInfo:(MediaInfo *)mediaInfo success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
//
}

- (void) playMedia:(NSURL *)videoURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypeMovie];
    [metaData setString:title forKey:kGCKMetadataKeyTitle];
    [metaData setString:description forKey:kGCKMetadataKeySubtitle];

    if (iconURL)
    {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }
    
    GCKMediaInformation *mediaInformation = [[GCKMediaInformation alloc] initWithContentID:videoURL.absoluteString streamType:GCKMediaStreamTypeBuffered contentType:mimeType metadata:metaData streamDuration:1000 customData:nil];

    [self playMedia:mediaInformation webAppId:self.castWebAppId success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) playMedia:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypeMovie];
    [metaData setString:mediaInfo.title forKey:kGCKMetadataKeyTitle];
    [metaData setString:mediaInfo.description forKey:kGCKMetadataKeySubtitle];
    
    
    NSURL *iconURL;
    if (mediaInfo.images) {
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    if (iconURL) {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }
    
    GCKMediaInformation *mediaInformation = [[GCKMediaInformation alloc] initWithContentID:mediaInfo.url.absoluteString streamType:GCKMediaStreamTypeBuffered contentType:mediaInfo.mimeType metadata:metaData streamDuration:1000 customData:nil];
    
    [self playMedia:mediaInformation webAppId:self.castWebAppId success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) playMediaWithMediaInfo:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypeMovie];
    [metaData setString:mediaInfo.title forKey:kGCKMetadataKeyTitle];
    [metaData setString:mediaInfo.description forKey:kGCKMetadataKeySubtitle];
    
    if (iconURL)
    {
        GCKImage *iconImage = [[GCKImage alloc] initWithURL:iconURL width:100 height:100];
        [metaData addImage:iconImage];
    }
    
    GCKMediaInformation *mediaInformation = [[GCKMediaInformation alloc] initWithContentID:mediaInfo.url.absoluteString streamType:GCKMediaStreamTypeBuffered contentType:mediaInfo.mimeType metadata:metaData streamDuration:1000 customData:nil];
    
    [self playMedia:mediaInformation webAppId:self.castWebAppId success:success failure:failure];
}

- (void)playMedia:(NSURL *)videoURL contentDetails:(HACastContentDetails *)contentDetails position:(NSTimeInterval)position success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
	GCKMediaMetadata *metaData = [[GCKMediaMetadata alloc] initWithMetadataType:GCKMediaMetadataTypeMovie];
	[metaData setString:contentDetails.contentTitle forKey:kGCKMetadataKeyTitle];
	[metaData setString:contentDetails.contentDescription forKey:kGCKMetadataKeySubtitle];
	[metaData setString:contentDetails.contentId forKey:@"contentId"];
	[metaData setString:contentDetails.uuid forKey:@"uuid"];
	[metaData setString:contentDetails.friendlyName forKey:@"friendly_name"];
	[metaData setString:contentDetails.sessionId forKey:@"sessionId"];
	[metaData setString:contentDetails.encryptedUsername forKey:@"encrypted_username"];
	[metaData setString:contentDetails.encryptedPassword forKey:@"encrypted_password"];
	[metaData setString:contentDetails.config forKey:@"config"];
    
    if (contentDetails.selectedAudio) {
        [metaData setString:contentDetails.selectedAudio forKey:@"selectedAudio"];
    }
    if (contentDetails.selectedSubtitle) {
        [metaData setString:contentDetails.selectedSubtitle forKey:@"selectedSubtitle"];
    }
	
	if (contentDetails.contentImage)
	{
		GCKImage *iconImage = [[GCKImage alloc] initWithURL:[NSURL URLWithString:[contentDetails.contentImage stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]] width:100 height:100];
		[metaData addImage:iconImage];
	}
	
	GCKMediaInformation *mediaInformation = [[GCKMediaInformation alloc] initWithContentID:videoURL.absoluteString streamType:GCKMediaStreamTypeBuffered contentType:@"video/mp4" metadata:metaData streamDuration:1000 customData:nil];
	
	NSString *receiverID = self.castWebAppId;
	
	if (position > 1) {
		[self playMedia:mediaInformation position:position webAppId:receiverID success:success failure:failure];
	} else {
		[self playMedia:mediaInformation webAppId:receiverID success:success failure:failure];
	}
}

- (void) playMedia:(GCKMediaInformation *)mediaInformation webAppId:(NSString *)mediaAppId success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
	if ((_castDeviceManager.applicationConnectionState == GCKConnectionStateConnected) && _castMediaControlChannel) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ //we need this delay otherwise video is not loaded properly
			NSInteger result = [_castMediaControlChannel loadMedia:mediaInformation autoplay:YES];
			
			if (result == kGCKInvalidRequestID) {
				if (failure) {
					failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
				}
			} else {
				if (success) {
                    CastWebAppSession *webAppSession = [_sessions objectForKey:_currentAppId];
                    MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:webAppSession.launchSession andMediaControl:webAppSession.mediaControl];
                    success(launchObject);
				}
			}
		});
	} else {
		WebAppLaunchSuccessBlock webAppLaunchBlock = ^(WebAppSession *webAppSession)
		{
			NSInteger result = [_castMediaControlChannel loadMedia:mediaInformation autoplay:YES];
			
			if (result == kGCKInvalidRequestID)
			{
				if (failure)
					failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
			} else
			{
				webAppSession.launchSession.sessionType = LaunchSessionTypeMedia;
				
				_castMediaControlChannel.delegate = (CastWebAppSession *) webAppSession;
				
				if (success) {
					MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:webAppSession.launchSession andMediaControl:webAppSession.mediaControl];
					success(launchObject);
				}
			}
		};
		
		_launchingAppId = mediaAppId;
		
		[_launchSuccessBlocks setObject:webAppLaunchBlock forKey:mediaAppId];
		
		if (failure)
			[_launchFailureBlocks setObject:failure forKey:mediaAppId];
		
		BOOL relaunchIfRunning = NO; //since we need to join our app (if it's running)

		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			GCKLaunchOptions *lauchOptions = [[GCKLaunchOptions alloc] initWithRelaunchIfRunning:relaunchIfRunning];
			BOOL result = [_castDeviceManager launchApplication:mediaAppId withLaunchOptions:lauchOptions];
			
			if (!result)
			{
				[_launchSuccessBlocks removeObjectForKey:mediaAppId];
				[_launchFailureBlocks removeObjectForKey:mediaAppId];
				
				if (failure)
					failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
			}
		});

	}
}

- (void) playMedia:(GCKMediaInformation *)mediaInformation position:(NSTimeInterval)position webAppId:(NSString *)mediaAppId success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
	if ((_castDeviceManager.applicationConnectionState == GCKConnectionStateConnected) && _castMediaControlChannel) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ //we need this delay otherwise video is not loaded properly
			NSInteger result = [_castMediaControlChannel loadMedia:mediaInformation autoplay:YES playPosition:position];
			
			if (result == kGCKInvalidRequestID) {
				if (failure) {
					failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
				}
			} else {
				if (success) {
                    CastWebAppSession *webAppSession = [_sessions objectForKey:_currentAppId];
                    MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:webAppSession.launchSession andMediaControl:webAppSession.mediaControl];
                    success(launchObject);
				}
			}
		});
	} else {
		WebAppLaunchSuccessBlock webAppLaunchBlock = ^(WebAppSession *webAppSession)
		{
			NSInteger result = [_castMediaControlChannel loadMedia:mediaInformation autoplay:YES playPosition:position];
			
			if (result == kGCKInvalidRequestID)
			{
				if (failure)
					failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
			} else
			{
				webAppSession.launchSession.sessionType = LaunchSessionTypeMedia;
				
				_castMediaControlChannel.delegate = (CastWebAppSession *) webAppSession;
				
				if (success) {
					MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:webAppSession.launchSession andMediaControl:webAppSession.mediaControl];
					success(launchObject);
				}
			}
		};
		
		_launchingAppId = mediaAppId;
		
		[_launchSuccessBlocks setObject:webAppLaunchBlock forKey:mediaAppId];
		
		if (failure)
			[_launchFailureBlocks setObject:failure forKey:mediaAppId];
		
		BOOL relaunchIfRunning = NO; //since we need to join our app (if it's running)
		
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			GCKLaunchOptions *lauchOptions = [[GCKLaunchOptions alloc] initWithRelaunchIfRunning:relaunchIfRunning];
			BOOL result = [_castDeviceManager launchApplication:mediaAppId withLaunchOptions:lauchOptions];
			
			if (!result)
			{
				[_launchSuccessBlocks removeObjectForKey:mediaAppId];
				[_launchFailureBlocks removeObjectForKey:mediaAppId];
				
				if (failure)
					failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
			}
		});
	}
}

- (void)closeMedia:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    BOOL result = [_castDeviceManager stopApplicationWithSessionID:launchSession.sessionId];

    if (result)
    {
        if (success)
            success(nil);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
    }
}

- (void)joinCastingApp:(WebAppJoinCastingSuccessBlock)success failure:(FailureBlock)failure {
	WebAppLaunchSuccessBlock webAppLaunchBlock = ^(WebAppSession *webAppSession) {
		webAppSession.launchSession.sessionType = LaunchSessionTypeMedia;
		_castMediaControlChannel.delegate = (CastWebAppSession *) webAppSession;
		if (success) {
			success(webAppSession.mediaControl);
		}
	};
	
	NSString *mediaAppId = self.castWebAppId;
	
	_launchingAppId = mediaAppId;
	
	[_launchSuccessBlocks setObject:webAppLaunchBlock forKey:mediaAppId];
	
	if (failure) {
		[_launchFailureBlocks setObject:failure forKey:mediaAppId];
	}
	
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		BOOL result = [_castDeviceManager joinApplication:mediaAppId];
		
		if (!result) {
			[_launchSuccessBlocks removeObjectForKey:mediaAppId];
			[_launchFailureBlocks removeObjectForKey:mediaAppId];
			
			if (failure) {
				failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
			}
		}
	});
}

#pragma mark - Media Control

- (id<MediaControl>)mediaControl
{
    return self;
}

- (CapabilityPriorityLevel)mediaControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)playWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSInteger result;

    @try
    {
        result = [_castMediaControlChannel play];
    } @catch (NSException *exception)
    {
        // this exception will be caught when trying to send command with no video
        result = kGCKInvalidRequestID;
    }

    if (result == kGCKInvalidRequestID)
    {
        if (failure)
            failure(nil);
    } else
    {
        if (success)
            success(nil);
    }
}

- (void)pauseWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSInteger result;

    @try
    {
        result = [_castMediaControlChannel pause];
    } @catch (NSException *exception)
    {
        // this exception will be caught when trying to send command with no video
        result = kGCKInvalidRequestID;
    }

    if (result == kGCKInvalidRequestID)
    {
        if (failure)
            failure(nil);
    } else
    {
        if (success)
            success(nil);
    }
}

- (void)stopWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSInteger result;

    @try
    {
        result = [_castMediaControlChannel stop];
    } @catch (NSException *exception)
    {
        // this exception will be caught when trying to send command with no video
        result = kGCKInvalidRequestID;
    }

    if (result == kGCKInvalidRequestID)
    {
        if (failure)
            failure(nil);
    } else
    {
        if (success)
            success(nil);
    }
}

- (void)rewindWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (failure)
        failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:nil]);
}

- (void)fastForwardWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (failure)
        failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:nil]);
}


#pragma mark - WebAppLauncher

- (id<WebAppLauncher>)webAppLauncher
{
    return self;
}

- (CapabilityPriorityLevel)webAppLauncherPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)launchWebApp:(NSString *)webAppId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchWebApp:webAppId relaunchIfRunning:YES success:success failure:failure];
}

- (void)launchWebApp:(NSString *)webAppId relaunchIfRunning:(BOOL)relaunchIfRunning success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [_launchSuccessBlocks removeObjectForKey:webAppId];
    [_launchFailureBlocks removeObjectForKey:webAppId];

    if (success)
        [_launchSuccessBlocks setObject:success forKey:webAppId];

    if (failure)
        [_launchFailureBlocks setObject:failure forKey:webAppId];

    _launchingAppId = webAppId;
	
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		GCKLaunchOptions *lauchOptions = [[GCKLaunchOptions alloc] initWithRelaunchIfRunning:relaunchIfRunning];
		BOOL result = [_castDeviceManager launchApplication:webAppId withLaunchOptions:lauchOptions];
		
		if (!result)
		{
			[_launchSuccessBlocks removeObjectForKey:webAppId];
			[_launchFailureBlocks removeObjectForKey:webAppId];
			_launchingAppId = nil;
			
			if (failure)
				failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Could not detect if web app launched -- make sure you have the Google Cast Receiver JavaScript file in your web app"]);
		}
	});
}

- (void)launchWebApp:(NSString *)webAppId params:(NSDictionary *)params success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (failure)
        failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:nil]);
}

- (void)launchWebApp:(NSString *)webAppId params:(NSDictionary *)params relaunchIfRunning:(BOOL)relaunchIfRunning success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (failure)
        failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:nil]);
}

- (void)joinWebApp:(LaunchSession *)webAppLaunchSession success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    WebAppLaunchSuccessBlock mySuccess = ^(WebAppSession *webAppSession)
    {
        SuccessBlock joinSuccess = ^(id responseObject)
        {
			_castMediaControlChannel.delegate = (CastWebAppSession *) webAppSession;
            if (success)
                success(webAppSession);
        };

        [webAppSession connectWithSuccess:joinSuccess failure:failure];
    };

    [_launchSuccessBlocks setObject:mySuccess forKey:webAppLaunchSession.appId];

    if (failure)
        [_launchFailureBlocks setObject:failure forKey:webAppLaunchSession.appId];

    _launchingAppId = webAppLaunchSession.appId;

	
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		BOOL result = [_castDeviceManager joinApplication:webAppLaunchSession.appId];
		
		if (!result)
		{
			[_launchSuccessBlocks removeObjectForKey:webAppLaunchSession.appId];
			[_launchFailureBlocks removeObjectForKey:webAppLaunchSession.appId];
			_launchingAppId = nil;
			
			if (failure)
				failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Could not detect if web app launched -- make sure you have the Google Cast Receiver JavaScript file in your web app"]);
		}
	});
}

- (void) joinWebAppWithId:(NSString *)webAppId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    LaunchSession *launchSession = [LaunchSession launchSessionForAppId:webAppId];
    launchSession.sessionType = LaunchSessionTypeWebApp;
    launchSession.service = self;

    [self joinWebApp:launchSession success:success failure:failure];
}

- (void)closeWebApp:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    BOOL result = [self.castDeviceManager stopApplication];

    if (result)
    {
        if (success)
            success(nil);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
    }
}

- (void) pinWebApp:(NSString *)webAppId success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

-(void)unPinWebApp:(NSString *)webAppId success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)isWebAppPinned:(NSString *)webAppId success:(WebAppPinStatusBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeIsWebAppPinned:(NSString*)webAppId success:(WebAppPinStatusBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
    return nil;
}

#pragma mark - Volume Control

- (id <VolumeControl>)volumeControl
{
    return self;
}

- (CapabilityPriorityLevel)volumeControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)volumeUpWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self getVolumeWithSuccess:^(float volume)
    {
        if (volume >= 1.0)
        {
            if (success)
                success(nil);
        } else
        {
            float newVolume = volume + 0.01;

            if (newVolume > 1.0)
                newVolume = 1.0;

            [self setVolume:newVolume success:success failure:failure];
        }
    } failure:failure];
}

- (void)volumeDownWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self getVolumeWithSuccess:^(float volume)
    {
        if (volume <= 0.0)
        {
            if (success)
                success(nil);
        } else
        {
            float newVolume = volume - 0.01;

            if (newVolume < 0.0)
                newVolume = 0.0;

            [self setVolume:newVolume success:success failure:failure];
        }
    } failure:failure];
}

- (void)setMute:(BOOL)mute success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSInteger result = [self.castDeviceManager setMuted:mute];

    if (result == kGCKInvalidRequestID)
    {
        if (failure)
            [ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil];
    } else
    {
        [self.castDeviceManager requestDeviceStatus];

        if (success)
            success(nil);
    }
}

- (void)getMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure
{
    if (_currentMuteStatus)
    {
        if (success)
            success(_currentMuteStatus);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Cannot get this information without media loaded"]);
    }
}

- (ServiceSubscription *)subscribeMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure
{
    if (_currentMuteStatus)
    {
        if (success)
            success(_currentMuteStatus);
    }

    ServiceSubscription *subscription = [ServiceSubscription subscriptionWithDelegate:self target:nil payload:kCastServiceMuteSubscriptionName callId:[self getNextId]];
    [subscription addSuccess:success];
    [subscription addFailure:failure];
    [subscription subscribe];

    return subscription;
}

- (void)setVolume:(float)volume success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSInteger result;
    NSString *failureMessage;

    @try
    {
        result = [self.castDeviceManager setVolume:volume];
    } @catch (NSException *ex)
    {
        // this is likely caused by having no active media session
        result = kGCKInvalidRequestID;
        failureMessage = @"There is no active media session to set volume on";
    }

    if (result == kGCKInvalidRequestID)
    {
        if (failure)
            [ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:failureMessage];
    } else
    {
        [self.castDeviceManager requestDeviceStatus];

        if (success)
            success(nil);
    }
}

- (void)getVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure
{
    if (_currentVolumeLevel)
    {
        if (success)
            success(_currentVolumeLevel);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Cannot get this information without media loaded"]);
    }
}

- (ServiceSubscription *)subscribeVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure
{
    if (_currentVolumeLevel)
    {
        if (success)
            success(_currentVolumeLevel);
    }

    ServiceSubscription *subscription = [ServiceSubscription subscriptionWithDelegate:self target:nil payload:kCastServiceVolumeSubscriptionName callId:[self getNextId]];
    [subscription addSuccess:success];
    [subscription addFailure:failure];
    [subscription subscribe];

    [self.castDeviceManager requestDeviceStatus];

    return subscription;
}

@end

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <dlfcn.h>

static NSString *const kJarvisShotNotification = @"com.max.jarvis.screenshot.capture";
static NSString *const kJarvisSpeechNotification = @"com.max.jarvis.speech.speak";
static NSString *const kJarvisSpeechVoicesNotification = @"com.max.jarvis.speech.voices";
static NSString *const kJarvisAudioRecordNotification = @"com.max.jarvis.audio.record";
static NSString *const kJarvisShotRequestPath = @"/var/jb/tmp/jarvis-screenshot-request.json";
static NSString *const kJarvisShotStatusPath = @"/var/jb/tmp/jarvis-screenshot-status.json";
static NSString *const kJarvisShotDefaultPath = @"/var/jb/tmp/jarvis-screenshot.png";
static NSString *const kJarvisSpeechRequestPath = @"/var/jb/tmp/jarvis-speech-request.json";
static NSString *const kJarvisSpeechStatusPath = @"/var/jb/tmp/jarvis-speech-status.json";
static NSString *const kJarvisSpeechVoicesRequestPath = @"/var/jb/tmp/jarvis-speech-voices-request.json";
static NSString *const kJarvisSpeechVoicesStatusPath = @"/var/jb/tmp/jarvis-speech-voices-status.json";
static NSString *const kJarvisAudioRecordRequestPath = @"/var/jb/tmp/jarvis-audio-record-request.json";
static NSString *const kJarvisAudioRecordStatusPath = @"/var/jb/tmp/jarvis-audio-record-status.json";
static NSString *const kJarvisAudioRecordDefaultPath = @"/var/jb/tmp/jarvis-listen.m4a";

typedef CGImageRef (*UICreateScreenImageFn)(void);

static void jsbWriteStatus(NSDictionary *status) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
	[data writeToFile:kJarvisShotStatusPath atomically:YES];
}

static void jsbWriteSpeechStatus(NSDictionary *status) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
	[data writeToFile:kJarvisSpeechStatusPath atomically:YES];
}

static void jsbWriteSpeechVoicesStatus(NSDictionary *status) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
	[data writeToFile:kJarvisSpeechVoicesStatusPath atomically:YES];
}

static void jsbWriteAudioRecordStatus(NSDictionary *status) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
	[data writeToFile:kJarvisAudioRecordStatusPath atomically:YES];
}

static NSDictionary *jsbAudioSessionInfo(void) {
	AVAudioSession *session = AVAudioSession.sharedInstance;
	NSMutableArray *outputs = [NSMutableArray array];
	for (AVAudioSessionPortDescription *output in session.currentRoute.outputs) {
		[outputs addObject:@{
			@"portType": output.portType ?: @"",
			@"portName": output.portName ?: @"",
			@"uid": output.UID ?: @"",
		}];
	}
	return @{
		@"category": session.category ?: @"",
		@"mode": session.mode ?: @"",
		@"outputVolume": @(session.outputVolume),
		@"outputs": outputs,
	};
}

static NSError *jsbActivateSpeechAudioSession(void) {
	AVAudioSession *session = AVAudioSession.sharedInstance;
	NSError *error = nil;
	BOOL ok = [session setCategory:AVAudioSessionCategoryPlayback
	                   withOptions:AVAudioSessionCategoryOptionDuckOthers
	                         error:&error];
	if (ok) ok = [session setMode:AVAudioSessionModeSpokenAudio error:&error];
	if (ok) ok = [session setActive:YES error:&error];
	return ok ? nil : error;
}

static NSDictionary *jsbReadRequest(void) {
	NSData *data = [NSData dataWithContentsOfFile:kJarvisShotRequestPath];
	if (!data) return @{};
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

static NSDictionary *jsbReadSpeechRequest(void) {
	NSData *data = [NSData dataWithContentsOfFile:kJarvisSpeechRequestPath];
	if (!data) return @{};
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

static NSDictionary *jsbReadSpeechVoicesRequest(void) {
	NSData *data = [NSData dataWithContentsOfFile:kJarvisSpeechVoicesRequestPath];
	if (!data) return @{};
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

static NSDictionary *jsbReadAudioRecordRequest(void) {
	NSData *data = [NSData dataWithContentsOfFile:kJarvisAudioRecordRequestPath];
	if (!data) return @{};
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

static NSString *jsbOutputPathFromRequest(NSDictionary *request) {
	NSString *path = request[@"path"];
	if (![path isKindOfClass:NSString.class] || path.length == 0) return kJarvisShotDefaultPath;
	if (![path hasPrefix:@"/var/jb/tmp/"] && ![path hasPrefix:@"/tmp/"]) return kJarvisShotDefaultPath;
	return path;
}

static NSString *jsbAudioPathFromRequest(NSDictionary *request) {
	NSString *path = request[@"path"];
	if (![path isKindOfClass:NSString.class] || path.length == 0) return kJarvisAudioRecordDefaultPath;
	if (![path hasPrefix:@"/var/jb/tmp/"] && ![path hasPrefix:@"/tmp/"]) return kJarvisAudioRecordDefaultPath;
	return path;
}

static UICreateScreenImageFn jsbScreenImageFn(void) {
	static UICreateScreenImageFn fn;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void *handle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW);
		fn = handle ? (UICreateScreenImageFn)dlsym(handle, "UICreateScreenImage") : NULL;
	});
	return fn;
}

static void jsbCaptureNow(void) {
	NSDictionary *request = jsbReadRequest();
	NSString *seq = [request[@"seq"] isKindOfClass:NSString.class] ? request[@"seq"] : @"";
	NSString *path = jsbOutputPathFromRequest(request);

	UICreateScreenImageFn createImage = jsbScreenImageFn();
	if (!createImage) {
		jsbWriteStatus(@{ @"ok": @NO, @"seq": seq, @"error": @"UICreateScreenImage unavailable" });
		return;
	}

	CGImageRef image = createImage();
	if (!image) {
		jsbWriteStatus(@{ @"ok": @NO, @"seq": seq, @"error": @"UICreateScreenImage returned NULL" });
		return;
	}

	[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
	                          withIntermediateDirectories:YES
	                                           attributes:nil
	                                                error:nil];
	CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
	CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	if (!destination) {
		CGImageRelease(image);
		jsbWriteStatus(@{ @"ok": @NO, @"seq": seq, @"error": @"CGImageDestinationCreateWithURL failed" });
		return;
	}

	CGImageDestinationAddImage(destination, image, NULL);
	BOOL ok = CGImageDestinationFinalize(destination);
	size_t width = CGImageGetWidth(image);
	size_t height = CGImageGetHeight(image);
	CFRelease(destination);
	CGImageRelease(image);

	if (!ok) {
		jsbWriteStatus(@{ @"ok": @NO, @"seq": seq, @"error": @"PNG write failed" });
		return;
	}

	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	jsbWriteStatus(@{
		@"ok": @YES,
		@"seq": seq,
		@"path": path,
		@"width": @(width),
		@"height": @(height),
		@"bytes": @([attrs fileSize]),
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}

static void jsbCaptureNotification(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{
		jsbCaptureNow();
	});
}

@interface JSBSpeechDelegate : NSObject <AVSpeechSynthesizerDelegate>
@property (nonatomic, copy) NSString *seq;
@property (nonatomic, copy) NSString *text;
@end

@implementation JSBSpeechDelegate
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
	jsbWriteSpeechStatus(@{
		@"ok": @YES,
		@"seq": self.seq ?: @"",
		@"spoken": self.text ?: @"",
		@"audioSession": jsbAudioSessionInfo(),
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
	jsbWriteSpeechStatus(@{
		@"ok": @NO,
		@"seq": self.seq ?: @"",
		@"error": @"speech cancelled",
		@"audioSession": jsbAudioSessionInfo(),
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}
@end

static AVSpeechSynthesizer *gJarvisSpeechSynthesizer;
static JSBSpeechDelegate *gJarvisSpeechDelegate;

static void jsbSpeakNow(void) {
	NSDictionary *request = jsbReadSpeechRequest();
	NSString *seq = [request[@"seq"] isKindOfClass:NSString.class] ? request[@"seq"] : @"";
	NSString *text = [request[@"text"] isKindOfClass:NSString.class] ? request[@"text"] : @"";
	NSNumber *rate = [request[@"rate"] isKindOfClass:NSNumber.class] ? request[@"rate"] : nil;
	NSString *voice = [request[@"voice"] isKindOfClass:NSString.class] ? request[@"voice"] : nil;

	if (text.length == 0) {
		jsbWriteSpeechStatus(@{ @"ok": @NO, @"seq": seq, @"error": @"empty speech text" });
		return;
	}
	if (text.length > 500) text = [[text substringToIndex:500] stringByAppendingString:@"..."];

	if (!gJarvisSpeechSynthesizer) {
		gJarvisSpeechSynthesizer = [AVSpeechSynthesizer new];
		gJarvisSpeechDelegate = [JSBSpeechDelegate new];
		gJarvisSpeechSynthesizer.delegate = gJarvisSpeechDelegate;
	}

	if (gJarvisSpeechSynthesizer.speaking) {
		[gJarvisSpeechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
	}

	NSError *sessionError = jsbActivateSpeechAudioSession();
	if (sessionError) {
		jsbWriteSpeechStatus(@{
			@"ok": @NO,
			@"seq": seq,
			@"error": sessionError.localizedDescription ?: @"speech audio session failed",
			@"audioSession": jsbAudioSessionInfo(),
		});
		return;
	}

	gJarvisSpeechDelegate.seq = seq;
	gJarvisSpeechDelegate.text = text;

	AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
	utterance.rate = rate ? MIN(MAX(rate.floatValue, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate) : AVSpeechUtteranceDefaultSpeechRate;
	if (voice.length) {
		AVSpeechSynthesisVoice *selected = [AVSpeechSynthesisVoice voiceWithIdentifier:voice];
		if (selected) utterance.voice = selected;
	}

	jsbWriteSpeechStatus(@{
		@"ok": @YES,
		@"seq": seq,
		@"started": @YES,
		@"audioSession": jsbAudioSessionInfo(),
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
	[gJarvisSpeechSynthesizer speakUtterance:utterance];
}

static void jsbSpeechNotification(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{
		jsbSpeakNow();
	});
}

static void jsbListSpeechVoicesNow(void) {
	NSDictionary *request = jsbReadSpeechVoicesRequest();
	NSString *seq = [request[@"seq"] isKindOfClass:NSString.class] ? request[@"seq"] : @"";
	NSMutableArray *voices = [NSMutableArray array];
	for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
		[voices addObject:@{
			@"identifier": voice.identifier ?: @"",
			@"name": voice.name ?: @"",
			@"language": voice.language ?: @"",
			@"quality": @((NSInteger)voice.quality),
		}];
	}
	jsbWriteSpeechVoicesStatus(@{
		@"ok": @YES,
		@"seq": seq,
		@"voices": voices,
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}

static void jsbSpeechVoicesNotification(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{
		jsbListSpeechVoicesNow();
	});
}

@interface JSBAudioRecordDelegate : NSObject <AVAudioRecorderDelegate>
@property (nonatomic, copy) NSString *seq;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) NSTimeInterval startedAt;
@end

@implementation JSBAudioRecordDelegate
- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.path error:nil];
	[AVAudioSession.sharedInstance setActive:NO withOptions:0 error:nil];
	jsbWriteAudioRecordStatus(@{
		@"ok": @(flag),
		@"seq": self.seq ?: @"",
		@"path": self.path ?: @"",
		@"bytes": @([attrs fileSize]),
		@"duration": @(MAX(0, NSDate.date.timeIntervalSince1970 - self.startedAt)),
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}
- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
	[AVAudioSession.sharedInstance setActive:NO withOptions:0 error:nil];
	jsbWriteAudioRecordStatus(@{
		@"ok": @NO,
		@"seq": self.seq ?: @"",
		@"error": error.localizedDescription ?: @"audio recorder encode error",
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}
@end

static AVAudioRecorder *gJarvisAudioRecorder;
static JSBAudioRecordDelegate *gJarvisAudioRecordDelegate;

static void jsbRecordAudioNow(void) {
	NSDictionary *request = jsbReadAudioRecordRequest();
	NSString *seq = [request[@"seq"] isKindOfClass:NSString.class] ? request[@"seq"] : @"";
	NSString *path = jsbAudioPathFromRequest(request);
	NSNumber *durationValue = [request[@"duration"] isKindOfClass:NSNumber.class] ? request[@"duration"] : @3;
	NSTimeInterval duration = MIN(MAX(durationValue.doubleValue, 1.0), 15.0);

	if (gJarvisAudioRecorder.recording) [gJarvisAudioRecorder stop];

	[[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
	                          withIntermediateDirectories:YES
	                                           attributes:nil
	                                                error:nil];
	[[NSFileManager defaultManager] removeItemAtPath:path error:nil];

	NSError *error = nil;
	AVAudioSession *session = AVAudioSession.sharedInstance;
	if (![session setCategory:AVAudioSessionCategoryRecord error:&error] ||
	    ![session setActive:YES error:&error]) {
		jsbWriteAudioRecordStatus(@{ @"ok": @NO, @"seq": seq, @"error": error.localizedDescription ?: @"audio session failed" });
		return;
	}

	NSDictionary *settings = @{
		AVFormatIDKey: @(kAudioFormatMPEG4AAC),
		AVSampleRateKey: @44100.0,
		AVNumberOfChannelsKey: @1,
		AVEncoderAudioQualityKey: @(AVAudioQualityMedium),
	};

	gJarvisAudioRecordDelegate = [JSBAudioRecordDelegate new];
	gJarvisAudioRecordDelegate.seq = seq;
	gJarvisAudioRecordDelegate.path = path;
	gJarvisAudioRecordDelegate.startedAt = NSDate.date.timeIntervalSince1970;

	gJarvisAudioRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:path]
	                                                   settings:settings
	                                                      error:&error];
	if (!gJarvisAudioRecorder) {
		jsbWriteAudioRecordStatus(@{ @"ok": @NO, @"seq": seq, @"error": error.localizedDescription ?: @"audio recorder unavailable" });
		return;
	}
	gJarvisAudioRecorder.delegate = gJarvisAudioRecordDelegate;
	gJarvisAudioRecorder.meteringEnabled = YES;
	if (![gJarvisAudioRecorder prepareToRecord] || ![gJarvisAudioRecorder recordForDuration:duration]) {
		jsbWriteAudioRecordStatus(@{ @"ok": @NO, @"seq": seq, @"error": @"recording failed to start" });
		return;
	}
	jsbWriteAudioRecordStatus(@{
		@"ok": @YES,
		@"seq": seq,
		@"started": @YES,
		@"path": path,
		@"duration": @(duration),
		@"ts": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)),
	});
}

static void jsbAudioRecordNotification(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
	dispatch_async(dispatch_get_main_queue(), ^{
		jsbRecordAudioNow();
	});
}

%ctor {
	NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
	if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		jsbCaptureNotification, (__bridge CFStringRef)kJarvisShotNotification,
		NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		jsbSpeechNotification, (__bridge CFStringRef)kJarvisSpeechNotification,
		NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		jsbSpeechVoicesNotification, (__bridge CFStringRef)kJarvisSpeechVoicesNotification,
		NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFNotificationCenterAddObserver(
		CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		jsbAudioRecordNotification, (__bridge CFStringRef)kJarvisAudioRecordNotification,
		NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	NSLog(@"[JarvisScreenshotBridge] listening for %@, %@, %@, and %@", kJarvisShotNotification, kJarvisSpeechNotification, kJarvisSpeechVoicesNotification, kJarvisAudioRecordNotification);
}

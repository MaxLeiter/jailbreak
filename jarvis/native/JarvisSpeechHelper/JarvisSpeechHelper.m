#import <Foundation/Foundation.h>
#import <Speech/Speech.h>

static void printJSON(NSDictionary *dict) {
	NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
	fwrite(data.bytes, 1, data.length, stdout);
	fputc('\n', stdout);
}

static NSString *authName(SFSpeechRecognizerAuthorizationStatus status) {
	switch (status) {
		case SFSpeechRecognizerAuthorizationStatusNotDetermined: return @"notDetermined";
		case SFSpeechRecognizerAuthorizationStatusDenied: return @"denied";
		case SFSpeechRecognizerAuthorizationStatusRestricted: return @"restricted";
		case SFSpeechRecognizerAuthorizationStatusAuthorized: return @"authorized";
	}
	return @"unknown";
}

static int status(void) {
	SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en_US"]];
	printJSON(@{
		@"ok": @YES,
		@"bundle": NSBundle.mainBundle.bundleIdentifier ?: @"",
		@"authorization": authName(SFSpeechRecognizer.authorizationStatus),
		@"available": @(recognizer.available),
		@"onDevice": @(recognizer.supportsOnDeviceRecognition),
	});
	return 0;
}

static int transcribe(NSString *path, NSString *localeIdentifier) {
	if (SFSpeechRecognizer.authorizationStatus != SFSpeechRecognizerAuthorizationStatusAuthorized) {
		printJSON(@{ @"ok": @NO, @"error": [NSString stringWithFormat:@"Speech authorization %@", authName(SFSpeechRecognizer.authorizationStatus)] });
		return 2;
	}

	NSURL *url = [NSURL fileURLWithPath:path];
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		printJSON(@{ @"ok": @NO, @"error": @"audio file does not exist", @"path": path });
		return 3;
	}

	NSLocale *locale = [NSLocale localeWithLocaleIdentifier:localeIdentifier ?: @"en_US"];
	SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
	if (!recognizer || !recognizer.available) {
		printJSON(@{ @"ok": @NO, @"error": @"speech recognizer unavailable" });
		return 4;
	}

	SFSpeechURLRecognitionRequest *request = [[SFSpeechURLRecognitionRequest alloc] initWithURL:url];
	if (recognizer.supportsOnDeviceRecognition) request.requiresOnDeviceRecognition = YES;
	request.shouldReportPartialResults = NO;

	__block BOOL done = NO;
	__block NSString *transcript = @"";
	__block NSString *errorText = nil;
	SFSpeechRecognitionTask *task =
		[recognizer recognitionTaskWithRequest:request
		                         resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
			if (result.bestTranscription.formattedString.length) {
				transcript = result.bestTranscription.formattedString;
			}
			if (error) {
				errorText = error.localizedDescription ?: @"recognition failed";
				done = YES;
				return;
			}
			if (result.isFinal) done = YES;
		}];

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
	while (!done && deadline.timeIntervalSinceNow > 0) {
		[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
	}
	if (!done) {
		[task cancel];
		errorText = @"recognition timed out";
	}

	if (errorText && transcript.length == 0) {
		printJSON(@{ @"ok": @NO, @"error": errorText, @"path": path });
		return 5;
	}
	printJSON(@{ @"ok": @YES, @"path": path, @"transcript": transcript, @"final": @(done) });
	return 0;
}

int main(int argc, char **argv) {
	@autoreleasepool {
		if (argc >= 2 && !strcmp(argv[1], "status")) return status();
		if (argc >= 3 && !strcmp(argv[1], "transcribe")) {
			NSString *path = [NSString stringWithUTF8String:argv[2]];
			NSString *locale = argc >= 4 ? [NSString stringWithUTF8String:argv[3]] : @"en_US";
			return transcribe(path, locale);
		}
		printJSON(@{ @"ok": @NO, @"error": @"usage: JarvisSpeechHelper status | transcribe <audio-path> [locale]" });
		return 64;
	}
}

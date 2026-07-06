/*
 * BrowserViewController — minimal browser chrome for M0: one tab, an address bar, and
 * back / forward / reload. UIKit analogue of UI/AppKit/Interface/TabController (which
 * is an NSToolbar + LocationSearchField). Multi-tab is deferred (see README).
 */
#import "BrowserViewController.h"
#import "LBTrace.h"

#include <stdlib.h>

static NSString* lb_initial_url()
{
    NSString* candidate = nil;
    char const* env = getenv("LADYBIRD_START_URL");
    if (env && *env)
        candidate = [NSString stringWithUTF8String:env];

    if (!candidate.length)
        candidate = [NSString stringWithContentsOfFile:@"/var/jb/tmp/ladybird-start-url" encoding:NSUTF8StringEncoding error:nil];

    candidate = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return candidate.length ? candidate : @"https://example.com/";
}

@implementation BrowserViewController {
    LadybirdWebView* _webView;
    UITextField* _addressBar;
    UIToolbar* _toolbar;
    UIActivityIndicatorView* _spinner;
}

- (void)viewDidLoad
{
    lb_trace("BrowserVC viewDidLoad: enter");
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    // --- Address bar row ---
    _addressBar = [[UITextField alloc] init];
    _addressBar.borderStyle = UITextBorderStyleRoundedRect;
    _addressBar.placeholder = @"Search or enter address";
    _addressBar.keyboardType = UIKeyboardTypeURL;
    _addressBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _addressBar.autocorrectionType = UITextAutocorrectionTypeNo;
    _addressBar.clearButtonMode = UITextFieldViewModeWhileEditing;
    _addressBar.returnKeyType = UIReturnKeyGo;
    _addressBar.delegate = self;
    _addressBar.translatesAutoresizingMaskIntoConstraints = NO;

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;

    UIBarButtonItem* back = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.backward"] style:UIBarButtonItemStylePlain target:self action:@selector(goBack)];
    UIBarButtonItem* forward = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"] style:UIBarButtonItemStylePlain target:self action:@selector(goForward)];
    UIBarButtonItem* reload = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(reload)];
    UIBarButtonItem* addressItem = [[UIBarButtonItem alloc] initWithCustomView:_addressBar];
    UIBarButtonItem* spinnerItem = [[UIBarButtonItem alloc] initWithCustomView:_spinner];
    UIBarButtonItem* flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    addressItem.width = 10000; // let the flexible space rules stretch it

    _toolbar = [[UIToolbar alloc] init];
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    _toolbar.items = @[ back, forward, reload, flex, addressItem, flex, spinnerItem ];

    // --- Web view ---
    lb_trace("BrowserVC viewDidLoad: creating LadybirdWebView");
    _webView = [[LadybirdWebView alloc] initWithFrame:CGRectZero];
    lb_trace("BrowserVC viewDidLoad: LadybirdWebView created");
    _webView.observer = self;
    _webView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:_toolbar];
    [self.view addSubview:_webView];

    UILayoutGuide* g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_webView.topAnchor constraintEqualToAnchor:_toolbar.bottomAnchor],
        [_webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    NSString* initialURL = lb_initial_url();
    lb_trace("BrowserVC viewDidLoad: loadURL initial len=%lu", (unsigned long)initialURL.length);
    [_webView loadURL:initialURL];
    lb_trace("BrowserVC viewDidLoad: done");
}

#pragma mark - Chrome actions
- (void)goBack { [_webView goBack]; }
- (void)goForward { [_webView goForward]; }
- (void)reload { [_webView reload]; }

#pragma mark - UITextFieldDelegate
- (BOOL)textFieldShouldBeginEditing:(UITextField*)tf
{
    lb_trace("address begin? text-len=%lu", (unsigned long)tf.text.length);
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField*)tf
{
    lb_trace("address did begin first=%d", tf.isFirstResponder);
}

- (BOOL)textField:(UITextField*)tf shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)string
{
    lb_trace("address change loc=%lu len=%lu repl-len=%lu first=%d",
        (unsigned long)range.location,
        (unsigned long)range.length,
        (unsigned long)string.length,
        tf.isFirstResponder);
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField*)tf
{
    lb_trace("address return text-len=%lu", (unsigned long)tf.text.length);
    [tf resignFirstResponder];
    if (tf.text.length)
        [_webView loadURL:tf.text];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField*)tf
{
    lb_trace("address did end first=%d text-len=%lu", tf.isFirstResponder, (unsigned long)tf.text.length);
}

#pragma mark - LadybirdWebViewObserver
- (void)webView:(LadybirdWebView*)wv didChangeTitle:(NSString*)title { self.title = title; }
- (void)webView:(LadybirdWebView*)wv didChangeURL:(NSString*)url
{
    lb_trace("web url change len=%lu address-first=%d", (unsigned long)url.length, _addressBar.isFirstResponder);
    if (!_addressBar.isFirstResponder)
        _addressBar.text = url;
}
- (void)webViewDidStartLoading:(LadybirdWebView*)wv { [_spinner startAnimating]; }
- (void)webViewDidFinishLoading:(LadybirdWebView*)wv { [_spinner stopAnimating]; }

@end

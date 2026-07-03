/*
 * Event.h — UIKit event -> LibWeb input event converters. UIKit analogue of
 * UI/AppKit/Interface/Event.{h,mm}. Objective-C++.
 *
 * The bridge's enqueue_input_event(Web::MouseEvent) multiplies widget coords by DPR via
 * to_content_position, so these converters pass LOGICAL (point) coordinates, matching
 * the AppKit converters.
 */
#pragma once

#import <UIKit/UIKit.h>
#include <LibWeb/Page/InputEvent.h>
#include <LibWeb/UIEvents/KeyCode.h>
#include <LibWeb/UIEvents/MouseButton.h>

@class LadybirdWebView;

namespace LadybirdIOS {

Web::MouseEvent mouse_event_from_touch(LadybirdWebView*, UITouch*, Web::MouseEvent::Type, Web::UIEvents::MouseButton);
Web::MouseEvent mouse_event_at(LadybirdWebView*, CGPoint, Web::MouseEvent::Type, Web::UIEvents::MouseButton);
Web::MouseEvent wheel_event(LadybirdWebView*, CGPoint at, double delta_x, double delta_y);
Web::PinchEvent pinch_event(LadybirdWebView*, CGPoint at, CGFloat scale);

Web::KeyEvent key_event_from_text(NSString* text, Web::KeyEvent::Type);
Web::KeyEvent key_event_backspace(Web::KeyEvent::Type);
Web::KeyEvent key_event_from_uikey(UIKey*, Web::KeyEvent::Type);

// UIKeyboardHIDUsage -> Web::UIEvents::KeyCode (rewrite of AppKit's Carbon kVK_* switch).
Web::UIEvents::KeyCode key_code_from_hid_usage(UIKeyboardHIDUsage);

}

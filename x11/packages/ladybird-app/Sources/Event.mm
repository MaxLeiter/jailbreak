/*
 * Event.mm — see Event.h. Ported from UI/AppKit/Interface/Event.mm, with the Carbon
 * kVK_* keycode switch rewritten against UIKeyboardHIDUsage* (iOS uses HID usages, not
 * Carbon virtual keycodes).
 *
 * Field order confirmed against Libraries/LibWeb/Page/InputEvent.h (engine 92b0257):
 *   MouseEvent { type, position, screen_position, button, buttons, modifiers,
 *                wheel_delta_x, wheel_delta_y, click_count, browser_data,
 *                async_scroll_performed_default_action=false }
 *   KeyEvent   { type, key, modifiers, code_point, repeat, should_insert_text, browser_data }
 *   PinchEvent { position, modifiers, scale_delta }
 * (matches UI/AppKit/Interface/Event.mm's ns_event_to_* converters — no longer guessed.)
 */
#import "Event.h"
#import "LadybirdWebView.h"

namespace LadybirdIOS {

static Gfx::IntPoint point_in_view(LadybirdWebView* view, CGPoint p)
{
    return Gfx::IntPoint { (int)p.x, (int)p.y }; // logical points; bridge scales by DPR
}

static Web::UIEvents::KeyModifier current_modifiers()
{
    return Web::UIEvents::KeyModifier::Mod_None; // hardware modifier state filled from UIKey.modifierFlags below
}

Web::MouseEvent mouse_event_at(LadybirdWebView* view, CGPoint at, Web::MouseEvent::Type type, Web::UIEvents::MouseButton button)
{
    auto pos = point_in_view(view, at);
    return Web::MouseEvent {
        type,
        pos.to_type<Web::DevicePixels>(),
        pos.to_type<Web::DevicePixels>(), // screen position; refine with window offset later
        button,
        button, // buttons held
        current_modifiers(),
        0, 0,   // wheel_delta_x/y
        1,      // click_count
        nullptr,
    };
}

Web::MouseEvent mouse_event_from_touch(LadybirdWebView* view, UITouch* touch, Web::MouseEvent::Type type, Web::UIEvents::MouseButton button)
{
    return mouse_event_at(view, [touch locationInView:view], type, button);
}

Web::MouseEvent wheel_event(LadybirdWebView* view, CGPoint at, double delta_x, double delta_y)
{
    auto pos = point_in_view(view, at);
    return Web::MouseEvent {
        Web::MouseEvent::Type::MouseWheel,
        pos.to_type<Web::DevicePixels>(),
        pos.to_type<Web::DevicePixels>(),
        Web::UIEvents::MouseButton::None,
        Web::UIEvents::MouseButton::None,
        current_modifiers(),
        delta_x, delta_y,
        0,
        nullptr,
    };
}

Web::PinchEvent pinch_event(LadybirdWebView* view, CGPoint at, CGFloat scale)
{
    auto pos = point_in_view(view, at);
    // Field order is { position, modifiers, scale_delta } (confirmed above). AppKit feeds
    // NSMagnificationGestureRecognizer.magnification, an additive delta reset to 0 each callback.
    // UIPinchGestureRecognizer.scale is a cumulative multiplier the caller resets to 1.0 each
    // callback, so the equivalent additive delta is (scale - 1.0). scale_delta is a double.
    return Web::PinchEvent {
        pos.to_type<Web::DevicePixels>(),
        current_modifiers(),
        (double)scale - 1.0,
    };
}

Web::KeyEvent key_event_from_text(NSString* text, Web::KeyEvent::Type type)
{
    u32 code_point = 0;
    if (text.length > 0)
        code_point = [text characterAtIndex:0];
    return Web::KeyEvent {
        type,
        Web::UIEvents::KeyCode::Key_Invalid, // no physical key from soft keyboard text
        Web::UIEvents::KeyModifier::Mod_None,
        code_point,
        false, // repeat
        true,  // should_insert_text: this IS committed text from the soft keyboard
        // browser_data defaults to nullptr
    };
}

Web::KeyEvent key_event_backspace(Web::KeyEvent::Type type)
{
    return Web::KeyEvent {
        type,
        Web::UIEvents::KeyCode::Key_Backspace,
        Web::UIEvents::KeyModifier::Mod_None,
        0,
        false, // repeat
        false, // should_insert_text: backspace edits, it does not insert text
    };
}

static Web::UIEvents::KeyModifier modifiers_from_flags(UIKeyModifierFlags flags)
{
    unsigned mods = Web::UIEvents::KeyModifier::Mod_None;
    if (flags & UIKeyModifierShift)     mods |= Web::UIEvents::KeyModifier::Mod_Shift;
    if (flags & UIKeyModifierControl)   mods |= Web::UIEvents::KeyModifier::Mod_Ctrl;
    if (flags & UIKeyModifierAlternate) mods |= Web::UIEvents::KeyModifier::Mod_Alt;
    if (flags & UIKeyModifierCommand)   mods |= Web::UIEvents::KeyModifier::Mod_Super;
    return (Web::UIEvents::KeyModifier)mods;
}

Web::KeyEvent key_event_from_uikey(UIKey* key, Web::KeyEvent::Type type)
{
    u32 code_point = 0;
    NSString* chars = key.characters;
    if (chars.length > 0) {
        unichar c = [chars characterAtIndex:0];
        if (!(c >= 0xE000 && c <= 0xF8FF)) // drop PUA functional glyphs, like AppKit
            code_point = c;
    }
    return Web::KeyEvent {
        type,
        key_code_from_hid_usage(key.keyCode),
        modifiers_from_flags(key.modifierFlags),
        code_point,
        false, // repeat: UIKey has no is-a-repeat flag; leave false (matches soft-key path)
        // should_insert_text: AppKit routes key-downs through -interpretKeyEvents: which inserts
        // text on the down edge only; mirror that so a hardware key-down commits its character.
        type == Web::KeyEvent::Type::KeyDown,
    };
}

// Minimal HID-usage -> KeyCode map. Fill out the full table (letters, digits, F-keys,
// keypad) porting AppKit's ns_key_code_to_key_code switch; this covers the essentials.
Web::UIEvents::KeyCode key_code_from_hid_usage(UIKeyboardHIDUsage usage)
{
    using KC = Web::UIEvents::KeyCode;
    switch (usage) {
    case UIKeyboardHIDUsageKeyboardReturnOrEnter: return KC::Key_Return;
    case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return KC::Key_Backspace;
    case UIKeyboardHIDUsageKeyboardTab: return KC::Key_Tab;
    case UIKeyboardHIDUsageKeyboardSpacebar: return KC::Key_Space;
    case UIKeyboardHIDUsageKeyboardEscape: return KC::Key_Escape;
    case UIKeyboardHIDUsageKeyboardLeftArrow: return KC::Key_Left;
    case UIKeyboardHIDUsageKeyboardRightArrow: return KC::Key_Right;
    case UIKeyboardHIDUsageKeyboardUpArrow: return KC::Key_Up;
    case UIKeyboardHIDUsageKeyboardDownArrow: return KC::Key_Down;
    default:
        if (usage >= UIKeyboardHIDUsageKeyboardA && usage <= UIKeyboardHIDUsageKeyboardZ)
            return (KC)((int)KC::Key_A + (usage - UIKeyboardHIDUsageKeyboardA));
        return KC::Key_Invalid;
    }
}

}

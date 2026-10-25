/// Which wire lane a touch gesture uses, decided ONCE when the gesture starts
/// and held until every finger has lifted. Pure, so Tests/ can drive it.
///
/// Why once: the old code re-decided on every touchesBegan. On the KDE desktop
/// preset one finger goes through the pointer lane (the parallel wl_touch is
/// suppressed), but landing a second finger flipped the decision mid-gesture, so
/// the FIRST finger's later moves and its up were sent as wl_touch with no matching
/// down (invariant 37). A gesture now keeps the lane it started with.
struct LaneTracker {
    struct Lane: Equatable {
        /// Send wl_touch / tablet records for this gesture's touches.
        var forwardsTouch: Bool
        /// Touch replaces the emulated pointer (no pointer press or click).
        var consumesPointer: Bool

        /// Before any gesture, or after a drop mid-gesture: send nothing, so a
        /// finger that already lost its down can never produce a stray motion/up.
        static let none = Lane(forwardsTouch: false, consumesPointer: false)
    }

    private(set) var lane = Lane.none
    private(set) var isDecided = false

    /// A touchesBegan. `isGestureStart` is true when these are the only touches on
    /// the glass (no gesture was already running). Returns the lane to use.
    ///
    ///  - one direct finger, touch not replacing the pointer: pointer lane
    ///    (forwardsTouch false) for the whole gesture, whatever lands later;
    ///  - everything else (simultaneous multi-touch, Pencil, touch-native
    ///    presets): wl_touch / tablet, and the pointer is consumed only when the
    ///    session says touch replaces it.
    mutating func began(isGestureStart: Bool, newTouches: Int, allDirect: Bool,
                        replacesPointer: Bool) -> Lane {
        if isGestureStart || !isDecided {
            let pointerLane = newTouches == 1 && allDirect && !replacesPointer
            lane = Lane(forwardsTouch: !pointerLane, consumesPointer: replacesPointer)
            isDecided = true
        }
        return lane
    }

    /// Every finger lifted, or the latches were reset.
    mutating func reset() {
        lane = .none
        isDecided = false
    }
}

import CoreGraphics

/// Captured in Quartz desktop coordinates when L2 is pressed. Keeping the
/// display and bounds together rejects a monitor/layout change before release.
struct MotionJumpPointerTarget: Equatable {
    let displayID: CGDirectDisplayID
    let bounds: CGRect

    func point(for quadrant: MotionJumpQuadrant) -> CGPoint {
        let right = quadrant == .upperRight || quadrant == .lowerRight
        let lower = quadrant == .lowerLeft || quadrant == .lowerRight
        return CGPoint(x: bounds.minX + bounds.width * (right ? 0.75 : 0.25),
                       y: bounds.minY + bounds.height * (lower ? 0.75 : 0.25))
    }
}

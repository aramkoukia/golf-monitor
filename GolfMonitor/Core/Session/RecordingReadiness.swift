import CoreGraphics
import Foundation

/// Decides the "Ready to swing" indicator on the Range screen and the watch:
/// whether a recording started now is likely to be caught and measured.
/// Checks, in order: light, camera view, ball lock, room in front of the ball.
///
/// Pure value logic, unit-tested.
struct RecordingReadiness {
    /// Mean frame brightness below this with a fixed fast shutter is too dark
    /// to track the ball (roughly 2½ stops under a normal exposure).
    var darkBelow: Float = 0.17
    /// Once too dark, it must get this much brighter to clear, so the
    /// indicator doesn't flicker at the boundary.
    var darkHysteresis: Float = 0.03
    /// Share of the frame width a ball needs in front of it, toward the
    /// target, to stay in view for the frames after impact.
    var minRoomAhead: CGFloat = 0.25

    struct Inputs {
        var scene: SceneSnapshot
        var cameraView: CameraView
        var handedness: Handedness
        /// A fixed shutter (1/1000…1/4000) is set. With Auto the camera
        /// lengthens the exposure itself, so darkness isn't flagged.
        var fixedShutter: Bool
    }

    func evaluate(_ inputs: Inputs, previous: RemoteReadiness? = nil) -> RemoteReadiness {
        if inputs.fixedShutter, let brightness = inputs.scene.brightness {
            let bar = previous == .tooDark ? darkBelow + darkHysteresis : darkBelow
            if brightness < bar { return .tooDark }
        }
        guard inputs.cameraView == .faceOn else { return .readySwingOnly }
        // Locks include a ball that is only hidden for a moment (the golfer
        // at address): it is still watched, so it still counts.
        guard !inputs.scene.locks.isEmpty else { return .noBall }
        let hasRoom = inputs.scene.locks.contains { roomAhead(of: $0, handedness: inputs.handedness) >= minRoomAhead }
        return hasRoom ? .ready : .ballAtEdge
    }

    /// Face-on, the golfer faces the camera, so a right-hander's target is on
    /// the right of the image and a left-hander's on the left.
    func roomAhead(of lock: SceneSnapshot.Lock, handedness: Handedness) -> CGFloat {
        handedness == .right ? 1 - lock.center.x : lock.center.x
    }
}

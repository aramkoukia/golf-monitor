import SwiftUI
import UIKit

/// Hosts the camera's preview layer (an `AVCaptureVideoPreviewLayer` on
/// device, an `AVPlayerLayer` in the Simulator) and keeps it sized to the
/// view on every layout pass, including rotation.
struct CameraPreviewView: UIViewRepresentable {
    var layer: CALayer

    final class HostView: UIView {
        var hosted: CALayer? {
            didSet {
                guard hosted !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let hosted { layer.addSublayer(hosted) }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.hosted = layer
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.hosted = layer
    }
}

/// Maps normalized frame coordinates onto a view that shows the frame with
/// aspect-fill (like the preview layer), so overlays land on the right pixels.
struct AspectFillMapping {
    var viewSize: CGSize
    /// Frame width / height.
    var frameAspect: CGFloat

    private var displayedSize: CGSize {
        guard frameAspect > 0, viewSize.height > 0 else { return viewSize }
        let viewAspect = viewSize.width / viewSize.height
        if viewAspect > frameAspect {
            return CGSize(width: viewSize.width, height: viewSize.width / frameAspect)
        }
        return CGSize(width: viewSize.height * frameAspect, height: viewSize.height)
    }

    func point(_ normalized: CGPoint) -> CGPoint {
        let d = displayedSize
        return CGPoint(x: (viewSize.width - d.width) / 2 + normalized.x * d.width,
                       y: (viewSize.height - d.height) / 2 + normalized.y * d.height)
    }

    /// A length given as a fraction of the frame width.
    func length(_ widthFraction: CGFloat) -> CGFloat { widthFraction * displayedSize.width }
}

/// Maps normalized frame coordinates onto an aspect-FIT view (video players).
struct AspectFitMapping {
    var viewSize: CGSize
    var frameAspect: CGFloat

    var displayedRect: CGRect {
        guard frameAspect > 0, viewSize.height > 0 else { return CGRect(origin: .zero, size: viewSize) }
        let viewAspect = viewSize.width / viewSize.height
        let size = viewAspect > frameAspect
            ? CGSize(width: viewSize.height * frameAspect, height: viewSize.height)
            : CGSize(width: viewSize.width, height: viewSize.width / frameAspect)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func point(_ normalized: CGPoint) -> CGPoint {
        let r = displayedRect
        return CGPoint(x: r.minX + normalized.x * r.width, y: r.minY + normalized.y * r.height)
    }
}

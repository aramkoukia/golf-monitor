import AVFoundation
import SwiftUI
import UIKit

// MARK: - Camera preview wrapper (shared by Session & Setup tabs)

/// UIView that keeps the preview layer sized to its bounds on every layout
/// pass (including rotation), so the viewfinder always fills its frame.
final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let layer = previewLayer {
                layer.videoGravity = .resizeAspectFill
                self.layer.addSublayer(layer)
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    var previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = previewLayer
    }
}

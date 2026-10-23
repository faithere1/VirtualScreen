import AppKit
import ScreenCaptureKit

/// Streams one cropped region of one window into a layer. Only the crop is captured, at the size it is shown.
final class CaptureStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let filter: SCContentFilter
    private let crop: CGRect
    private weak var layer: CALayer?
    private let queue = DispatchQueue(label: "VirtualScreen.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var pixelSize: CGSize
    private var fps: Int
    private var updateWork: DispatchWorkItem?

    /// Called on the main queue when the stream ends on its own (e.g. the source window closed).
    var onStop: ((Error) -> Void)?

    init(filter: SCContentFilter, crop: CGRect, layer: CALayer, pixelSize: CGSize, fps: Int) {
        self.filter = filter
        self.crop = crop
        self.layer = layer
        self.pixelSize = pixelSize
        self.fps = fps
    }

    func start() {
        guard stream == nil else { return }
        let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.ended(error) }
        }
    }

    func stop() {
        updateWork?.cancel()
        stream?.stopCapture()
        stream = nil
    }

    func setFPS(_ fps: Int) {
        self.fps = fps
        stream?.updateConfiguration(makeConfiguration())
    }

    /// Debounced so a live resize doesn't reconfigure the stream on every mouse move.
    func setPixelSize(_ size: CGSize) {
        pixelSize = size
        updateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stream?.updateConfiguration(self.makeConfiguration())
        }
        updateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = crop
        config.width = max(Int(pixelSize.width.rounded()), 2)
        config.height = max(Int(pixelSize.height.rounded()), 2)
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return config
    }

    private func ended(_ error: Error) {
        stream = nil
        onStop?(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        // Hand the IOSurface straight to Core Animation: no pixel copies.
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.ended(error) }
    }
}

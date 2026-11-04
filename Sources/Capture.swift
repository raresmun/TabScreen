import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO

struct StreamConfig: Equatable {
    let codec: String
    let width: Int
    let height: Int
    let description: Data   // avcC record the browser's decoder needs
}

protocol EncodedFrameSink: AnyObject {
    func encoderProduced(config: StreamConfig)
    func encoderProduced(frame: Data, isKeyFrame: Bool, timestampMicros: Double)
}

/// Hardware H.264 encoder tuned for low latency.
final class H264Encoder: @unchecked Sendable {
    let width: Int
    let height: Int
    weak var sink: EncodedFrameSink?

    private var session: VTCompressionSession?
    private var lastConfig: StreamConfig?
    private let lock = NSLock()
    private var forceKeyFrame = true

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func start() -> Bool {
        var created: VTCompressionSession?
        let lowLatencySpec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatencySpec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        var lowLatency = true
        if status != noErr || created == nil {
            Log.write("Low-latency encoder unavailable (\(status)); using the standard one")
            lowLatency = false
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let session = created else {
            Log.write("Could not create the video encoder (\(status))")
            return false
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if result != noErr { Log.write("Encoder setting \(key) not applied (\(result))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        // Baseline-type H.264 never reorders frames, so the tablet's hardware decoder can show every frame
        // the moment it arrives instead of holding a few back.
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                value: "H264_ConstrainedBaseline_AutoLevel" as CFString) != noErr {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        }
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 20_000_000))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 90))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 3600))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        Log.write("Encoder ready: \(width)x\(height), low latency: \(lowLatency)")
        return true
    }

    func requestKeyFrame() {
        lock.lock()
        forceKeyFrame = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let session = session else { return }
        lock.lock()
        let keyFrame = forceKeyFrame
        forceKeyFrame = false
        lock.unlock()
        let properties: CFDictionary? = keyFrame ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary) : nil
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        let submitStatus = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                                           presentationTimeStamp: presentationTime, duration: .invalid,
                                                           frameProperties: properties, infoFlagsOut: nil) { [weak self] encodeStatus, _, sampleBuffer in
            guard encodeStatus == noErr, let sampleBuffer = sampleBuffer else { return }
            self?.handleEncoded(sampleBuffer)
        }
        if submitStatus != noErr {
            Log.write("Encoding failed (\(submitStatus))")
            if keyFrame { requestKeyFrame() }
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary,
           let avcC = atoms["avcC"] as? Data, avcC.count >= 4 {
            let bytes = [UInt8](avcC)
            let codec = String(format: "avc1.%02x%02x%02x", Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let config = StreamConfig(codec: codec, width: Int(dimensions.width), height: Int(dimensions.height), description: avcC)
            if config != lastConfig {
                lastConfig = config
                Log.write("Stream format: \(codec) \(dimensions.width)x\(dimensions.height)")
                sink?.encoderProduced(config: config)
            }
        }
        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool, notSync {
            isKeyFrame = false
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copyStatus == noErr else { return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        sink?.encoderProduced(frame: data, isKeyFrame: isKeyFrame, timestampMicros: (seconds * 1_000_000).rounded())
    }
}

/// Turns frames into JPEG pictures for browsers that can't decode video (pages opened over plain Wi-Fi).
final class JPEGEncoder: @unchecked Sendable {
    /// (JPEG data, is it full size – otherwise half size, used while things move)
    var onFrame: (@Sendable (Data, Bool) -> Void)?

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let queue = DispatchQueue(label: "tabscreen.jpeg", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var pending: (buffer: CVPixelBuffer, quality: Double, scale: Double)?

    /// Encodes the newest frame. Frames arriving while one is being encoded replace each other, so nothing queues up.
    func submit(_ buffer: CVPixelBuffer, quality: Double, scale: Double = 1) {
        lock.lock()
        if busy {
            pending = (buffer, quality, scale)
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        queue.async { self.encodeLoop((buffer, quality, scale)) }
    }

    private func encodeLoop(_ first: (buffer: CVPixelBuffer, quality: Double, scale: Double)) {
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        var job: (buffer: CVPixelBuffer, quality: Double, scale: Double)? = first
        while let current = job {
            var image = CIImage(cvPixelBuffer: current.buffer)
            if current.scale < 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: current.scale, y: current.scale))
            }
            if let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [qualityKey: current.quality]) {
                onFrame?(data, current.scale >= 1)
            }
            lock.lock()
            job = pending
            pending = nil
            if job == nil { busy = false }
            lock.unlock()
        }
    }
}

/// Captures the virtual display with ScreenCaptureKit and feeds the frames to the encoders.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onError: (@Sendable (String) -> Void)?

    private let encoder: H264Encoder
    private let jpegEncoder: JPEGEncoder
    private let queue = DispatchQueue(label: "tabscreen.capture", qos: .userInteractive)
    private var captureStream: SCStream?
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime = Date.distantPast
    private var sharpenPasses = 0
    private var idleTimer: DispatchSourceTimer?
    private var jpegWanted = false
    private var lastJPEGTime = Date.distantPast
    private var sharpJPEGSent = true

    init(encoder: H264Encoder, jpegEncoder: JPEGEncoder) {
        self.encoder = encoder
        self.jpegEncoder = jpegEncoder
        super.init()
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, attempt: Int = 0) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                Log.write("Screen capture not allowed: \(error.localizedDescription)")
                self.onError?("Allow Screen Recording for TabScreen, then restart it")
                return
            }
            guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                if attempt < 20 {
                    self.queue.asyncAfter(deadline: .now() + 0.25) {
                        self.start(displayID: displayID, width: width, height: height, attempt: attempt + 1)
                    }
                } else {
                    Log.write("The virtual display never showed up for capture")
                    self.onError?("Couldn't capture the extra display")
                }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 90)
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.showsCursor = false   // the tablet draws the pointer itself (see CursorTracker)
            configuration.queueDepth = 6
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                Log.write("Could not attach to the capture stream: \(error.localizedDescription)")
                self.onError?("Capture failed to start")
                return
            }
            self.captureStream = stream
            stream.startCapture { error in
                if let error = error {
                    Log.write("Capture failed to start: \(error.localizedDescription)")
                    self.onError?("Capture failed: \(error.localizedDescription)")
                } else {
                    Log.write("Capturing the extra display at \(width)x\(height)")
                }
            }
            self.startIdleTimer()
        }
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        captureStream?.stopCapture { _ in }
        captureStream = nil
    }

    /// Encodes the latest picture again – used when the tablet connects or asks for a fresh key frame.
    func resendLastFrame(asKeyFrame: Bool) {
        queue.async {
            guard let buffer = self.lastBuffer else { return }
            if asKeyFrame { self.encoder.requestKeyFrame() }
            self.encoder.encode(buffer)
        }
    }

    /// Turns JPEG pictures on or off (only needed while a browser without video decoding is connected).
    func setJPEGWanted(_ wanted: Bool) {
        queue.async { self.jpegWanted = wanted }
    }

    /// Sends the current picture right away (a tablet just connected, or its connection caught up).
    func sendJPEGNow() {
        queue.async {
            guard self.jpegWanted, let buffer = self.lastBuffer else { return }
            self.sharpJPEGSent = false   // a sharper copy follows from the idle timer
            self.lastJPEGTime = Date()
            self.jpegEncoder.submit(buffer, quality: 0.7, scale: 0.5)
        }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self = self, let buffer = self.lastBuffer else { return }
            let idle = Date().timeIntervalSince(self.lastFrameTime)
            // When the picture stops changing, send it again in higher quality so text ends up crisp.
            if self.sharpenPasses < 2 && idle > 0.15 {
                self.sharpenPasses += 1
                self.encoder.encode(buffer)
            }
            if self.jpegWanted && !self.sharpJPEGSent && idle > 0.25 && Date().timeIntervalSince(self.lastJPEGTime) > 0.1 {
                self.sharpJPEGSent = true
                self.lastJPEGTime = Date()
                self.jpegEncoder.submit(buffer, quality: 0.9)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastBuffer = pixelBuffer
        lastFrameTime = Date()
        sharpenPasses = 0
        encoder.encode(pixelBuffer)
        if jpegWanted {
            sharpJPEGSent = false
            if lastFrameTime.timeIntervalSince(lastJPEGTime) >= 1.0 / 60 {
                lastJPEGTime = lastFrameTime
                jpegEncoder.submit(pixelBuffer, quality: 0.7, scale: 0.5)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("Capture stopped: \(error.localizedDescription)")
        onError?("Capture stopped: \(error.localizedDescription)")
    }
}

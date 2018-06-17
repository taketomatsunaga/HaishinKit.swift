import Foundation
import AVFoundation
import VideoToolbox
import CoreFoundation

protocol VideoEncoderDelegate: class {
    func didSetFormatDescription(video formatDescription: CMFormatDescription?)
    func sampleOutput(video sampleBuffer: CMSampleBuffer)
}

// MARK: -
final class H264Encoder: NSObject {
    static let supportedSettingsKeys: [String] = [
        "muted",
        "width",
        "height",
        "bitrate",
        "profileLevel",
        "dataRateLimits",
        "canPerformMultiPasses",
        "enabledHardwareEncoder", // macOS only
        "maxKeyFrameIntervalDuration",
        "scalingMode"
    ]

    static let defaultWidth: Int32 = 480
    static let defaultHeight: Int32 = 272
    static let defaultBitrate: UInt32 = 160 * 1024
    static let defaultScalingMode: String = ScalingMode.trim.rawValue

    #if os(iOS)
    static let defaultAttributes: [NSString: AnyObject] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as AnyObject,
        kCVPixelBufferOpenGLESCompatibilityKey: kCFBooleanTrue
    ]
    #else
    static let defaultAttributes: [NSString: AnyObject] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as AnyObject,
        kCVPixelBufferOpenGLCompatibilityKey: kCFBooleanTrue
    ]
    #endif
    static let defaultDataRateLimits: [Int] = [0, 0]

    @objc var muted: Bool = false
    @objc var scalingMode: String = H264Encoder.defaultScalingMode {
        didSet {
            guard scalingMode != oldValue else {
                return
            }
            invalidateSession = true
        }
    }

    @objc var width: Int32 = H264Encoder.defaultWidth {
        didSet {
            guard width != oldValue else {
                return
            }
            invalidateSession = true
        }
    }
    @objc var height: Int32 = H264Encoder.defaultHeight {
        didSet {
            guard height != oldValue else {
                return
            }
            invalidateSession = true
        }
    }
    @objc var enabledHardwareEncoder: Bool = true {
        didSet {
            guard enabledHardwareEncoder != oldValue else {
                return
            }
            invalidateSession = true
        }
    }
    @objc var bitrate: UInt32 = H264Encoder.defaultBitrate {
        didSet {
            guard bitrate != oldValue else {
                return
            }
            setProperty(kVTCompressionPropertyKey_AverageBitRate, Int(bitrate) as CFTypeRef)
        }
    }
    @objc var dataRateLimits: [Int] = H264Encoder.defaultDataRateLimits {
        didSet {
            guard dataRateLimits != oldValue else {
                return
            }
            if dataRateLimits == H264Encoder.defaultDataRateLimits {
                invalidateSession = true
                return
            }
            setProperty(kVTCompressionPropertyKey_DataRateLimits, dataRateLimits as CFTypeRef)
        }
    }
    @objc var profileLevel: String = kVTProfileLevel_H264_Baseline_3_1 as String {
        didSet {
            guard profileLevel != oldValue else {
                return
            }
            invalidateSession = true
        }
    }
    @objc var maxKeyFrameIntervalDuration: Double = 2.0 {
        didSet {
            guard maxKeyFrameIntervalDuration != oldValue else {
                return
            }
            setProperty(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: maxKeyFrameIntervalDuration))
        }
    }
    @objc var canPerformMultiPasses: Bool = true {
        didSet {
            guard canPerformMultiPasses != oldValue else {
                return
            }
            invalidateSession = true
        }
    }

    var locked: UInt32 = 0
    var lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.H264Encoder.lock")
    var expectedFPS: Float64 = AVMixer.defaultFPS {
        didSet {
            guard expectedFPS != oldValue else {
                return
            }
            setProperty(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: expectedFPS))
        }
    }
    var formatDescription: CMFormatDescription? {
        didSet {
            guard !CMFormatDescriptionEqual(formatDescription, oldValue) else {
                return
            }
            delegate?.didSetFormatDescription(video: formatDescription)
        }
    }
    weak var delegate: VideoEncoderDelegate?

    internal(set) var running: Bool = false
    private var supportedProperty: [AnyHashable: Any]? = nil {
        didSet {
            guard logger.isEnabledFor(level: .info) else {
                return
            }
            var keys: [String] = []
            for (key, _) in supportedProperty ?? [:] {
                keys.append(key.description)
            }
            logger.info(keys.joined(separator: ", "))
        }
    }
    private(set) var status: OSStatus = noErr
    private var attributes: [NSString: AnyObject] {
        var attributes: [NSString: AnyObject] = H264Encoder.defaultAttributes
        attributes[kCVPixelBufferWidthKey] = NSNumber(value: width)
        attributes[kCVPixelBufferHeightKey] = NSNumber(value: height)
        return attributes
    }
    private var invalidateSession: Bool = true
    private var lastImageBuffer: CVImageBuffer?

    // @see: https: //developer.apple.com/library/mac/releasenotes/General/APIDiffsMacOSX10_8/VideoToolbox.html
    private var properties: [NSString: NSObject] {
        let isBaseline: Bool = profileLevel.contains("Baseline")
        var properties: [NSString: NSObject] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_ProfileLevel: profileLevel as NSObject,
            kVTCompressionPropertyKey_AverageBitRate: Int(bitrate) as NSObject,
            kVTCompressionPropertyKey_ExpectedFrameRate: NSNumber(value: expectedFPS),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: NSNumber(value: maxKeyFrameIntervalDuration),
            kVTCompressionPropertyKey_AllowFrameReordering: !isBaseline as NSObject,
            kVTCompressionPropertyKey_PixelTransferProperties: [
                "ScalingMode": scalingMode
            ] as NSObject
        ]

#if os(OSX)
        if enabledHardwareEncoder {
            properties[kVTVideoEncoderSpecification_EncoderID] = "com.apple.videotoolbox.videoencoder.h264.gva" as NSObject
            properties["EnableHardwareAcceleratedVideoEncoder"] = kCFBooleanTrue
            properties["RequireHardwareAcceleratedVideoEncoder"] = kCFBooleanTrue
        }
#endif

        if dataRateLimits != H264Encoder.defaultDataRateLimits {
            properties[kVTCompressionPropertyKey_DataRateLimits] = dataRateLimits as NSObject
        }
        if !isBaseline {
            properties[kVTCompressionPropertyKey_H264EntropyMode] = kVTH264EntropyMode_CABAC
        }
        return properties
    }

    private var callback: VTCompressionOutputCallback = {(
        outputCallbackRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?) in
        guard
            let refcon: UnsafeMutableRawPointer = outputCallbackRefCon,
            let sampleBuffer: CMSampleBuffer = sampleBuffer, status == noErr else {
            return
        }
        let encoder: H264Encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        if encoder.canPerformMultiPasses {
            encoder.performMultiPasses(sampleBuffer)
        } else {
            encoder.delegate?.sampleOutput(video: sampleBuffer)
        }
    }

    private var storage: VTMultiPassStorage? {
        didSet {
            if let oldValue: VTMultiPassStorage = oldValue {
                VTMultiPassStorageClose(oldValue)
            }
        }
    }
    private var frameSilo: VTFrameSilo?

    private var _session: VTCompressionSession?
    private var session: VTCompressionSession? {
        get {
            if _session == nil {
                guard VTCompressionSessionCreate(
                    kCFAllocatorDefault,
                    width,
                    height,
                    kCMVideoCodecType_H264,
                    nil,
                    attributes as CFDictionary?,
                    nil,
                    callback,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &_session
                    ) == noErr else {
                    logger.warn("create a VTCompressionSessionCreate")
                    return nil
                }
                invalidateSession = false
                supportedProperty = _session?.copySupportedPropertyDictionary()
                if canPerformMultiPasses {
                    status = VTMultiPassStorageCreate(kCFAllocatorDefault, nil, kCMTimeRangeInvalid, nil, &storage)
                    if let storage: VTMultiPassStorage = storage {
                        VTSessionSetProperty(_session!, kVTCompressionPropertyKey_MultiPassStorage, storage)
                    }
                    status = VTFrameSiloCreate(kCFAllocatorDefault, nil, kCMTimeRangeInvalid, nil, &frameSilo)
                }
                status = VTSessionSetProperties(_session!, properties as CFDictionary)
                status = VTCompressionSessionPrepareToEncodeFrames(_session!)
                if canPerformMultiPasses {
                    status = VTCompressionSessionBeginPass(_session!, VTCompressionSessionOptionFlags.beginFinalPass, nil)
                }
            }
            return _session
        }
        set {
            if let session: VTCompressionSession = _session {
                VTCompressionSessionInvalidate(session)
            }
            _session = newValue
        }
    }

    private var beginPassTime = kCMTimeInvalid

    func encodeImageBuffer(_ imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime, duration: CMTime) {
        guard running && locked == 0 else {
            return
        }
        if invalidateSession {
            frameSilo = nil
            storage = nil
            session = nil
        }

        guard let session: VTCompressionSession = session else {
            return
        }

        if canPerformMultiPasses {
            if let frameSilo = frameSilo, let timeRange = timeRange(presentationTimeStamp) {
                VTCompressionSessionEndPass(session, nil, nil)
                print("=====================\(timeRange)")
                VTFrameSiloCallBlockForEachSampleBuffer(frameSilo, timeRange) { (sampleBuffer) -> OSStatus in
                    print(sampleBuffer.presentationTimeStamp)
                    return noErr
                }
                VTCompressionSessionBeginPass(session, VTCompressionSessionOptionFlags(rawValue: 0), nil)
                //beginPassTime = presentationTimeStamp
            }
            if beginPassTime == kCMTimeInvalid {
                beginPassTime = presentationTimeStamp
                VTCompressionSessionBeginPass(session, VTCompressionSessionOptionFlags(rawValue: 0), nil)
            }
        }

        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(
            session,
            muted ? lastImageBuffer ?? imageBuffer : imageBuffer,
            presentationTimeStamp,
            duration,
            nil,
            nil,
            &flags
        )

        if !muted {
            lastImageBuffer = imageBuffer
        }
    }

    func performMultiPasses(_ sampleBuffer: CMSampleBuffer) {
        guard let frameSilo = self.frameSilo else {
            return
        }
        VTFrameSiloAddSampleBuffer(frameSilo, sampleBuffer)
    }

    private func timeRange(_ timestamp: CMTime) -> CMTimeRange? {
        if beginPassTime == kCMTimeInvalid {
            return nil
        }
        if 0.2 < (timestamp.seconds - beginPassTime.seconds) {
            return CMTimeRange(start: beginPassTime, end: timestamp)
        }
        return nil
    }

    private func setProperty(_ key: CFString, _ value: CFTypeRef?) {
        lockQueue.async {
            guard let session: VTCompressionSession = self._session else {
                return
            }
            self.status = VTSessionSetProperty(
                session,
                key,
                value
            )
        }
    }

#if os(iOS)
    @objc func applicationWillEnterForeground(_ notification: Notification) {
        invalidateSession = true
    }
    @objc func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type: AVAudioSessionInterruptionType = AVAudioSessionInterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }
#endif
}

extension H264Encoder: Running {
    // MARK: Running
    func startRunning() {
        lockQueue.async {
            self.running = true
#if os(iOS)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.didAudioSessionInterruption),
                name: .AVAudioSessionInterruption,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.applicationWillEnterForeground),
                name: .UIApplicationWillEnterForeground,
                object: nil
            )
#endif
        }
    }

    func stopRunning() {
        lockQueue.async {
            self.storage = nil
            self.frameSilo = nil
            self.session = nil
            self.lastImageBuffer = nil
            self.formatDescription = nil
#if os(iOS)
            NotificationCenter.default.removeObserver(self)
#endif
            self.running = false
        }
    }
}

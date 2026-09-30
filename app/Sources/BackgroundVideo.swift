import SwiftUI
import AppKit
import AVFoundation
import CoreImage

/// Background video for the dashboard: a green-screen clip played looped and muted, with the green
/// keyed to the app's navy through a Core Image colour cube (no alpha needed). The clip is not
/// downloaded by the app; the user places it at video/atrain.mp4 and build.sh bundles it.
enum BackgroundVideo {
    static let bundledName = "atrain"
    static let devPath = NSHomeDirectory() + "/vpn-split/app/video/atrain.mp4"
    /// The Mining Meteor clip opens with ~3.5 s of empty green and a white flash; start after it.
    static let introSkipSeconds = 3.6

    static var url: URL? {
        if let u = Bundle.main.url(forResource: bundledName, withExtension: "mp4") { return u }
        return FileManager.default.fileExists(atPath: devPath) ? URL(fileURLWithPath: devPath) : nil
    }

    /// Colour cube that maps chroma-key green to `fill` (opaque), everything else unchanged.
    static func greenKeyFilter(fill: (r: Float, g: Float, b: Float)) -> CIFilter? {
        let size = 64
        var cube = [Float](repeating: 0, count: size * size * size * 4)
        var i = 0
        for z in 0..<size {          // blue
            let b = Float(z) / Float(size - 1)
            for y in 0..<size {      // green
                let g = Float(y) / Float(size - 1)
                for x in 0..<size {  // red
                    let r = Float(x) / Float(size - 1)
                    let (h, s, v) = hsv(r, g, b)
                    // green screen: hue roughly 75..165 degrees, reasonably saturated and not too dark
                    let isGreen = h >= 75 && h <= 165 && s >= 0.30 && v >= 0.18
                    if isGreen {
                        cube[i] = fill.r; cube[i + 1] = fill.g; cube[i + 2] = fill.b; cube[i + 3] = 1
                    } else {
                        cube[i] = r; cube[i + 1] = g; cube[i + 2] = b; cube[i + 3] = 1
                    }
                    i += 4
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        // apply the cube in sRGB so the hue test and the fill colour mean what they say on screen
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(size, forKey: "inputCubeDimension")
        f.setValue(data, forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        return f
    }

    private static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
            if h < 0 { h += 360 }
        }
        let s: Float = mx == 0 ? 0 : d / mx
        return (h, s, mx)
    }
}

final class VideoBackdropView: NSView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.024, green: 0.102, blue: 0.310, alpha: 1).cgColor
        playerLayer.videoGravity = .resizeAspect      // show the whole frame; never crop the character away
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        playerLayer.frame = bounds
    }

    func load(_ url: URL) {
        let asset = AVURLAsset(url: url)
        // The composition must be built after the tracks are known, or it renders nothing.
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
            DispatchQueue.main.async { self?.start(asset) }
        }
    }

    private func start(_ asset: AVURLAsset) {
        let item = AVPlayerItem(asset: asset)
        let natural = asset.tracks(withMediaType: .video).first?.naturalSize ?? CGSize(width: 1280, height: 720)
        let bypass = ProcessInfo.processInfo.environment["ATRAIN_NOKEY"] == "1"   // debugging aid
        if !bypass, let key = BackgroundVideo.greenKeyFilter(fill: (0.024, 0.102, 0.310)) {
            // after keying, lift the footage a little so it reads through the UI tint
            let boost = CIFilter(name: "CIColorControls")
            boost?.setValue(1.22, forKey: kCIInputContrastKey)
            boost?.setValue(0.08, forKey: kCIInputBrightnessKey)
            boost?.setValue(1.25, forKey: kCIInputSaturationKey)
            let comp = AVMutableVideoComposition(asset: asset) { request in
                key.setValue(request.sourceImage, forKey: kCIInputImageKey)
                var out = key.outputImage ?? request.sourceImage
                if let b = boost { b.setValue(out, forKey: kCIInputImageKey); out = b.outputImage ?? out }
                request.finish(with: out, context: nil)
            }
            // render at most 1280 wide: sharp enough behind the UI, cheap on the GPU
            let scale = min(1, 1280 / max(natural.width, 1))
            comp.renderSize = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
            item.videoComposition = comp
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.actionAtItemEnd = .none
        // loop only the part with footage: skip an empty green intro / flash if the clip has one
        let skip = CMTime(seconds: BackgroundVideo.introSkipSeconds, preferredTimescale: 600)
        let total = asset.duration
        if CMTimeCompare(total, CMTimeAdd(skip, CMTime(seconds: 2, preferredTimescale: 600))) > 0 {
            looper = AVPlayerLooper(player: queue, templateItem: item, timeRange: CMTimeRange(start: skip, end: total))
        } else {
            looper = AVPlayerLooper(player: queue, templateItem: item)
        }
        playerLayer.player = queue
        player = queue
        queue.play()
    }

    func setPaused(_ paused: Bool) {
        paused ? player?.pause() : player?.play()
    }

    deinit { player?.pause() }
}

struct BackgroundVideoView: NSViewRepresentable {
    let url: URL
    var paused: Bool = false

    func makeNSView(context: Context) -> VideoBackdropView {
        let v = VideoBackdropView(frame: .zero)
        v.load(url)
        return v
    }

    func updateNSView(_ v: VideoBackdropView, context: Context) {
        v.setPaused(paused)
    }
}

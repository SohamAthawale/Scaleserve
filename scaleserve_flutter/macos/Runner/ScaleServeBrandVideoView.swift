import AVKit
import Cocoa
import FlutterMacOS

final class ScaleServeBrandVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let registrar: FlutterPluginRegistrar

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    return ScaleServeBrandVideoView(registrar: registrar, arguments: args)
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class ScaleServeBrandVideoView: NSView {
  private let playerView = AVPlayerView()
  private var player: AVPlayer?
  private var loopObserver: NSObjectProtocol?

  init(registrar: FlutterPluginRegistrar, arguments: Any?) {
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor

    playerView.controlsStyle = .none
    playerView.showsFullScreenToggleButton = false
    playerView.autoresizingMask = [.width, .height]
    playerView.frame = bounds
    addSubview(playerView)

    let params = arguments as? [String: Any]
    let asset = params?["asset"] as? String ?? ""
    let gravity = (params?["gravity"] as? String) == "fit"
      ? AVLayerVideoGravity.resizeAspect
      : AVLayerVideoGravity.resizeAspectFill

    playerView.videoGravity = gravity

    guard let url = Self.assetURL(for: asset, registrar: registrar) else {
      return
    }

    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.actionAtItemEnd = .none
    player.play()

    loopObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak player] _ in
      player?.seek(to: .zero)
      player?.play()
    }

    self.player = player
    playerView.player = player
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    if let loopObserver {
      NotificationCenter.default.removeObserver(loopObserver)
    }
    player?.pause()
  }

  override func layout() {
    super.layout()
    playerView.frame = bounds
  }

  private static func assetURL(
    for asset: String,
    registrar: FlutterPluginRegistrar
  ) -> URL? {
    let assetKey = registrar.lookupKey(forAsset: asset)
    let nsAssetKey = assetKey as NSString

    if let resourceURL = Bundle.main.url(
      forResource: nsAssetKey.deletingPathExtension,
      withExtension: nsAssetKey.pathExtension
    ) {
      return resourceURL
    }

    return URL(string: assetKey, relativeTo: Bundle.main.bundleURL)
  }
}

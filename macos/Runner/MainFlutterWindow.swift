import AVFoundation
import Accelerate
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    var windowFrame = self.frame
    // Decks need room: open large, but never bigger than the screen.
    if let screen = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
      windowFrame.size = NSSize(width: min(1600, screen.width), height: min(1000, screen.height))
      windowFrame.origin = NSPoint(x: screen.midX - windowFrame.width / 2, y: screen.midY - windowFrame.height / 2)
    }
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // The top bar and switches need this much room to show in full.
    self.contentMinSize = NSSize(width: 800, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MixerChannel.shared.attach(to: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

import ExpoModulesCore

public class LidarScannerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LidarScanner")

    View(LidarScannerView.self) {
      Prop("isScanning") { (view: LidarScannerView, isScanning: Bool) in
        if isScanning {
          view.startScanning()
        } else {
          view.stopScanning()
        }
      }
    }
  }
}

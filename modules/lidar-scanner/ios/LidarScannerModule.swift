import ExpoModulesCore

public class LidarScannerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LidarScanner")

    View(LidarScannerView.self) {
      Events("onFrameCaptured", "onError")
      
      Prop("isScanning") { (view: LidarScannerView, isScanning: Bool) in
        if isScanning {
          view.startScanning()
        } else {
          view.stopScanning()
        }
      }
    }

    AsyncFunction("clearData") {
      let fileManager = FileManager.default
      guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
      
      do {
        let items = try fileManager.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: nil)
        for item in items {
          if item.lastPathComponent.starts(with: "Scan_") {
            try fileManager.removeItem(at: item)
          }
        }
      } catch {
        print("Error clearing data: \(error)")
      }
    }
  }
}

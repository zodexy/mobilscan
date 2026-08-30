import ExpoModulesCore
import ARKit
import SceneKit

class LidarScannerView: ExpoView, ARSessionDelegate, ARSCNViewDelegate {
  let arView = ARSCNView(frame: .zero)
  var isScanning = false
  
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    
    arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    arView.delegate = self
    arView.session.delegate = self
    
    // Built-in debug option to show the LiDAR feature points (point cloud)
    // Note: showSceneUnderstanding is only available in RealityKit (ARView), not SceneKit (ARSCNView).
    arView.debugOptions = [.showFeaturePoints]
    
    addSubview(arView)
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    arView.frame = bounds
  }
  
  func startScanning() {
    guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
        print("LiDAR is not supported on this device.")
        return
    }
    
    let config = ARWorldTrackingConfiguration()
    config.sceneReconstruction = .mesh
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
        config.frameSemantics = .sceneDepth
    }
    
    arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    isScanning = true
  }
  
  func stopScanning() {
    arView.session.pause()
    isScanning = false
  }
}

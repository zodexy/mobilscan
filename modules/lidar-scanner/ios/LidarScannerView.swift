import ExpoModulesCore
import ARKit
import SceneKit
import CoreImage
import UIKit

extension SCNGeometry {
    convenience init?(from meshGeometry: ARMeshGeometry) {
        let vertices = meshGeometry.vertices
        let normals = meshGeometry.normals
        let faces = meshGeometry.faces
        
        let vertexSource = SCNGeometrySource(buffer: vertices.buffer, vertexFormat: vertices.format, semantic: .vertex, vertexCount: vertices.count, dataOffset: vertices.offset, dataStride: vertices.stride)
        let normalSource = SCNGeometrySource(buffer: normals.buffer, vertexFormat: normals.format, semantic: .normal, vertexCount: normals.count, dataOffset: normals.offset, dataStride: normals.stride)
        let geometryElement = SCNGeometryElement(buffer: faces.buffer, primitiveType: .triangles, primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        
        self.init(sources: [vertexSource, normalSource], elements: [geometryElement])
    }
}

class LidarScannerView: ExpoView, ARSessionDelegate, ARSCNViewDelegate {
    let arView = ARSCNView(frame: .zero)
    var isScanning = false
    
    var lastCaptureTime: TimeInterval = 0
    let captureInterval: TimeInterval = 1.0 / 5.0 // 5 FPS
    
    var scanDir: URL?
    var transformsData: [[String: Any]] = []
    var frameIndex = 0
    let savingQueue = DispatchQueue(label: "com.mobilscan.savingQueue")
    
    // CoreImage context for converting CVPixelBuffer to JPEG
    let ciContext = CIContext()
    
    let onFrameCaptured = EventDispatcher()
    let onError = EventDispatcher()
    
    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.delegate = self
        arView.session.delegate = self
        
        // Disable feature points, we will draw the blue mesh instead
        arView.debugOptions = []
        
        addSubview(arView)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
    }
    
    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("LiDAR is not supported on this device.")
            onError([
                "message": "A készüléked nem támogatja a LiDAR szkennelést."
            ])
            return
        }
        
        setupDirectories()
        
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
        }
        
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        lastCaptureTime = 0
        
        // Késleltetve (hogy az ARKit már bekapcsolja a kamerát) átállítjuk a záridőt "Sport" módra!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTripleCamera, .builtInDualCamera, .builtInLiDARDepthCamera],
                mediaType: .video,
                position: .back
            )
            for device in discoverySession.devices {
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.custom) {
                        // 1/120 másodperc tökéletes kompromisszum: szinte nulla motion blur, de még kap elég fényt
                        let duration = CMTimeMake(value: 1, timescale: 120)
                        let iso = min(device.activeFormat.maxISO, 800) // Magasabb ISO, hogy ne legyen túl sötét
                        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                        print("Kamera záridő sikeresen beállítva: 1/120s a(z) \(device.localizedName) eszközön")
                    }
                    device.unlockForConfiguration()
                } catch {
                    print("Nem sikerült zárolni a kamerát: \(error)")
                }
            }
        }
    }
    
    func stopScanning() {
        arView.session.pause()
        isScanning = false
        
        let currentAnchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let currentScanDir = scanDir
        let currentTransforms = transformsData
        
        savingQueue.async {
            if let scanDir = currentScanDir {
                // Save transforms.json
                let jsonDict: [String: Any] = ["frames": currentTransforms]
                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted) {
                    let jsonUrl = scanDir.appendingPathComponent("transforms.json")
                    try? jsonData.write(to: jsonUrl)
                }
                
                // Save Lidar Mesh as OBJ for RealityCapture
                self.exportMeshAsOBJ(anchors: currentAnchors, to: scanDir.appendingPathComponent("lidar_mesh.obj"))
            }
        }
    }
    
    private func exportMeshAsOBJ(anchors: [ARMeshAnchor], to url: URL) {
        var lines: [String] = []
        // Optional pre-allocation to speed things up
        lines.reserveCapacity(anchors.count * 10000)
        
        var vertexOffset = 1
        
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            
            let vertices = geometry.vertices
            for i in 0..<vertices.count {
                let vertexPointer = vertices.buffer.contents.advanced(by: vertices.offset + (vertices.stride * i))
                let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                
                // Transform vertex to world space
                let worldVertex = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                lines.append("v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)")
            }
            
            let faces = geometry.faces
            for i in 0..<faces.count {
                let facePointer = faces.buffer.contents.advanced(by: faces.offset + (faces.stride * i))
                
                if faces.bytesPerIndex == 2 {
                    let indices = facePointer.assumingMemoryBound(to: Int16.self)
                    let v1 = Int(indices[0]) + vertexOffset
                    let v2 = Int(indices[1]) + vertexOffset
                    let v3 = Int(indices[2]) + vertexOffset
                    lines.append("f \(v1) \(v2) \(v3)")
                } else if faces.bytesPerIndex == 4 {
                    let indices = facePointer.assumingMemoryBound(to: Int32.self)
                    let v1 = Int(indices[0]) + vertexOffset
                    let v2 = Int(indices[1]) + vertexOffset
                    let v3 = Int(indices[2]) + vertexOffset
                    lines.append("f \(v1) \(v2) \(v3)")
                }
            }
            
            vertexOffset += vertices.count
        }
        
        let objText = lines.joined(separator: "\n")
        try? objText.write(to: url, atomically: true, encoding: .utf8)
    }
    
    func setupDirectories() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        scanDir = documentDirectory.appendingPathComponent("Scan_\(dateStr)", isDirectory: true)
        
        guard let scanDir = scanDir else { return }
        
        let imagesDir = scanDir.appendingPathComponent("images", isDirectory: true)
        let depthDir = scanDir.appendingPathComponent("depth", isDirectory: true)
        
        do {
            try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: depthDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating directories: \(error)")
        }
        
        transformsData.removeAll()
        frameIndex = 0
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }
        
        let currentTime = frame.timestamp
        if currentTime - lastCaptureTime >= captureInterval {
            lastCaptureTime = currentTime
            captureData(from: frame)
        }
    }
    
    func captureData(from frame: ARFrame) {
        guard let scanDir = scanDir else { return }
        
        let currentIndex = frameIndex
        frameIndex += 1
        
        // Fire event to React Native
        onFrameCaptured([
            "frameCount": currentIndex
        ])
        
        // We must copy data we want to process in the background
        let pixelBuffer = frame.capturedImage
        let depthBuffer = frame.sceneDepth?.depthMap
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        
        // Convert SIMD matrices to nested arrays for JSON
        let transformArray = [
            [transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w],
            [transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w],
            [transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w],
            [transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w]
        ]
        
        let intrinsicsArray = [
            [intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z],
            [intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z],
            [intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z]
        ]
        
        let imageName = String(format: "%04d.jpg", currentIndex)
        let depthName = String(format: "%04d.bin", currentIndex)
        
        var frameDict: [String: Any] = [
            "file_path": "images/\(imageName)",
            "transform_matrix": transformArray,
            "intrinsics_matrix": intrinsicsArray
        ]
        
        if depthBuffer != nil {
            frameDict["depth_path"] = "depth/\(depthName)"
        }
        
        transformsData.append(frameDict)
        
        let imagesDir = scanDir.appendingPathComponent("images")
        let depthDir = scanDir.appendingPathComponent("depth")
        let imageUrl = imagesDir.appendingPathComponent(imageName)
        let depthUrl = depthDir.appendingPathComponent(depthName)
        
        // Convert to CIImage immediately on the AR thread
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Create CGImage synchronously so the pixel buffer is no longer needed by the background thread
        let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
        
        // Extract depth data synchronously
        var depthData: Data? = nil
        if let db = depthBuffer {
            CVPixelBufferLockBaseAddress(db, .readOnly)
            let height = CVPixelBufferGetHeight(db)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(db)
            if let baseAddress = CVPixelBufferGetBaseAddress(db) {
                depthData = Data(bytes: baseAddress, count: height * bytesPerRow)
            }
            CVPixelBufferUnlockBaseAddress(db, .readOnly)
        }
        
        savingQueue.async {
            // Save Image using UIKit
            if let cgImg = cgImage {
                let uiImage = UIImage(cgImage: cgImg)
                if let jpegData = uiImage.jpegData(compressionQuality: 0.9) {
                    try? jpegData.write(to: imageUrl)
                }
            }
            
            // Save Depth Map
            if let data = depthData {
                try? data.write(to: depthUrl)
            }
        }
    }
    
    // MARK: - ARSCNViewDelegate
    
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        guard let geometry = SCNGeometry(from: meshAnchor.geometry) else { return nil }
        
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.5)
        material.isDoubleSided = true
        material.fillMode = .lines // Wireframe looks very cool for LiDAR meshes
        
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        guard let geometry = SCNGeometry(from: meshAnchor.geometry) else { return }
        
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.5)
        material.isDoubleSided = true
        material.fillMode = .lines
        
        geometry.firstMaterial = material
        node.geometry = geometry
    }
}

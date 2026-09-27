import Foundation
import AVFoundation
import CoreMedia
import ExpoModulesCore
import ARKit
import SceneKit
import CoreImage
import UIKit
import Metal

struct VoxelKey: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

class ColorGrid {
    let gridSize: Float = 0.02 // 2cm voxels for color retention
    var grid: [VoxelKey: SIMD3<Float>] = [:]
    
    func key(for position: SIMD3<Float>) -> VoxelKey {
        return VoxelKey(
            x: Int(round(position.x / gridSize)),
            y: Int(round(position.y / gridSize)),
            z: Int(round(position.z / gridSize))
        )
    }
    
    func paint(at position: SIMD3<Float>, r: UInt8, g: UInt8, b: UInt8) -> SIMD3<UInt8> {
        let key = self.key(for: position)
        if let existing = grid[key] {
            // Move 30% towards new color for a smooth spray-paint effect
            let newR = existing.x * 0.7 + Float(r) * 0.3
            let newG = existing.y * 0.7 + Float(g) * 0.3
            let newB = existing.z * 0.7 + Float(b) * 0.3
            let newColor = SIMD3<Float>(newR, newG, newB)
            grid[key] = newColor
            return SIMD3<UInt8>(UInt8(newR), UInt8(newG), UInt8(newB))
        } else {
            // First time seeing this voxel: start 50% between gray and the true color
            let newR = 150.0 * 0.5 + Float(r) * 0.5
            let newG = 150.0 * 0.5 + Float(g) * 0.5
            let newB = 150.0 * 0.5 + Float(b) * 0.5
            let newColor = SIMD3<Float>(newR, newG, newB)
            grid[key] = newColor
            return SIMD3<UInt8>(UInt8(newR), UInt8(newG), UInt8(newB))
        }
    }
    
    func getColor(at position: SIMD3<Float>) -> SIMD3<UInt8>? {
        if let c = grid[key(for: position)] {
            return SIMD3<UInt8>(UInt8(c.x), UInt8(c.y), UInt8(c.z))
        }
        return nil
    }
}
extension SCNGeometry {
    convenience init?(from meshGeometry: ARMeshGeometry, nodeTransform: simd_float4x4? = nil, camera: ARCamera? = nil, rgbData: Data? = nil, rgbWidth: Int = 0, rgbHeight: Int = 0, colorGrid: ColorGrid? = nil) {
        let vertices = meshGeometry.vertices
        let normals = meshGeometry.normals
        let faces = meshGeometry.faces
        
        let vertexSource = SCNGeometrySource(buffer: vertices.buffer, vertexFormat: vertices.format, semantic: .vertex, vertexCount: vertices.count, dataOffset: vertices.offset, dataStride: vertices.stride)
        let normalSource = SCNGeometrySource(buffer: normals.buffer, vertexFormat: normals.format, semantic: .normal, vertexCount: normals.count, dataOffset: normals.offset, dataStride: normals.stride)
        let geometryElement = SCNGeometryElement(buffer: faces.buffer, primitiveType: .triangles, primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        
        var sources = [vertexSource, normalSource]
        
        if let transform = nodeTransform, let cam = camera, let data = rgbData, rgbWidth > 0, rgbHeight > 0 {
            var colorData = Data(capacity: vertices.count * 4)
            let viewMat = cam.viewMatrix(for: .landscapeRight)
            let projMat = cam.projectionMatrix(for: .landscapeRight, viewportSize: CGSize(width: rgbWidth, height: rgbHeight), zNear: 0.001, zFar: 1000)
            let viewProj = projMat * viewMat
            
            let bytes = [UInt8](data)
            
            for i in 0..<vertices.count {
                var r: UInt8 = 150
                var g: UInt8 = 150
                var b: UInt8 = 150
                var a: UInt8 = 200 // Semi-transparent gray for unpainted (hides sharp camera!)
                
                let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * i))
                let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldVertex = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let worldPos = SIMD3<Float>(worldVertex.x, worldVertex.y, worldVertex.z)
                
                var coloredFromCamera = false
                
                let clip = viewProj * worldVertex
                if clip.w > 0 {
                    let ndcX = clip.x / clip.w
                    let ndcY = clip.y / clip.w
                    let u = (ndcX * 0.5) + 0.5
                    let v = 1.0 - ((ndcY * 0.5) + 0.5)
                    
                    let px = Int(u * Float(rgbWidth))
                    let py = Int(v * Float(rgbHeight))
                    
                    if px >= 0 && px < rgbWidth && py >= 0 && py < rgbHeight {
                        let offset = (py * rgbWidth + px) * 4
                        if offset + 2 < bytes.count {
                            if let grid = colorGrid {
                                let newColor = grid.paint(at: worldPos, r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2])
                                r = newColor.x
                                g = newColor.y
                                b = newColor.z
                                a = 255
                                coloredFromCamera = true
                            }
                        }
                    }
                }
                
                if !coloredFromCamera, let grid = colorGrid {
                    if let savedColor = grid.getColor(at: worldPos) {
                        r = savedColor.x
                        g = savedColor.y
                        b = savedColor.z
                        a = 255
                    }
                }
                
                colorData.append(r)
                colorData.append(g)
                colorData.append(b)
                colorData.append(a)
            }
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: vertices.count, usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 1, dataOffset: 0, dataStride: 4)
            sources.append(colorSource)
        }
        
        self.init(sources: sources, elements: [geometryElement])
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
    var cameraResolution: CGSize = .zero
    var cameraIntrinsics: simd_float3x3 = matrix_identity_float3x3
    let savingQueue = DispatchQueue(label: "com.mobilscan.savingQueue")
    
    // CoreImage context for converting CVPixelBuffer to JPEG
    let ciContext = CIContext()
    
    // State for live colorization
    var latestRGBData: Data?
    var latestRGBWidth: Int = 0
    var latestRGBHeight: Int = 0
    var latestCamera: ARCamera?
    let colorGrid = ColorGrid()
    
    let onFrameCaptured = EventDispatcher()
    let onError = EventDispatcher()
    
    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.delegate = self
        arView.session.delegate = self
        
        // Disable feature points, we will draw the mesh
        arView.debugOptions = []
        
        addSubview(arView)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
    }
    
    func startScanning() {
        if isScanning { return }
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
        colorGrid.grid.removeAll()
        
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
                        let iso = min(device.activeFormat.maxISO, 800.0) // Magasabb ISO, hogy ne legyen túl sötét
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
        if !isScanning { return }
        isScanning = false
        let currentAnchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        arView.session.pause()
        
        let currentScanDir = scanDir
        let currentTransforms = transformsData
        
        savingQueue.async {
            if let scanDir = currentScanDir {
                let fl_x = self.cameraIntrinsics.columns.0.x
                let fl_y = self.cameraIntrinsics.columns.1.y
                let cx = self.cameraIntrinsics.columns.2.x
                let cy = self.cameraIntrinsics.columns.2.y
                let w = self.cameraResolution.width
                let h = self.cameraResolution.height
                
                // Save transforms.json
                let jsonDict: [String: Any] = [
                    "camera_model": "OPENCV",
                    "w": w,
                    "h": h,
                    "fl_x": fl_x,
                    "fl_y": fl_y,
                    "cx": cx,
                    "cy": cy,
                    "frames": currentTransforms
                ]
                
                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: .prettyPrinted) {
                    let jsonUrl = scanDir.appendingPathComponent("transforms.json")
                    try? jsonData.write(to: jsonUrl)
                }
                
                // Save Lidar Mesh as PLY for 2DGS/3DGS initialization
                self.exportMeshAsPLY(anchors: currentAnchors, to: scanDir.appendingPathComponent("sparse_pc.ply"))
            }
        }
    }
    
    private func exportMeshAsPLY(anchors: [ARMeshAnchor], to url: URL) {
        guard let outputStream = OutputStream(url: url, append: false) else { return }
        outputStream.open()
        defer { outputStream.close() }
        
        var totalVertices = 0
        for anchor in anchors {
            totalVertices += anchor.geometry.vertices.count
        }
        
        let header = """
        ply
        format ascii 1.0
        element vertex \(totalVertices)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        property uchar red
        property uchar green
        property uchar blue
        end_header\n
        """
        
        if let headerData = header.data(using: .utf8) {
            let bytes = [UInt8](headerData)
            bytes.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    _ = outputStream.write(baseAddress, maxLength: bytes.count)
                }
            }
        }
        
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let vertices = geometry.vertices
            let normals = geometry.normals
            
            for i in 0..<vertices.count {
                let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * i))
                let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                
                // Transform vertex to world space
                let worldVertex = transform * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                
                let normalPointer = normals.buffer.contents().advanced(by: normals.offset + (normals.stride * i))
                let normal = normalPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                
                // Transform normal to world space
                let normal4 = transform * SIMD4<Float>(normal.x, normal.y, normal.z, 0.0)
                let worldNormal = simd_normalize(SIMD3<Float>(normal4.x, normal4.y, normal4.z))
                
                let line = "\(worldVertex.x) \(worldVertex.y) \(worldVertex.z) \(worldNormal.x) \(worldNormal.y) \(worldNormal.z) 128 128 128\n"
                if let lineData = line.data(using: .utf8) {
                    let bytes = [UInt8](lineData)
                    bytes.withUnsafeBufferPointer { buffer in
                        if let baseAddress = buffer.baseAddress {
                            _ = outputStream.write(baseAddress, maxLength: bytes.count)
                        }
                    }
                }
            }
        }
    }
    
    func setupDirectories() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        scanDir = documentDirectory.appendingPathComponent("Scan_\\(dateStr)", isDirectory: true)
        
        guard let scanDir = scanDir else { return }
        
        let imagesDir = scanDir.appendingPathComponent("images", isDirectory: true)
        
        do {
            try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating directories: \\(error)")
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
        
        let pixelBuffer = frame.capturedImage
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        
        if currentIndex == 0 {
            cameraIntrinsics = intrinsics
            cameraResolution = frame.camera.imageResolution
        }
        
        // Convert SIMD matrices to row-major nested arrays for JSON (Nerfstudio format)
        let transformArray = [
            [transform.columns.0.x, transform.columns.1.x, transform.columns.2.x, transform.columns.3.x],
            [transform.columns.0.y, transform.columns.1.y, transform.columns.2.y, transform.columns.3.y],
            [transform.columns.0.z, transform.columns.1.z, transform.columns.2.z, transform.columns.3.z],
            [transform.columns.0.w, transform.columns.1.w, transform.columns.2.w, transform.columns.3.w]
        ]
        
        let imageName = String(format: "%04d.jpg", currentIndex)
        
        let frameDict: [String: Any] = [
            "file_path": "images/\\(imageName)",
            "transform_matrix": transformArray
        ]
        
        transformsData.append(frameDict)
        
        let imagesDir = scanDir.appendingPathComponent("images")
        let imageUrl = imagesDir.appendingPathComponent(imageName)
        
        // Convert to CIImage immediately on the AR thread
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Create CGImage synchronously so the pixel buffer is no longer needed by the background thread
        let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
        
        // Setup live colorization data (low-res)
        let scale = 120.0 / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        let scaledCI = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        let width = Int(scaledCI.extent.width)
        let height = Int(scaledCI.extent.height)
        
        if width > 0 && height > 0 {
            var rawData = [UInt8](repeating: 0, count: width * height * 4)
            if let cgContext = CGContext(data: &rawData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                if let smallCgImg = self.ciContext.createCGImage(scaledCI, from: scaledCI.extent) {
                    cgContext.draw(smallCgImg, in: CGRect(x: 0, y: 0, width: width, height: height))
                    self.latestRGBWidth = width
                    self.latestRGBHeight = height
                    self.latestCamera = frame.camera
                    self.latestRGBData = Data(rawData)
                }
            }
        }
        
        savingQueue.async {
            // Save Image using UIKit
            if let cgImg = cgImage {
                let uiImage = UIImage(cgImage: cgImg)
                if let jpegData = uiImage.jpegData(compressionQuality: 0.9) {
                    try? jpegData.write(to: imageUrl)
                }
            }
        }
    }
    
    // MARK: - ARSCNViewDelegate
    
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        guard let geometry = SCNGeometry(from: meshAnchor.geometry, nodeTransform: meshAnchor.transform, camera: latestCamera, rgbData: latestRGBData, rgbWidth: latestRGBWidth, rgbHeight: latestRGBHeight, colorGrid: colorGrid) else { return nil }
        
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant // No shading, pure color like 3DGS!
        material.transparencyMode = .dualLayer
        
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        guard let geometry = SCNGeometry(from: meshAnchor.geometry, nodeTransform: meshAnchor.transform, camera: latestCamera, rgbData: latestRGBData, rgbWidth: latestRGBWidth, rgbHeight: latestRGBHeight, colorGrid: colorGrid) else { return }
        
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant // No shading, pure color like 3DGS!
        material.transparencyMode = .dualLayer
        
        geometry.firstMaterial = material
        node.geometry = geometry
    }
}

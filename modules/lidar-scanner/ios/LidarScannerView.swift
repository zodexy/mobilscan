import Foundation
import AVFoundation
import CoreMedia
import ExpoModulesCore
import ARKit
import SceneKit
import CoreImage
import UIKit
import Metal
import ImageIO

struct VoxelKey: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

struct VoxelData {
    let pos: SIMD3<Float>
    var color: SIMD3<Float>
}

class ColorGrid {
    let gridSize: Float = 0.02 // 2cm voxels
    var grid: [VoxelKey: VoxelData] = [:]
    
    func key(for position: SIMD3<Float>) -> VoxelKey {
        return VoxelKey(
            x: Int(round(position.x / gridSize)),
            y: Int(round(position.y / gridSize)),
            z: Int(round(position.z / gridSize))
        )
    }
    
    func addPoint(pos: SIMD3<Float>, r: UInt8, g: UInt8, b: UInt8) -> Bool {
        let key = self.key(for: pos)
        if grid[key] == nil {
            grid[key] = VoxelData(pos: pos, color: SIMD3<Float>(Float(r), Float(g), Float(b)))
            return true
        } else {
            // Blend color slightly
            var existing = grid[key]!
            let newR = existing.color.x * 0.8 + Float(r) * 0.2
            let newG = existing.color.y * 0.8 + Float(g) * 0.2
            let newB = existing.color.z * 0.8 + Float(b) * 0.2
            existing.color = SIMD3<Float>(newR, newG, newB)
            grid[key] = existing
            return false
        }
    }
}

class LidarScannerView: ExpoView, ARSessionDelegate, ARSCNViewDelegate {
    let arView = ARSCNView(frame: .zero)
    var isScanning = false
    var overlayNode: SCNNode?
    var pointCloudNode: SCNNode?
    
    var lastSavedCameraTransform: simd_float4x4?
    
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
        
        setupDirectories()
        
        // LiDAR is optional now! We will fallback to rawFeaturePoints if no LiDAR.
        let config = ARWorldTrackingConfiguration()
        
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics = .sceneDepth
            }
        }
        
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        lastSavedCameraTransform = nil
        colorGrid.grid.removeAll()
        
        // E02: Kamera indításának naplózása
        print("ARKit session elindítva.")
    }
    
    func stopScanning() {
        if !isScanning { return }
        isScanning = false
        
        overlayNode?.removeFromParentNode()
        overlayNode = nil
        pointCloudNode?.removeFromParentNode()
        pointCloudNode = nil
        
        arView.session.pause()
        
        let currentScanDir = scanDir
        let currentTransforms = transformsData
        let savedGrid = Array(colorGrid.grid.values)
        
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
                
                // Save Lidar Point Cloud as PLY for 2DGS/3DGS initialization
                self.exportMeshAsPLY(points: savedGrid, to: scanDir.appendingPathComponent("sparse_pc.ply"))
            }
        }
    }
    
    private func exportMeshAsPLY(points: [VoxelData], to url: URL) {
        guard let outputStream = OutputStream(url: url, append: false) else { return }
        outputStream.open()
        defer { outputStream.close() }
        
        let header = """
        ply
        format ascii 1.0
        element vertex \(points.count)
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
        
        for p in points {
            // Using a default up normal for now, but 2DGS will optimize it
            let line = "\(p.pos.x) \(p.pos.y) \(p.pos.z) 0.0 1.0 0.0 \(Int(p.color.x)) \(Int(p.color.y)) \(Int(p.color.z))\n"
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
        let confDir = scanDir.appendingPathComponent("confidence", isDirectory: true)
        
        do {
            try fileManager.createDirectory(at: scanDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: depthDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: confDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Error creating directories: \\(error)")
        }
        
        transformsData.removeAll()
        frameIndex = 0
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }
        
        if overlayNode == nil, let cameraNode = arView.pointOfView {
            setupOverlayNode(on: cameraNode)
        }
        
        let currentTransform = frame.camera.transform
        var shouldCapture = false
        
        if let last = lastSavedCameraTransform {
            let dx = currentTransform.columns.3.x - last.columns.3.x
            let dy = currentTransform.columns.3.y - last.columns.3.y
            let dz = currentTransform.columns.3.z - last.columns.3.z
            let distance = sqrt(dx*dx + dy*dy + dz*dz)
            
            let f1 = SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
            let f2 = SIMD3<Float>(currentTransform.columns.2.x, currentTransform.columns.2.y, currentTransform.columns.2.z)
            let dot = simd_dot(simd_normalize(f1), simd_normalize(f2))
            let angle = acos(min(max(dot, -1.0), 1.0)) * Float(180.0) / Float.pi
            
            if distance > 0.12 || angle > 12.0 { // 12cm or 12 degrees
                shouldCapture = true
            }
        } else {
            shouldCapture = true
        }
        
        if shouldCapture {
            lastSavedCameraTransform = currentTransform
            captureData(from: frame)
        }
    }
    
    private func setupOverlayNode(on cameraNode: SCNNode) {
        let plane = SCNPlane(width: 50, height: 50)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.15, alpha: 0.85) // Dark grey overlay to dim the real world
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.firstMaterial = material
        
        let node = SCNNode(geometry: plane)
        node.renderingOrder = -1 // Render before everything else
        node.position = SCNVector3(0, 0, -1) // 1 meter in front of the camera
        
        cameraNode.addChildNode(node)
        self.overlayNode = node
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
        let depthName = String(format: "%04d.png", currentIndex)
        let confName = String(format: "%04d.png", currentIndex)
        
        var frameDict: [String: Any] = [
            "file_path": "images/\(imageName)",
            "transform_matrix": transformArray,
            "timestamp": frame.timestamp
        ]
        
        var depthDataArray: [UInt16]? = nil
        var depthW = 0
        var depthH = 0
        var confCgImage: CGImage? = nil
        
        if #available(iOS 14.0, *) {
            if let sceneDepth = frame.sceneDepth {
                frameDict["depth_file_path"] = "depth/\(depthName)"
                frameDict["confidence_file_path"] = "confidence/\(confName)"
                
                // Extract depth as 16-bit array synchronously
                let dBuffer = sceneDepth.depthMap
                CVPixelBufferLockBaseAddress(dBuffer, .readOnly)
                depthW = CVPixelBufferGetWidth(dBuffer)
                depthH = CVPixelBufferGetHeight(dBuffer)
                if let baseAddress = CVPixelBufferGetBaseAddress(dBuffer) {
                    let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
                    var localArray = [UInt16](repeating: 0, count: depthW * depthH)
                    for i in 0..<(depthW * depthH) {
                        let meters = floatBuffer[i]
                        let mm = meters * Float(1000.0)
                        localArray[i] = mm.isNaN ? 0 : UInt16(min(max(mm, Float(0.0)), Float(65535.0)))
                    }
                    depthDataArray = localArray
                }
                CVPixelBufferUnlockBaseAddress(dBuffer, .readOnly)
                
                // Extract confidence as CGImage
                if let cBuffer = sceneDepth.confidenceMap {
                    let ci = CIImage(cvPixelBuffer: cBuffer)
                    confCgImage = ciContext.createCGImage(ci, from: ci.extent)
                }
            }
        }
        
        transformsData.append(frameDict)
        
        let imagesDir = scanDir.appendingPathComponent("images")
        let imageUrl = imagesDir.appendingPathComponent(imageName)
        let depthUrl = scanDir.appendingPathComponent("depth").appendingPathComponent(depthName)
        let confUrl = scanDir.appendingPathComponent("confidence").appendingPathComponent(confName)
        
        // Convert to CIImage immediately on the AR thread
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Create CGImage synchronously so the pixel buffer is no longer needed by the background thread
        let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
        
        // Setup live colorization data (low-res)
        let scale = CGFloat(120.0) / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
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
            
            // Save depth PNG
            if let mmData = depthDataArray {
                let data = mmData.withUnsafeBytes { Data($0) }
                if let provider = CGDataProvider(data: data as CFData),
                   let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
                   let dCgImg = CGImage(width: depthW, height: depthH, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: depthW * 2, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                    
                    if let destination = CGImageDestinationCreateWithURL(depthUrl as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, dCgImg, nil)
                        CGImageDestinationFinalize(destination)
                    }
                }
            }
            
            // Save confidence PNG
            if let cCgImg = confCgImage {
                if let destination = CGImageDestinationCreateWithURL(confUrl as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, cCgImg, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
        }
        
        // Extract dense point cloud for Live Preview!
        extractPointCloud(from: frame)
    }
    
    private func extractPointCloud(from frame: ARFrame) {
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let imageResolution = frame.camera.imageResolution
        
        guard let rgbData = latestRGBData, latestRGBWidth > 0, latestRGBHeight > 0 else { return }
        let rgbBytes = [UInt8](rgbData)
        
        var newPoints = false
        var usedDepth = false
        
        // --- 1. LIDAR DEPTH (If available) ---
        if #available(iOS 14.0, *) {
            if let sceneDepth = frame.sceneDepth, let confMap = sceneDepth.confidenceMap {
                usedDepth = true
                let depthMap = sceneDepth.depthMap
                let depthW = CVPixelBufferGetWidth(depthMap)
                let depthH = CVPixelBufferGetHeight(depthMap)
                
                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                CVPixelBufferLockBaseAddress(confMap, .readOnly)
                
                if let depthPtr = CVPixelBufferGetBaseAddress(depthMap)?.assumingMemoryBound(to: Float32.self),
                   let confPtr = CVPixelBufferGetBaseAddress(confMap)?.assumingMemoryBound(to: UInt8.self) {
                    
                    let scaleX = Float(imageResolution.width) / Float(depthW)
                    let scaleY = Float(imageResolution.height) / Float(depthH)
                    
                    let fx = intrinsics[0][0]
                    let fy = intrinsics[1][1]
                    let cx = intrinsics[2][0]
                    let cy = intrinsics[2][1]
                    
                    for y in stride(from: 0, to: depthH, by: 4) {
                        for x in stride(from: 0, to: depthW, by: 4) {
                            let index = y * depthW + x
                            if confPtr[index] < 2 { continue }
                            let z = depthPtr[index]
                            if z < 0.1 || z > 5.0 { continue }
                            
                            let rgbX = Float(x) * scaleX
                            let rgbY = Float(y) * scaleY
                            
                            let x_c = (rgbX - cx) * z / fx
                            let y_c = (rgbY - cy) * z / fy
                            
                            let pointCamera = SIMD4<Float>(x_c, y_c, -z, 1.0)
                            let pointWorld = transform * pointCamera
                            let pos = SIMD3<Float>(pointWorld.x, pointWorld.y, pointWorld.z)
                            
                            let u = rgbX / Float(imageResolution.width)
                            let v = rgbY / Float(imageResolution.height)
                            let px = Int(u * Float(latestRGBWidth))
                            let py = Int(v * Float(latestRGBHeight))
                            
                            if px >= 0 && px < latestRGBWidth && py >= 0 && py < latestRGBHeight {
                                let offset = (py * latestRGBWidth + px) * 4
                                if offset + 2 < rgbBytes.count {
                                    if colorGrid.addPoint(pos: pos, r: rgbBytes[offset], g: rgbBytes[offset + 1], b: rgbBytes[offset + 2]) {
                                        newPoints = true
                                    }
                                }
                            }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
            }
        }
        
        // --- 2. RAW FEATURE POINTS (Fallback for Non-LiDAR devices) ---
        if !usedDepth {
            if let featurePoints = frame.rawFeaturePoints {
                let viewMatrix = frame.camera.viewMatrix(for: .landscapeRight)
                let projMatrix = frame.camera.projectionMatrix(for: .landscapeRight, viewportSize: CGSize(width: latestRGBWidth, height: latestRGBHeight), zNear: 0.001, zFar: 1000)
                let viewProj = projMatrix * viewMatrix
                
                for point in featurePoints.points {
                    let pos = SIMD3<Float>(point.x, point.y, point.z)
                    
                    let worldVertex = SIMD4<Float>(pos.x, pos.y, pos.z, 1.0)
                    let clip = viewProj * worldVertex
                    if clip.w > 0 {
                        let ndcX = clip.x / clip.w
                        let ndcY = clip.y / clip.w
                        let u = (ndcX * 0.5) + 0.5
                        let v = 1.0 - ((ndcY * 0.5) + 0.5)
                        
                        let px = Int(u * Float(latestRGBWidth))
                        let py = Int(v * Float(latestRGBHeight))
                        
                        if px >= 0 && px < latestRGBWidth && py >= 0 && py < latestRGBHeight {
                            let offset = (py * latestRGBWidth + px) * 4
                            if offset + 2 < rgbBytes.count {
                                if colorGrid.addPoint(pos: pos, r: rgbBytes[offset], g: rgbBytes[offset + 1], b: rgbBytes[offset + 2]) {
                                    newPoints = true
                                }
                            }
                        }
                    }
                }
            }
        }
        
        if newPoints {
            DispatchQueue.main.async {
                self.rebuildPointCloudNode()
            }
        }
    }
    
    private func rebuildPointCloudNode() {
        let points = Array(colorGrid.grid.values)
        guard !points.isEmpty else { return }
        
        var vertices = [SCNVector3]()
        var colors = [SIMD4<Float>]()
        var indices = [Int32]()
        
        vertices.reserveCapacity(points.count)
        colors.reserveCapacity(points.count)
        indices.reserveCapacity(points.count)
        
        for (i, p) in points.enumerated() {
            vertices.append(SCNVector3(p.pos.x, p.pos.y, p.pos.z))
            colors.append(SIMD4<Float>(p.color.x / 255.0, p.color.y / 255.0, p.color.z / 255.0, 1.0))
            indices.append(Int32(i))
        }
        
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.stride)
        let element = SCNGeometryElement(data: indexData, primitiveType: .point, primitiveCount: indices.count, bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = 10.0
        element.minimumPointScreenSpaceRadius = 2.0
        element.maximumPointScreenSpaceRadius = 15.0
        
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.firstMaterial = material
        
        if pointCloudNode == nil {
            pointCloudNode = SCNNode()
            arView.scene.rootNode.addChildNode(pointCloudNode!)
        }
        pointCloudNode?.geometry = geometry
    }
    
    // MARK: - ARSCNViewDelegate
    
    // We no longer render the blocky ARMeshAnchor! We use our dense pointCloudNode instead.
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        return nil
    }
}

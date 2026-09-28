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
            // First time seeing this voxel: use true color immediately for popping effect
            let newR = Float(r)
            let newG = Float(g)
            let newB = Float(b)
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
        
        let facesData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let geometryElement = SCNGeometryElement(data: facesData,
                                                 primitiveType: .triangles,
                                                 primitiveCount: faces.count,
                                                 bytesPerIndex: faces.bytesPerIndex)
        
        var sources = [vertexSource, normalSource]
        
        if let transform = nodeTransform, let cam = camera, let data = rgbData, rgbWidth > 0, rgbHeight > 0 {
            var colorData = Data(capacity: vertices.count * 16)
            let viewMat = cam.viewMatrix(for: .landscapeRight)
            let projMat = cam.projectionMatrix(for: .landscapeRight, viewportSize: CGSize(width: rgbWidth, height: rgbHeight), zNear: 0.001, zFar: 1000)
            let viewProj = projMat * viewMat
            
            let bytes = [UInt8](data)
            
            for i in 0..<vertices.count {
                var r: Float = 0.0
                var g: Float = 0.0
                var b: Float = 0.0
                var a: Float = 0.0 // Invisible when unpainted so they build up in real-time!
                
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
                                r = Float(newColor.x) / 255.0
                                g = Float(newColor.y) / 255.0
                                b = Float(newColor.z) / 255.0
                                a = 1.0
                                coloredFromCamera = true
                            }
                        }
                    }
                }
                
                if !coloredFromCamera, let grid = colorGrid {
                    if let savedColor = grid.getColor(at: worldPos) {
                        r = Float(savedColor.x) / 255.0
                        g = Float(savedColor.y) / 255.0
                        b = Float(savedColor.z) / 255.0
                        a = 1.0
                    }
                }
                
                var colorVec = SIMD4<Float>(r, g, b, a)
                withUnsafeBytes(of: &colorVec) { ptr in
                    colorData.append(contentsOf: ptr)
                }
            }
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            sources.append(colorSource)
        }
        
        self.init(sources: sources, elements: [geometryElement])
    }
}

class LidarScannerView: ExpoView, ARSessionDelegate, ARSCNViewDelegate {
    let arView = ARSCNView(frame: .zero)
    var isScanning = false
    var overlayNode: SCNNode?
    
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
        if #available(iOS 14.0, *) {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics = .sceneDepth
            }
        }
        
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        lastSavedCameraTransform = nil
        colorGrid.grid.removeAll()
        
        // Késleltetve (hogy az ARKit már bekapcsolja a kamerát) átállítjuk a záridőt "Sport" módra!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTripleCamera, .builtInDualCamera],
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
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
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
        
        overlayNode?.removeFromParentNode()
        overlayNode = nil
        
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
            let angle = acos(min(max(dot, -1.0), 1.0)) * 180.0 / .pi
            
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
                        let mm = meters * 1000.0
                        localArray[i] = mm.isNaN ? 0 : UInt16(min(max(mm, 0), 65535))
                    }
                    depthDataArray = localArray
                }
                CVPixelBufferUnlockBaseAddress(dBuffer, .readOnly)
                
                // Extract confidence as CGImage
                let cBuffer = sceneDepth.confidenceMap
                let ci = CIImage(cvPixelBuffer: cBuffer)
                confCgImage = ciContext.createCGImage(ci, from: ci.extent)
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

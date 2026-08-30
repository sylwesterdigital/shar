import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import simd

#if os(iOS)
import UIKit
private typealias SharPlatformImage = UIImage
private typealias SharPlatformColor = UIColor
#elseif os(macOS)
import AppKit
private typealias SharPlatformImage = NSImage
private typealias SharPlatformColor = NSColor
#endif

/// Interactive, entirely local 3D preview used by both the native iOS and macOS clients.
/// GLB/glTF are parsed in-process. Apple Model I/O handles USD/USDZ/OBJ/STL/PLY/Alembic
/// and any additional formats supported by the installed OS. Nothing is uploaded to a viewer service.
struct ThreeDPreviewView: View {
    let file: SharedFile

    @State private var scene: SCNScene?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let scene {
                SharSceneView(scene: scene)
                    .ignoresSafeArea(edges: .bottom)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 36, weight: .semibold))
                    Text("Cannot Preview 3D Model")
                        .font(.headline)
                    Text(file.name)
                        .font(.subheadline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Text("Shar previews GLB/glTF directly and uses Apple's local 3D importers for USD, USDZ, OBJ, STL, PLY and Alembic. Some formats such as FBX, 3MF, STEP or IGES depend on support provided by the installed operating system.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading 3D model…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color.black.opacity(0.92))
        .task(id: file.id) {
            isLoading = true
            errorMessage = nil
            scene = nil
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try ThreeDSceneLoader.load(url: file.url)
                }.value
                scene = loaded
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#if os(iOS)
private struct SharSceneView: UIViewRepresentable {
    let scene: SCNScene
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        ThreeDSceneLoader.configure(view: view, scene: scene)
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== scene { ThreeDSceneLoader.configure(view: uiView, scene: scene) }
    }
}
#elseif os(macOS)
private struct SharSceneView: NSViewRepresentable {
    let scene: SCNScene
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        ThreeDSceneLoader.configure(view: view, scene: scene)
        return view
    }
    func updateNSView(_ nsView: SCNView, context: Context) {
        if nsView.scene !== scene { ThreeDSceneLoader.configure(view: nsView, scene: scene) }
    }
}
#endif

enum ThreeDSceneLoader {
    enum PreviewError: LocalizedError {
        case malformedGLB(String)
        case unsupported(String)
        case missingData(String)

        var errorDescription: String? {
            switch self {
            case .malformedGLB(let value): return "Invalid GLB/glTF: \(value)"
            case .unsupported(let value): return value
            case .missingData(let value): return "The model is missing required data: \(value)"
            }
        }
    }

    static func load(url: URL) throws -> SCNScene {
        let ext = url.pathExtension.lowercased()
        if ext == "glb" || ext == "gltf" {
            return try SharGLTFLoader.load(url: url)
        }

        if MDLAsset.canImportFileExtension(ext) {
            let asset = MDLAsset(url: url)
            guard asset.count > 0 else { throw PreviewError.unsupported("Apple Model I/O could not decode this \(ext.uppercased()) file.") }
            return SCNScene(mdlAsset: asset)
        }

        // SceneKit can still import a few legacy scene formats not advertised by Model I/O.
        if let scene = try? SCNScene(url: url, options: nil) { return scene }
        throw PreviewError.unsupported("Interactive preview for .\(ext) is not available on this device yet. The file remains shareable and downloadable.")
    }

    static func configure(view: SCNView, scene: SCNScene) {
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = SharPlatformColor(white: 0.08, alpha: 1)
        view.rendersContinuously = false
        ensureCamera(in: scene, view: view)
    }

    private static func ensureCamera(in scene: SCNScene, view: SCNView) {
        if let existing = scene.rootNode.childNodes(passingTest: { node, _ in node.camera != nil }).first {
            view.pointOfView = existing
            return
        }

        let (minV, maxV) = scene.rootNode.boundingBox
        let center = SCNVector3(
            (minV.x + maxV.x) * 0.5,
            (minV.y + maxV.y) * 0.5,
            (minV.z + maxV.z) * 0.5
        )
        let dx = maxV.x - minV.x
        let dy = maxV.y - minV.y
        let dz = maxV.z - minV.z
        let diameter = max(0.1, max(dx, max(dy, dz)))
        let camera = SCNCamera()
        camera.zNear = Double(max(0.001, diameter / 1000))
        camera.zFar = Double(max(1000, diameter * 1000))
        camera.fieldOfView = 45
        let node = SCNNode()
        node.name = "SharPreviewCamera"
        node.camera = camera
        node.position = SCNVector3(center.x, center.y + diameter * 0.12, center.z + diameter * 2.4)
        node.look(at: center)
        scene.rootNode.addChildNode(node)
        view.pointOfView = node
    }
}

// MARK: - Minimal glTF 2.0 / GLB loader

private enum SharGLTFLoader {
    private static let glbMagic: UInt32 = 0x46546C67
    private static let jsonChunkType: UInt32 = 0x4E4F534A
    private static let binChunkType: UInt32 = 0x004E4942

    static func load(url: URL) throws -> SCNScene {
        let ext = url.pathExtension.lowercased()
        let document: GLTFDocument
        let buffers: [Data]

        if ext == "glb" {
            let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
            let parsed = try parseGLB(raw, baseURL: url.deletingLastPathComponent())
            document = parsed.document
            buffers = parsed.buffers
        } else {
            let json = try Data(contentsOf: url, options: [.mappedIfSafe])
            document = try JSONDecoder().decode(GLTFDocument.self, from: json)
            buffers = try loadExternalBuffers(document: document, baseURL: url.deletingLastPathComponent(), embeddedBinary: nil)
        }

        return try buildScene(document: document, buffers: buffers, baseURL: url.deletingLastPathComponent())
    }

    private static func parseGLB(_ data: Data, baseURL: URL) throws -> (document: GLTFDocument, buffers: [Data]) {
        guard data.count >= 20 else { throw ThreeDSceneLoader.PreviewError.malformedGLB("header is truncated") }
        let magic = data.u32LE(at: 0)
        let version = data.u32LE(at: 4)
        let declaredLength = Int(data.u32LE(at: 8))
        guard magic == glbMagic else { throw ThreeDSceneLoader.PreviewError.malformedGLB("bad magic") }
        guard version == 2 else { throw ThreeDSceneLoader.PreviewError.malformedGLB("only glTF 2.0 is supported") }
        guard declaredLength <= data.count else { throw ThreeDSceneLoader.PreviewError.malformedGLB("declared length exceeds file size") }

        var offset = 12
        var jsonData: Data?
        var binary: Data?
        while offset + 8 <= declaredLength {
            let length = Int(data.u32LE(at: offset))
            let type = data.u32LE(at: offset + 4)
            offset += 8
            guard length >= 0, offset + length <= declaredLength else { throw ThreeDSceneLoader.PreviewError.malformedGLB("chunk is truncated") }
            let chunk = data.subdata(in: offset..<(offset + length))
            if type == jsonChunkType { jsonData = chunk }
            if type == binChunkType { binary = chunk }
            offset += length
        }
        guard var jsonData else { throw ThreeDSceneLoader.PreviewError.malformedGLB("JSON chunk is missing") }
        while let last = jsonData.last, last == 0 || last == 0x20 { jsonData.removeLast() }
        let document = try JSONDecoder().decode(GLTFDocument.self, from: jsonData)
        let buffers = try loadExternalBuffers(document: document, baseURL: baseURL, embeddedBinary: binary)
        return (document, buffers)
    }

    private static func loadExternalBuffers(document: GLTFDocument, baseURL: URL, embeddedBinary: Data?) throws -> [Data] {
        let defs = document.buffers ?? []
        if defs.isEmpty, let embeddedBinary { return [embeddedBinary] }
        var result: [Data] = []
        for (index, buffer) in defs.enumerated() {
            if let uri = buffer.uri {
                result.append(try data(forURI: uri, baseURL: baseURL))
            } else if index == 0, let embeddedBinary {
                result.append(embeddedBinary)
            } else {
                throw ThreeDSceneLoader.PreviewError.missingData("buffer \(index)")
            }
        }
        return result
    }

    private static func buildScene(document: GLTFDocument, buffers: [Data], baseURL: URL) throws -> SCNScene {
        let scene = SCNScene()
        let nodes = document.nodes ?? []
        var parented = Set<Int>()
        for node in nodes { for child in node.children ?? [] { parented.insert(child) } }

        let rootIndices: [Int]
        if let sceneIndex = document.scene,
           let scenes = document.scenes,
           scenes.indices.contains(sceneIndex) {
            rootIndices = scenes[sceneIndex].nodes ?? []
        } else if let first = document.scenes?.first, let roots = first.nodes, !roots.isEmpty {
            rootIndices = roots
        } else {
            rootIndices = nodes.indices.filter { !parented.contains($0) }
        }

        var cache: [Int: SCNNode] = [:]
        func makeNode(_ index: Int) throws -> SCNNode {
            if let cached = cache[index] { return cached }
            guard nodes.indices.contains(index) else { throw ThreeDSceneLoader.PreviewError.missingData("node \(index)") }
            let def = nodes[index]
            let node = SCNNode()
            node.name = def.name
            applyTransform(def, to: node)
            cache[index] = node

            if let meshIndex = def.mesh {
                let meshNodes = try makeMeshNodes(meshIndex, document: document, buffers: buffers, baseURL: baseURL)
                for meshNode in meshNodes { node.addChildNode(meshNode) }
            }
            for childIndex in def.children ?? [] { node.addChildNode(try makeNode(childIndex)) }
            return node
        }

        if rootIndices.isEmpty, let meshes = document.meshes {
            for index in meshes.indices {
                for node in try makeMeshNodes(index, document: document, buffers: buffers, baseURL: baseURL) {
                    scene.rootNode.addChildNode(node)
                }
            }
        } else {
            for index in rootIndices { scene.rootNode.addChildNode(try makeNode(index)) }
        }
        return scene
    }

    private static func makeMeshNodes(_ meshIndex: Int, document: GLTFDocument, buffers: [Data], baseURL: URL) throws -> [SCNNode] {
        guard let meshes = document.meshes, meshes.indices.contains(meshIndex) else { throw ThreeDSceneLoader.PreviewError.missingData("mesh \(meshIndex)") }
        var result: [SCNNode] = []
        for primitive in meshes[meshIndex].primitives {
            guard primitive.mode == nil || primitive.mode == 4 || primitive.mode == 5 else { continue }
            guard let positionIndex = primitive.attributes["POSITION"] else { continue }
            let position = try source(accessorIndex: positionIndex, semantic: .vertex, document: document, buffers: buffers)
            var sources = [position.source]
            if let normalIndex = primitive.attributes["NORMAL"], let normal = try? source(accessorIndex: normalIndex, semantic: .normal, document: document, buffers: buffers) { sources.append(normal.source) }
            if let uvIndex = primitive.attributes["TEXCOORD_0"], let uv = try? source(accessorIndex: uvIndex, semantic: .texcoord, document: document, buffers: buffers) { sources.append(uv.source) }

            let element: SCNGeometryElement
            if let indices = primitive.indices {
                element = try geometryElement(accessorIndex: indices, mode: primitive.mode ?? 4, document: document, buffers: buffers)
            } else {
                element = sequentialElement(vertexCount: position.count, mode: primitive.mode ?? 4)
            }
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.name = meshes[meshIndex].name
            if let materialIndex = primitive.material {
                geometry.materials = [material(index: materialIndex, document: document, buffers: buffers, baseURL: baseURL)]
            } else {
                let mat = SCNMaterial()
                mat.diffuse.contents = SharPlatformColor(white: 0.78, alpha: 1)
                mat.metalness.contents = 0.08
                mat.roughness.contents = 0.72
                geometry.materials = [mat]
            }
            let node = SCNNode(geometry: geometry)
            result.append(node)
        }
        return result
    }

    private static func source(accessorIndex: Int, semantic: SCNGeometrySource.Semantic, document: GLTFDocument, buffers: [Data]) throws -> (source: SCNGeometrySource, count: Int) {
        guard let accessors = document.accessors, accessors.indices.contains(accessorIndex) else { throw ThreeDSceneLoader.PreviewError.missingData("accessor \(accessorIndex)") }
        let accessor = accessors[accessorIndex]
        guard let viewIndex = accessor.bufferView,
              let views = document.bufferViews,
              views.indices.contains(viewIndex) else { throw ThreeDSceneLoader.PreviewError.missingData("bufferView for accessor \(accessorIndex)") }
        let view = views[viewIndex]
        guard buffers.indices.contains(view.buffer) else { throw ThreeDSceneLoader.PreviewError.missingData("buffer \(view.buffer)") }
        let components = componentCount(accessor.type)
        let bytes = componentSize(accessor.componentType)
        guard components > 0, bytes > 0 else { throw ThreeDSceneLoader.PreviewError.unsupported("Unsupported glTF accessor type") }
        let usesFloat = accessor.componentType == 5126
        guard usesFloat || semantic == .texcoord else { throw ThreeDSceneLoader.PreviewError.unsupported("This GLB uses a vertex encoding that Shar does not yet preview") }
        let stride = view.byteStride ?? components * bytes
        let offset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let source = SCNGeometrySource(
            data: buffers[view.buffer], semantic: semantic, vectorCount: accessor.count,
            usesFloatComponents: usesFloat, componentsPerVector: components,
            bytesPerComponent: bytes, dataOffset: offset, dataStride: stride
        )
        return (source, accessor.count)
    }

    private static func geometryElement(accessorIndex: Int, mode: Int, document: GLTFDocument, buffers: [Data]) throws -> SCNGeometryElement {
        guard let accessors = document.accessors, accessors.indices.contains(accessorIndex) else { throw ThreeDSceneLoader.PreviewError.missingData("index accessor") }
        let accessor = accessors[accessorIndex]
        guard let viewIndex = accessor.bufferView,
              let views = document.bufferViews, views.indices.contains(viewIndex) else { throw ThreeDSceneLoader.PreviewError.missingData("index bufferView") }
        let view = views[viewIndex]
        guard buffers.indices.contains(view.buffer) else { throw ThreeDSceneLoader.PreviewError.missingData("index buffer") }
        let bytesPerIndex = componentSize(accessor.componentType)
        guard [1, 2, 4].contains(bytesPerIndex) else { throw ThreeDSceneLoader.PreviewError.unsupported("Unsupported GLB index format") }
        let stride = view.byteStride ?? bytesPerIndex
        let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let input = buffers[view.buffer]
        var packed = Data(capacity: accessor.count * bytesPerIndex)
        for i in 0..<accessor.count {
            let o = start + i * stride
            guard o + bytesPerIndex <= input.count else { throw ThreeDSceneLoader.PreviewError.malformedGLB("index data is truncated") }
            packed.append(input.subdata(in: o..<(o + bytesPerIndex)))
        }
        let type: SCNGeometryPrimitiveType = mode == 5 ? .triangleStrip : .triangles
        let primitiveCount = mode == 5 ? max(0, accessor.count - 2) : accessor.count / 3
        return SCNGeometryElement(data: packed, primitiveType: type, primitiveCount: primitiveCount, bytesPerIndex: bytesPerIndex)
    }

    private static func sequentialElement(vertexCount: Int, mode: Int) -> SCNGeometryElement {
        let values = (0..<vertexCount).map(UInt32.init)
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let type: SCNGeometryPrimitiveType = mode == 5 ? .triangleStrip : .triangles
        let primitiveCount = mode == 5 ? max(0, vertexCount - 2) : vertexCount / 3
        return SCNGeometryElement(data: data, primitiveType: type, primitiveCount: primitiveCount, bytesPerIndex: 4)
    }

    private static func material(index: Int, document: GLTFDocument, buffers: [Data], baseURL: URL) -> SCNMaterial {
        let result = SCNMaterial()
        result.lightingModel = .physicallyBased
        guard let materials = document.materials, materials.indices.contains(index) else { return result }
        let def = materials[index]
        result.name = def.name
        result.isDoubleSided = def.doubleSided ?? false
        if let pbr = def.pbrMetallicRoughness {
            if let factor = pbr.baseColorFactor, factor.count >= 4 {
                result.diffuse.contents = SharPlatformColor(red: CGFloat(factor[0]), green: CGFloat(factor[1]), blue: CGFloat(factor[2]), alpha: CGFloat(factor[3]))
            }
            result.metalness.contents = pbr.metallicFactor ?? 1
            result.roughness.contents = pbr.roughnessFactor ?? 1
            if let textureIndex = pbr.baseColorTexture?.index,
               let image = imageForTexture(textureIndex, document: document, buffers: buffers, baseURL: baseURL) {
                result.diffuse.contents = image
            }
        }
        if let emissive = def.emissiveFactor, emissive.count >= 3 {
            result.emission.contents = SharPlatformColor(red: CGFloat(emissive[0]), green: CGFloat(emissive[1]), blue: CGFloat(emissive[2]), alpha: 1)
        }
        if def.alphaMode == "BLEND" { result.transparencyMode = .dualLayer }
        return result
    }

    private static func imageForTexture(_ textureIndex: Int, document: GLTFDocument, buffers: [Data], baseURL: URL) -> SharPlatformImage? {
        guard let textures = document.textures, textures.indices.contains(textureIndex),
              let sourceIndex = textures[textureIndex].source,
              let images = document.images, images.indices.contains(sourceIndex) else { return nil }
        let image = images[sourceIndex]
        let imageData: Data?
        if let viewIndex = image.bufferView,
           let views = document.bufferViews, views.indices.contains(viewIndex) {
            let view = views[viewIndex]
            if buffers.indices.contains(view.buffer) {
                let start = view.byteOffset ?? 0
                let end = start + view.byteLength
                imageData = end <= buffers[view.buffer].count ? buffers[view.buffer].subdata(in: start..<end) : nil
            } else { imageData = nil }
        } else if let uri = image.uri {
            imageData = try? data(forURI: uri, baseURL: baseURL)
        } else { imageData = nil }
        guard let imageData else { return nil }
        return SharPlatformImage(data: imageData)
    }

    private static func applyTransform(_ def: GLTFNode, to node: SCNNode) {
        if let matrix = def.matrix, matrix.count == 16 {
            let c0 = SIMD4<Float>(Float(matrix[0]), Float(matrix[1]), Float(matrix[2]), Float(matrix[3]))
            let c1 = SIMD4<Float>(Float(matrix[4]), Float(matrix[5]), Float(matrix[6]), Float(matrix[7]))
            let c2 = SIMD4<Float>(Float(matrix[8]), Float(matrix[9]), Float(matrix[10]), Float(matrix[11]))
            let c3 = SIMD4<Float>(Float(matrix[12]), Float(matrix[13]), Float(matrix[14]), Float(matrix[15]))
            node.simdTransform = simd_float4x4(columns: (c0, c1, c2, c3))
            return
        }
        if let v = def.translation, v.count >= 3 { node.simdPosition = SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2])) }
        if let q = def.rotation, q.count >= 4 { node.simdOrientation = simd_quatf(ix: Float(q[0]), iy: Float(q[1]), iz: Float(q[2]), r: Float(q[3])) }
        if let v = def.scale, v.count >= 3 { node.simdScale = SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2])) }
    }

    private static func data(forURI uri: String, baseURL: URL) throws -> Data {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else { throw ThreeDSceneLoader.PreviewError.missingData("malformed data URI") }
            let header = String(uri[..<comma])
            let body = String(uri[uri.index(after: comma)...])
            if header.contains(";base64"), let decoded = Data(base64Encoded: body) { return decoded }
            if let decoded = body.removingPercentEncoding?.data(using: .utf8) { return decoded }
            throw ThreeDSceneLoader.PreviewError.missingData("data URI")
        }
        return try Data(contentsOf: baseURL.appendingPathComponent(uri), options: [.mappedIfSafe])
    }

    private static func componentCount(_ type: String) -> Int {
        switch type { case "SCALAR": return 1; case "VEC2": return 2; case "VEC3": return 3; case "VEC4": return 4; default: return 0 }
    }

    private static func componentSize(_ type: Int) -> Int {
        switch type { case 5120, 5121: return 1; case 5122, 5123: return 2; case 5125, 5126: return 4; default: return 0 }
    }
}

private extension Data {
    func u32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UInt32(p[0]) | (UInt32(p[1]) << 8) | (UInt32(p[2]) << 16) | (UInt32(p[3]) << 24)
        }
    }
}

private struct GLTFDocument: Decodable {
    let scene: Int?
    let scenes: [GLTFScene]?
    let nodes: [GLTFNode]?
    let meshes: [GLTFMesh]?
    let accessors: [GLTFAccessor]?
    let bufferViews: [GLTFBufferView]?
    let buffers: [GLTFBuffer]?
    let materials: [GLTFMaterial]?
    let textures: [GLTFTexture]?
    let images: [GLTFImage]?
}
private struct GLTFScene: Decodable { let nodes: [Int]? }
private struct GLTFNode: Decodable { let name: String?; let mesh: Int?; let children: [Int]?; let matrix: [Double]?; let translation: [Double]?; let rotation: [Double]?; let scale: [Double]? }
private struct GLTFMesh: Decodable { let name: String?; let primitives: [GLTFPrimitive] }
private struct GLTFPrimitive: Decodable { let attributes: [String: Int]; let indices: Int?; let material: Int?; let mode: Int? }
private struct GLTFAccessor: Decodable { let bufferView: Int?; let byteOffset: Int?; let componentType: Int; let count: Int; let type: String }
private struct GLTFBufferView: Decodable { let buffer: Int; let byteOffset: Int?; let byteLength: Int; let byteStride: Int? }
private struct GLTFBuffer: Decodable { let uri: String?; let byteLength: Int }
private struct GLTFTexture: Decodable { let source: Int? }
private struct GLTFImage: Decodable { let uri: String?; let mimeType: String?; let bufferView: Int? }
private struct GLTFTextureInfo: Decodable { let index: Int }
private struct GLTFPBR: Decodable { let baseColorFactor: [Double]?; let baseColorTexture: GLTFTextureInfo?; let metallicFactor: Double?; let roughnessFactor: Double? }
private struct GLTFMaterial: Decodable { let name: String?; let pbrMetallicRoughness: GLTFPBR?; let emissiveFactor: [Double]?; let alphaMode: String?; let doubleSided: Bool? }

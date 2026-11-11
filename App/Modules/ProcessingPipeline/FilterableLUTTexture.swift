import Metal

/// Direct RGB/red-fastest cube storage; no axis remapping or curve changes.
/// GPUs without Float32 filtering (including the measured A16) use filterable
/// RGBA16Float; capable GPUs retain the existing RGBA32Float upload.
enum FilterableLUTTexture {
    static func format(supports32BitFloatFiltering: Bool) -> MTLPixelFormat {
        supports32BitFloatFiltering ? .rgba32Float : .rgba16Float
    }

    static func make(device: any MTLDevice, size: Int, rgba: [Float],
                     preferHalfPrecision: Bool = false) -> (any MTLTexture)? {
        guard size > 1, size <= 256, rgba.count == size * size * size * 4 else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = format(supports32BitFloatFiltering: device.supports32BitFloatFiltering && !preferHalfPrecision)
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let region = MTLRegionMake3D(0, 0, 0, size, size, size)
        if descriptor.pixelFormat == .rgba16Float {
            let half = rgba.map(Float16.init)
            half.withUnsafeBytes {
                texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: size * 4 * MemoryLayout<Float16>.size,
                    bytesPerImage: size * size * 4 * MemoryLayout<Float16>.size)
            }
        } else {
            rgba.withUnsafeBytes {
                texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                    bytesPerImage: size * size * 4 * MemoryLayout<Float>.size)
            }
        }
        return texture
    }
}

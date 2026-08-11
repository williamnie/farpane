import ConnectionCatalog
import CoreAudio
import Foundation

private enum HostAudioInputDeviceDiscoveryError: Error {
    case propertyUnavailable
    case propertyReadFailed(OSStatus)
}

final class HostAudioInputDeviceCatalogOwner {
    private(set) var catalog = HostAudioInputDeviceCatalog(reportedNames: [])

    static func makeProduct() -> HostAudioInputDeviceCatalogOwner {
        let owner = HostAudioInputDeviceCatalogOwner()
        owner.refresh()
        return owner
    }

    @discardableResult
    func refresh() -> Bool {
        do {
            catalog = HostAudioInputDeviceCatalog(
                reportedNames: try Self.discoverInputDeviceNames()
            )
            return true
        } catch {
            catalog = HostAudioInputDeviceCatalog(reportedNames: [])
            return false
        }
    }

    private static func discoverInputDeviceNames() throws -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectHasProperty(system, &address) else {
            throw HostAudioInputDeviceDiscoveryError.propertyUnavailable
        }
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            system,
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr,
              byteCount % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0
        else {
            throw HostAudioInputDeviceDiscoveryError.propertyReadFailed(status)
        }
        guard byteCount > 0 else { return [] }
        var devices = [AudioDeviceID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        )
        status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                system,
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw HostAudioInputDeviceDiscoveryError.propertyReadFailed(status)
        }
        return try devices.compactMap { device in
            guard try hasInputChannels(device) else { return nil }
            return try deviceName(device)
        }
    }

    private static func hasInputChannels(_ device: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            device,
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr, byteCount >= MemoryLayout<AudioBufferList>.size else {
            throw HostAudioInputDeviceDiscoveryError.propertyReadFailed(status)
        }
        var storage = [UInt8](repeating: 0, count: Int(byteCount))
        status = storage.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else {
            throw HostAudioInputDeviceDiscoveryError.propertyReadFailed(status)
        }
        return storage.withUnsafeMutableBytes { bytes in
            let list = bytes.baseAddress!
                .assumingMemoryBound(to: AudioBufferList.self)
            return UnsafeMutableAudioBufferListPointer(list)
                .contains { $0.mNumberChannels > 0 }
        }
    }

    private static func deviceName(_ device: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else {
            throw HostAudioInputDeviceDiscoveryError.propertyUnavailable
        }
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &byteCount,
            &value
        )
        guard status == noErr, let value else {
            throw HostAudioInputDeviceDiscoveryError.propertyReadFailed(status)
        }
        return value.takeUnretainedValue() as String
    }
}

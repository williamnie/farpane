import Darwin
import Foundation
import IOKit.ps

struct HostProcessSample: Equatable, Sendable {
  let cpuPercent: Double
  let residentBytes: UInt64
  let physicalFootprintBytes: UInt64
  let threadCount: Int
  let thermalState: String
  let powerSource: String
  let lowPowerModeEnabled: Bool
}

/// Reads only the current FarPane process and non-sensitive system power
/// state. CPU is the delta in process user+system time over monotonic wall
/// time, so values may exceed 100% when multiple cores are active.
final class HostProcessSampler: @unchecked Sendable {
  private let lock = NSLock()
  private var previousCPUSeconds: Double
  private var previousUptimeNS: UInt64

  init() {
    previousCPUSeconds = HostProcessSampler.currentCPUSeconds()
    previousUptimeNS = DispatchTime.now().uptimeNanoseconds
  }

  func sample() -> HostProcessSample {
    let now = DispatchTime.now().uptimeNanoseconds
    let cpuSeconds = Self.currentCPUSeconds()
    let cpuPercent = locked { () -> Double in
      let elapsed = Double(now &- previousUptimeNS) / 1_000_000_000
      let consumed = max(0, cpuSeconds - previousCPUSeconds)
      previousUptimeNS = now
      previousCPUSeconds = cpuSeconds
      guard elapsed >= 0.1 else { return 0 }
      return consumed / elapsed * 100
    }
    return HostProcessSample(
      cpuPercent: cpuPercent,
      residentBytes: Self.currentResidentBytes(),
      physicalFootprintBytes: Self.currentPhysicalFootprintBytes(),
      threadCount: Self.currentThreadCount(),
      thermalState: Self.currentThermalState(),
      powerSource: Self.currentPowerSource(),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
    )
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func currentCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec)
      + Double(usage.ru_utime.tv_usec) / 1_000_000
    let system = Double(usage.ru_stime.tv_sec)
      + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + system
  }

  private static func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          $0,
          &count
        )
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
  }

  private static func currentPhysicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(
          mach_task_self_,
          task_flavor_t(TASK_VM_INFO),
          $0,
          &count
        )
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
  }

  private static func currentThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else {
      return 0
    }
    if let threads {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
      )
    }
    return Int(count)
  }

  private static func currentThermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private static func currentPowerSource() -> String {
    guard let unmanagedInfo = IOPSCopyPowerSourcesInfo() else { return "unknown" }
    let info = unmanagedInfo.takeRetainedValue()
    guard let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
    else { return "unknown" }
    switch source as NSString as String {
    case kIOPSACPowerValue: return "ac"
    case kIOPSBatteryPowerValue: return "battery"
    case kIOPSOffLineValue: return "offline"
    default: return "unknown"
    }
  }
}

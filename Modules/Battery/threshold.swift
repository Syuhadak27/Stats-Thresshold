//
//  threshold.swift
//  Battery
//
//  Battery charge threshold support through YogaSMC / ThinkVPC.
//  Ported from the local REFERENSI/ThinkpadAssistant implementation.
//
//  Threshold is written as IOUserClient properties (setCMstart / setCMstop),
//  which YogaSMC forwards to the ACPI BCCS / BCSS methods and finally to the EC.
//  The SMC keys B0St/B0Sp/B0En do NOT exist and must not be used here.
//

import Cocoa
import IOKit
import Kit

internal extension Notification.Name {
    static let batteryPowerSourceDidChange = Notification.Name("eu.exelban.Stats.Battery.powerSourceDidChange")
}

internal enum BatteryThresholdError: LocalizedError {
    case serviceNotFound
    case setFailed(IOReturn)
    
    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return localizedString("ThinkVPC (YogaSMC) service not found")
        case .setFailed(let kr):
            return String(format: localizedString("Could not write battery threshold (0x%08X)"), kr)
        }
    }
}

internal final class BatteryThresholdManager {
    static let shared = BatteryThresholdManager()
    private init() {}
    
    private let serviceName = "ThinkVPC"
    private let batteryProperty = "Battery"
    private let batteryIndex = 1  // BAT_PRIMARY (0 = ANY, 1 = PRIMARY, 2 = SECONDARY)
    
    // YogaSMC maps setCMstart/setCMstop to the EC methods BCCS/BCSS, but the EC
    // only re-evaluates them when AC is plugged/unplugged. A charge that started
    // before the threshold was written keeps going until the next plug event.
    // setCMInhibitCharge (EC BICS) is the active switch we drive from the level.
    private let inhibitChargeKey = "setCMInhibitCharge"
    
    // Serializes all EC writes and protects the latched inhibit state.
    private let queue = DispatchQueue(label: "eu.exelban.Stats.Battery.threshold", qos: .utility)
    private var inhibited: Bool? = nil
    private var lastLevel: Int? = nil
    
    private let startKey = "Battery_thresholdStart"
    private let stopKey = "Battery_thresholdStop"
    private let enabledKey = "Battery_thresholdEnabled"
    
    private static var ioPort: mach_port_t {
        if #available(macOS 12.0, *) { return kIOMainPortDefault }
        return kIOMasterPortDefault
    }
    
    private static func clamp(_ value: Int) -> Int {
        return min(100, max(0, value))
    }
    
    var start: Int {
        get { Self.clamp(Store.shared.int(key: self.startKey, defaultValue: 75)) }
        set { Store.shared.set(key: self.startKey, value: Self.clamp(newValue)) }
    }
    
    var stop: Int {
        get { Self.clamp(Store.shared.int(key: self.stopKey, defaultValue: 85)) }
        set { Store.shared.set(key: self.stopKey, value: Self.clamp(newValue)) }
    }
    
    var isEnabled: Bool {
        get { Store.shared.bool(key: self.enabledKey, defaultValue: true) }
        set { Store.shared.set(key: self.enabledKey, value: newValue) }
    }
    
    /// True when the YogaSMC ThinkVPC IOService is present on this machine.
    var isServiceAvailable: Bool {
        guard let service = try? self.copyService() else { return false }
        IOObjectRelease(service)
        return true
    }
    
    /// Short text used by the popup and the settings subtitle.
    var status: String {
        guard self.isServiceAvailable else { return localizedString("Unavailable") }
        guard self.isEnabled else { return localizedString("Disabled") }
        return "\(self.start)% → \(self.stop)%"
    }
    
    private func copyService() throws -> io_registry_entry_t {
        let matching = IOServiceMatching(self.serviceName)
        let service = IOServiceGetMatchingService(Self.ioPort, matching)
        guard service != 0 else { throw BatteryThresholdError.serviceNotFound }
        return service
    }
    
    private func send(_ props: [String: Any]) throws {
        let service = try self.copyService()
        defer { IOObjectRelease(service) }
        let cfProps = props as NSDictionary as CFTypeRef
        
        // Primary path: IOKit registry setProperties -> YogaVPC::setProperties()
        var kr = IORegistryEntrySetCFProperties(service, cfProps)
        if kr == kIOReturnSuccess { return }
        
        // Fallback: official YogaSMC user client (IOConnectSetCFProperties).
        var connect: io_connect_t = 0
        let open = IOServiceOpen(service, mach_task_self_, 0, &connect)
        guard open == kIOReturnSuccess else { throw BatteryThresholdError.setFailed(kr) }
        defer { IOServiceClose(connect) }
        kr = IOConnectSetCFProperties(connect, cfProps)
        guard kr == kIOReturnSuccess else { throw BatteryThresholdError.setFailed(kr) }
    }
    
    /// Persists the values and writes them to the EC. Passing `nil` keeps the stored value.
    /// Disabling restores the full range (start 0 / stop 100, no charge inhibit).
    @discardableResult
    func apply(start: Int? = nil, stop: Int? = nil, enabled: Bool? = nil) throws -> Bool {
        return try self.queue.sync {
            let s = start.map(Self.clamp) ?? self.start
            let t = stop.map(Self.clamp) ?? self.stop
            let e = enabled ?? self.isEnabled
            if start != nil { self.start = s }
            if stop != nil { self.stop = t }
            if enabled != nil { self.isEnabled = e }
            
            var props: [String: Any] = [self.batteryProperty: self.batteryIndex]
            if e {
                props["setCMstart"] = s
                props["setCMstop"] = t
            } else {
                props["setCMstart"] = 0
                props["setCMstop"] = 100
                props[self.inhibitChargeKey] = 0
            }
            try self.send(props)
            
            // A threshold write makes the EC state unknown. Re-emit the inhibit
            // flag right away using the last observed level instead of waiting
            // for the next battery sample.
            self.inhibited = e ? nil : false
            if e, let level = self.lastLevel {
                try self.enforceLocked(level: level)
            }
            return e
        }
    }
    
    /// Actively holds the charge inside the configured window. Call this on every
    /// battery sample: the EC otherwise keeps charging when a threshold is written
    /// after AC was connected, and only corrects itself on the next plug event.
    func enforce(level: Int) throws {
        try self.queue.sync {
            try self.enforceLocked(level: level)
        }
    }
    
    private func enforceLocked(level: Int) throws {
        guard self.isEnabled else { return }
        
        let l = Self.clamp(level)
        self.lastLevel = l
        
        let target: Bool
        if l >= self.stop {
            target = true
        } else if l <= self.start {
            target = false
        } else {
            // Inside the window keep the previous state. When it is unknown
            // (app start, threshold change, AC replug), stay off until the
            // battery drains down to the start threshold.
            target = self.inhibited ?? true
        }
        
        guard self.inhibited != target else { return }
        try self.send([
            self.batteryProperty: self.batteryIndex,
            self.inhibitChargeKey: target ? 1 : 0
        ])
        self.inhibited = target
        NSLog("[BatteryThreshold] inhibit charge = %d at %d%%", target ? 1 : 0, l)
    }
    
    /// Debug only: raw BAT_PRIMARY data (BCTG/BCSG) goes to Console, never to the UI.
    func logRawThresholds() {
        guard let service = try? self.copyService() else { return }
        defer { IOObjectRelease(service) }
        let raw = IORegistryEntryCreateCFProperty(service, "BAT_PRIMARY" as CFString, kCFAllocatorDefault, 0)
        if let dict = raw?.takeRetainedValue() as? NSDictionary {
            NSLog("[BatteryThreshold] raw BAT_PRIMARY: %@", dict.description)
        }
    }
}

internal func presentBatteryThresholdError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = localizedString("Battery threshold")
    alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

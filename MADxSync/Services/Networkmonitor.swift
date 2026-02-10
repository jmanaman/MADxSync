//
//  NetworkMonitor.swift
//  MADxSync
//
//  Central network state awareness for the entire app.
//  Uses NWPathMonitor to detect connectivity changes in real time.
//
//  Key capabilities:
//  - Detects WiFi vs cellular vs no connectivity
//  - Detects FLO WiFi (192.168.4.x subnet) vs internet WiFi
//  - All services check this before making network requests
//  - Publishes state changes for UI (offline banner, etc.)
//
//  CREATED: 2026-02-09
//

import Foundation
import Network
import Combine

// MARK: - Connection Type

enum ConnectionType: String {
    case wifi = "WiFi"
    case cellular = "Cellular"
    case wired = "Wired"
    case none = "None"
}

// MARK: - Network Monitor

@MainActor
class NetworkMonitor: ObservableObject {
    
    static let shared = NetworkMonitor()
    
    // MARK: - Published State
    
    /// Device has some network path available (WiFi, cellular, or wired)
    @Published private(set) var isConnected: Bool = true
    
    /// Current connection type
    @Published private(set) var connectionType: ConnectionType = .wifi
    
    /// Device is connected to FLO WiFi AP (192.168.4.x subnet, local only — no internet)
    @Published private(set) var isFLOWiFi: Bool = false
    
    /// Device has a path to the internet (excludes FLO WiFi which is local-only)
    /// Use this for Supabase requests, not just `isConnected`
    @Published private(set) var hasInternet: Bool = true
    
    /// Timestamp of last connectivity change — useful for debouncing
    /// Initialized to distant past so app launch isn't treated as a "transition"
    @Published private(set) var lastChangeDate: Date = .distantPast
    
    // MARK: - Internal
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.madxsync.networkmonitor", qos: .utility)
    
    /// Track if we've ever received a path update (avoids acting on initial default values)
    private(set) var hasReceivedInitialUpdate = false
    
    // MARK: - Init
    
    private init() {
        startMonitoring()
    }
    
    deinit {
        monitor.cancel()
    }
    
    // MARK: - Monitoring
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: monitorQueue)
        print("[NetworkMonitor] Started monitoring")
    }
    
    private func handlePathUpdate(_ path: NWPath) {
        let wasConnected = isConnected
        let wasFLO = isFLOWiFi
        let oldType = connectionType
        
        // Determine connection type
        // IMPORTANT: Only report an interface type if the path is actually satisfied.
        // During transitions, NWPathMonitor can report an interface type (e.g., .cellular)
        // while status is still .unsatisfied — which produces confusing "Cellular + disconnected" logs.
        let newConnected = path.status == .satisfied
        let newType: ConnectionType
        if !newConnected {
            newType = .none
        } else if path.usesInterfaceType(.wifi) {
            newType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            newType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            newType = .wired
        } else {
            newType = .none
        }
        
        // Update state
        isConnected = newConnected
        connectionType = newType
        lastChangeDate = Date()
        
        // FLO WiFi detection:
        // When on FLO WiFi, NWPathMonitor reports WiFi but the path is local-only (no internet).
        // We detect this by checking: WiFi + not satisfied for internet gateways.
        // NWPath.status == .satisfied just means "a network interface is up", not "internet works".
        // On FLO WiFi, isExpensive == false, isConstrained == false, but there's no default route to internet.
        //
        // Best heuristic: If we're on WiFi and the path does NOT support DNS resolution
        // to external hosts, we're likely on FLO. But NWPathMonitor doesn't give us that directly.
        //
        // Practical approach: Check if WiFi + no internet gateway.
        // NWPath doesn't expose gateway info, so we use a secondary check:
        // FLOService.shared.isConnected is the ground truth (it successfully hit 192.168.4.1).
        // Here we just track whether WiFi is active — FLOService cross-references this.
        //
        // UPDATE: We can check path.gateways — if empty or local-only, it's FLO WiFi.
        // But gateways isn't available on all iOS versions.
        //
        // SIMPLEST RELIABLE APPROACH:
        // - WiFi connected + FLOService.isConnected == true → isFLOWiFi = true
        // - This is set by FLOService when it successfully reaches 192.168.4.1
        // - NetworkMonitor just tracks the WiFi state; FLO detection is confirmed by FLOService
        
        // For now, if we transition away from WiFi, FLO is definitely not connected
        if newType != .wifi {
            isFLOWiFi = false
        }
        // Note: isFLOWiFi = true is set externally by FLOService via setFLOWiFiConnected()
        
        // hasInternet: connected AND (not on FLO-only WiFi)
        // If on cellular, we have internet. If on WiFi but not FLO, we have internet.
        // If on FLO WiFi, no internet.
        hasInternet = newConnected && !isFLOWiFi
        
        // Log changes
        if !hasReceivedInitialUpdate {
            hasReceivedInitialUpdate = true
            print("[NetworkMonitor] Initial state: \(newType.rawValue), connected=\(newConnected), internet=\(hasInternet)")
        } else if wasConnected != newConnected || oldType != newType || wasFLO != isFLOWiFi {
            print("[NetworkMonitor] Changed: \(oldType.rawValue)→\(newType.rawValue), connected=\(newConnected), FLO=\(isFLOWiFi), internet=\(hasInternet)")
        }
        
        // Post notification for services that aren't observing @Published
        NotificationCenter.default.post(name: .networkStateChanged, object: nil)
    }
    
    // MARK: - External State Updates
    
    /// Called by FLOService when it successfully communicates with 192.168.4.1
    /// This confirms we're on FLO WiFi (local-only, no internet)
    func setFLOWiFiConnected(_ connected: Bool) {
        guard isFLOWiFi != connected else { return }
        isFLOWiFi = connected
        hasInternet = isConnected && !isFLOWiFi
        print("[NetworkMonitor] FLO WiFi: \(connected), internet=\(hasInternet)")
    }
    
    // MARK: - Convenience
    
    /// True if we can reach Supabase (has internet, not on FLO-only WiFi)
    var canReachSupabase: Bool {
        hasInternet
    }
    
    /// Human-readable status for UI
    var statusText: String {
        if !isConnected { return "Offline" }
        if isFLOWiFi { return "FLO WiFi (no internet)" }
        return connectionType.rawValue
    }
    
    /// True if a network transition happened in the last N seconds
    /// Useful for debouncing requests during WiFi↔cellular handoff
    func isTransitioning(withinSeconds seconds: TimeInterval = 3.0) -> Bool {
        Date().timeIntervalSince(lastChangeDate) < seconds
    }
}

// MARK: - Notification

extension Notification.Name {
    static let networkStateChanged = Notification.Name("networkStateChanged")
}

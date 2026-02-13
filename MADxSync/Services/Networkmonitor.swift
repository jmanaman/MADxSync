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
//  UPDATED: 2026-02-11 — Added wifiAvailable flag for LTE coexistence.
//  When iOS enables LTE alongside FLO WiFi, NWPathMonitor may report the
//  primary path as cellular. But WiFi is still associated and usable.
//  wifiAvailable tracks whether the WiFi interface exists in the path at all,
//  regardless of which interface iOS considers "primary". FLOService uses this
//  instead of connectionType to decide whether to poll the FLO.
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
    
    /// Current PRIMARY connection type (what iOS prefers for routing)
    /// NOTE: When LTE is enabled alongside FLO WiFi, this may report .cellular
    /// even though WiFi is still associated. Use wifiAvailable for FLO decisions.
    @Published private(set) var connectionType: ConnectionType = .wifi
    
    /// WiFi interface is available (associated), even if not the primary path.
    /// THIS IS THE KEY FLAG for FLO communication.
    /// When iOS enables LTE alongside FLO WiFi:
    ///   - connectionType may be .cellular (iOS prefers LTE for internet)
    ///   - wifiAvailable is still true (WiFi is associated to FLO AP)
    /// FLOService checks this flag, NOT connectionType.
    @Published private(set) var wifiAvailable: Bool = true
    
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
    
    /// Optional: WiFi-specific monitor for more reliable WiFi interface tracking.
    /// NWPathMonitor(requiredInterfaceType: .wifi) reports status of JUST the WiFi interface,
    /// independent of what iOS considers the "best" overall path.
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    
    /// Track if we've ever received a path update (avoids acting on initial default values)
    private(set) var hasReceivedInitialUpdate = false
    
    // MARK: - Init
    
    private init() {
        startMonitoring()
    }
    
    deinit {
        monitor.cancel()
        wifiMonitor.cancel()
    }
    
    // MARK: - Monitoring
    
    private func startMonitoring() {
        // Main path monitor — tracks the overall "best" path
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: monitorQueue)
        
        // WiFi-specific monitor — tracks WiFi interface availability independently.
        // This is the key addition for LTE coexistence. When iOS enables LTE
        // alongside FLO WiFi, the main monitor may report cellular as primary,
        // but this monitor will still report .satisfied as long as WiFi is associated.
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleWiFiPathUpdate(path)
            }
        }
        wifiMonitor.start(queue: monitorQueue)
        
        print("[NetworkMonitor] Started monitoring (main + WiFi-specific)")
    }
    
    /// Handle updates from the WiFi-specific monitor.
    /// This fires independently of the main path monitor and tells us
    /// definitively whether the WiFi interface is up, regardless of LTE.
    private func handleWiFiPathUpdate(_ path: NWPath) {
        let wasAvailable = wifiAvailable
        let newAvailable = path.status == .satisfied
        
        wifiAvailable = newAvailable
        
        if wasAvailable != newAvailable {
            print("[NetworkMonitor] WiFi interface: \(newAvailable ? "available" : "unavailable") (independent of primary path)")
            
            // If WiFi went away entirely, FLO is definitely gone
            if !newAvailable {
                if isFLOWiFi {
                    isFLOWiFi = false
                    print("[NetworkMonitor] WiFi interface lost — clearing FLO WiFi state")
                }
            }
            
            // Recalculate hasInternet
            // If WiFi just became available and it's FLO, no internet via WiFi
            // If WiFi went away but we have cellular, we have internet
            recalculateInternetState()
            
            // Notify services
            NotificationCenter.default.post(name: .networkStateChanged, object: nil)
        }
    }
    
    private func handlePathUpdate(_ path: NWPath) {
        let wasConnected = isConnected
        let wasFLO = isFLOWiFi
        let oldType = connectionType
        
        // Determine PRIMARY connection type from the main path monitor
        // IMPORTANT: This is what iOS considers the "best" path for general traffic.
        // When LTE is active alongside FLO WiFi, this will report .cellular.
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
        
        // NOTE: wifiAvailable is updated by the WiFi-specific monitor (handleWiFiPathUpdate).
        // We do NOT set wifiAvailable here based on connectionType — that's the whole point.
        // However, as a safety fallback, if the main path reports WiFi as primary,
        // then WiFi is definitely available.
        if newType == .wifi {
            wifiAvailable = true
        }
        
        // For now, if we transition away from WiFi entirely (no WiFi at all),
        // FLO is definitely not connected. But we rely on the WiFi monitor for this.
        // The main monitor just provides the connectionType for UI display.
        
        // Recalculate internet availability
        recalculateInternetState()
        
        // Log changes
        if !hasReceivedInitialUpdate {
            hasReceivedInitialUpdate = true
            print("[NetworkMonitor] Initial state: \(newType.rawValue), connected=\(newConnected), wifiAvailable=\(wifiAvailable), internet=\(hasInternet)")
        } else if wasConnected != newConnected || oldType != newType || wasFLO != isFLOWiFi {
            print("[NetworkMonitor] Changed: \(oldType.rawValue)→\(newType.rawValue), connected=\(newConnected), wifiAvailable=\(wifiAvailable), FLO=\(isFLOWiFi), internet=\(hasInternet)")
        }
        
        // Post notification for services that aren't observing @Published
        NotificationCenter.default.post(name: .networkStateChanged, object: nil)
    }
    
    // MARK: - Internet State Calculation
    
    /// Recalculate hasInternet based on all available state.
    /// This is called from both the main and WiFi path update handlers.
    ///
    /// Internet is available when:
    ///   - We have cellular (LTE) connectivity, OR
    ///   - We have WiFi that is NOT FLO (i.e., real internet WiFi)
    ///
    /// Internet is NOT available when:
    ///   - We're only on FLO WiFi with no cellular, OR
    ///   - We have no connectivity at all
    private func recalculateInternetState() {
        let hasCellular = connectionType == .cellular || (isConnected && !wifiAvailable)
        let hasInternetWiFi = wifiAvailable && !isFLOWiFi
        
        // KEY INSIGHT for LTE coexistence:
        // When on FLO WiFi + LTE, we have internet via LTE even though
        // WiFi (FLO) doesn't provide internet.
        hasInternet = hasCellular || hasInternetWiFi
        
        // Edge case: if the main path is satisfied and uses cellular, we have internet
        if isConnected && connectionType == .cellular {
            hasInternet = true
        }
    }
    
    // MARK: - External State Updates
    
    /// Called by FLOService when it successfully communicates with 192.168.4.1
    /// This confirms we're on FLO WiFi (local-only, no internet via WiFi)
    func setFLOWiFiConnected(_ connected: Bool) {
        guard isFLOWiFi != connected else { return }
        isFLOWiFi = connected
        
        // Recalculate internet state now that FLO status changed
        recalculateInternetState()
        
        print("[NetworkMonitor] FLO WiFi: \(connected), wifiAvailable=\(wifiAvailable), internet=\(hasInternet)")
    }
    
    // MARK: - Convenience
    
    /// True if we can reach Supabase (has internet, not on FLO-only WiFi)
    var canReachSupabase: Bool {
        hasInternet
    }
    
    /// Human-readable status for UI
    var statusText: String {
        if !isConnected && !wifiAvailable { return "Offline" }
        if isFLOWiFi && connectionType == .cellular { return "FLO WiFi + LTE" }
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

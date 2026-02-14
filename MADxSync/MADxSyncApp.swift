//
//  MADxSyncApp.swift
//  MADxSync
//
//  Main app entry point.
//  Flow: Login → Pick Truck → App
//
//  1. Not authenticated → LoginView
//  2. Authenticated but no truck selected → TruckPickerView
//  3. Authenticated + truck selected → MainTabView
//
//  UPDATED: 2026-02-09 — Added lifecycle management (scenePhase),
//  network monitor integration, and foreground/background handling.
//
//  UPDATED: 2026-02-11 — Banner logic for FLO WiFi + LTE coexistence.
//

import SwiftUI
import UIKit

@main
struct MADxSyncApp: App {
    @StateObject private var authService = AuthService.shared
    @StateObject private var truckService = TruckService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.scenePhase) private var scenePhase
    
    /// Memory pressure observer — logs warnings to diagnose potential black screen issues
    private let memoryObserver: Any? = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
    ) { _ in
        let usage = ProcessInfo.processInfo.physicalMemory > 0
            ? String(format: "%.0f MB used", Double(getMemoryUsage()) / 1_048_576.0)
            : "unknown"
        print("[Memory] ⚠️ Memory warning received — \(usage)")
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(truckService)
                .environmentObject(networkMonitor)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }
    
    // MARK: - Lifecycle Management
    
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
            
        case .active:
            // App came to foreground
            print("[Lifecycle] → Active (from \(oldPhase))")
                    
            // 1. Check auth token validity — refresh if needed, but DON'T sign out on failure
            if authService.isAuthenticated {
                Task {
                    await authService.refreshAccessTokenSafe()
                }
            }
                    
            // 2. Resume FLO polling (FLOService internally checks NetworkMonitor.isFLOWiFi)
            if authService.isAuthenticated {
                        FLOService.shared.resumePolling()
            }
                    
            // 3. NavigationService continues in background (iOS allows background location)
            //    but HeadingArrowView guards prevent animation crashes via applicationState check
                    
            // 4. If we were in background for a while, district data might be stale
            //    DistrictService will use cache if offline
                    
            // 5. Start HUB sync polling (60s interval, pulls pending sources + treatment status)
            if authService.isAuthenticated {
                        HubSyncService.shared.start()
            }
            
        case .inactive:
            // App is transitioning (e.g., notification center pulled down, app switcher)
            // Don't tear anything down yet — this fires briefly during normal use
            print("[Lifecycle] → Inactive")
            
        case .background:
            // App fully backgrounded
            print("[Lifecycle] → Background")
                    
            // 1. Pause FLO polling — no point hitting 192.168.4.1 in background
            FLOService.shared.pausePolling()
                    
            // 2. Stop HUB sync polling — no point polling Supabase in background
            HubSyncService.shared.stop()
                    
            // 3. Cancel non-critical pending work
            //    (NavigationService GPS continues — iOS allows background location updates)
                    
            // 4. Auth timer continues — it's lightweight and needs to keep tokens fresh
            //    for when we come back to foreground
            
        @unknown default:
            print("[Lifecycle] → Unknown phase")
        }
    }
}

// MARK: - Root View (handles auth + truck gate)

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var truckService: TruckService
    @EnvironmentObject var networkMonitor: NetworkMonitor
    
    /// Whether any network banner is currently showing
    private var bannerShowing: Bool {
        if !networkMonitor.isConnected && !networkMonitor.wifiAvailable { return true }
        if networkMonitor.isFLOWiFi { return true }
        return false
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Network status banner — sits ABOVE content so it never covers the FLO toolbar
            if !networkMonitor.isConnected && !networkMonitor.wifiAvailable {
                offlineBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if networkMonitor.isFLOWiFi && networkMonitor.connectionType == .cellular {
                // Best state: FLO WiFi for hardware control + LTE for cloud sync
                floLTEBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if networkMonitor.isFLOWiFi {
                // FLO WiFi only, no LTE
                floWiFiBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // Main content fills remaining space
            Group {
                if !authService.isAuthenticated {
                    LoginView()
                } else if !truckService.hasTruckSelected {
                    TruckPickerView()
                } else {
                    MainTabView()
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut, value: authService.isAuthenticated)
            .animation(.easeInOut, value: truckService.hasTruckSelected)
        }
        .animation(.easeInOut(duration: 0.3), value: networkMonitor.hasInternet)
        .animation(.easeInOut(duration: 0.3), value: networkMonitor.isFLOWiFi)
        .animation(.easeInOut(duration: 0.3), value: networkMonitor.wifiAvailable)
    }
    
    // MARK: - Banners
    
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.bold())
            Text("Offline — using cached data")
                .font(.caption.bold())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.9))
    }
    
    private var floWiFiBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption.bold())
            Text("FLO WiFi — no internet")
                .font(.caption.bold())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.9))
    }
    
    private var floLTEBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption.bold())
            Text("FLO WiFi + LTE")
                .font(.caption.bold())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.green.opacity(0.85))
    }
}

// MARK: - Memory Usage Helper

/// Returns the app's current memory footprint in bytes.
/// Uses task_info to get the actual resident memory size.
private func getMemoryUsage() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

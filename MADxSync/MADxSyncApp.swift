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

import SwiftUI

@main
struct MADxSyncApp: App {
    @StateObject private var authService = AuthService.shared
    @StateObject private var truckService = TruckService.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.scenePhase) private var scenePhase
    
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
            
        case .inactive:
            // App is transitioning (e.g., notification center pulled down, app switcher)
            // Don't tear anything down yet — this fires briefly during normal use
            print("[Lifecycle] → Inactive")
            
        case .background:
            // App fully backgrounded
            print("[Lifecycle] → Background")
            
            // 1. Pause FLO polling — no point hitting 192.168.4.1 in background
            FLOService.shared.pausePolling()
            
            // 2. Cancel non-critical pending work
            //    (NavigationService GPS continues — iOS allows background location updates)
            
            // 3. Auth timer continues — it's lightweight and needs to keep tokens fresh
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
    
    var body: some View {
        ZStack {
            Group {
                if !authService.isAuthenticated {
                    // Step 1: Login
                    LoginView()
                } else if !truckService.hasTruckSelected {
                    // Step 2: Pick a truck
                    TruckPickerView()
                } else {
                    // Step 3: Go
                    MainTabView()
                }
            }
            .animation(.easeInOut, value: authService.isAuthenticated)
            .animation(.easeInOut, value: truckService.hasTruckSelected)
            
            // Offline banner — always visible regardless of auth state
            VStack {
                if !networkMonitor.hasInternet && !networkMonitor.isFLOWiFi {
                    offlineBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if networkMonitor.isFLOWiFi {
                    floWiFiBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.3), value: networkMonitor.hasInternet)
            .animation(.easeInOut(duration: 0.3), value: networkMonitor.isFLOWiFi)
        }
    }
    
    // MARK: - Offline Banner
    
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
}

import SwiftUI
import MapKit
import MapCache

/// Main tab view for MADx iOS app
struct MainTabView: View {
    @StateObject private var syncManager = SyncManager()
    @ObservedObject private var markerStore = MarkerStore.shared
    
    var body: some View {
        TabView {
            // Tab 1: Field Map with FLO controls
            FieldMapView()
                .tabItem {
                    Label("Field", systemImage: "map.fill")
                }
            
            // Tab 2: Sync Status
            SyncView(syncManager: syncManager)
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .badge(syncManager.pendingFiles)
            
            // Tab 3: Settings
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .onAppear {
            syncManager.checkFLOConnection()
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @ObservedObject private var floService = FLOService.shared
    @ObservedObject private var truckService = TruckService.shared
    @State private var showTruckPicker = false
    @State private var isDownloadingMaps = false
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?
    @State private var showDownloadComplete = false
    @State private var showSignOutConfirm = false
    
    var body: some View {
        NavigationView {
            List {
                // District & User
                Section(header: Text("Account")) {
                    if let user = authService.currentUser {
                        HStack {
                            Image(systemName: "building.2.fill")
                                .foregroundColor(.green)
                            Text(user.districtName ?? "Unknown District")
                                .fontWeight(.medium)
                        }
                        
                        if let name = user.userName {
                            HStack {
                                Image(systemName: "person.fill")
                                    .foregroundColor(.blue)
                                Text(name)
                            }
                        }
                        
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.secondary)
                            Text(user.email)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        if let role = user.role {
                            HStack {
                                Image(systemName: "shield.fill")
                                    .foregroundColor(.purple)
                                Text(role.capitalized)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                
                // Truck Identity
                Section(header: Text("Truck")) {
                    HStack {
                        Image(systemName: "truck.box.fill")
                            .foregroundColor(.blue)
                        Text(truckService.selectedTruckName ?? "Not Selected")
                            .fontWeight(.medium)
                        Spacer()
                        if let num = truckService.selectedTruckNumber {
                            Text("#\(num)")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button(action: { showTruckPicker = true }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Switch Truck")
                        }
                    }
                }
                
                // FLO Connection
                Section(header: Text("FLO Hardware")) {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(floService.isConnected ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            Text(floService.isConnected ? "Connected" : "Disconnected")
                        }
                        .foregroundColor(floService.isConnected ? .green : .red)
                    }
                    
                    if floService.isConnected {
                        HStack {
                            Text("Truck")
                            Spacer()
                            Text(floService.truckName)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Firmware")
                            Spacer()
                            Text(floService.firmwareVersion)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button(action: openFLOUI) {
                        HStack {
                            Image(systemName: "safari")
                            Text("Open FLO Web UI")
                        }
                    }
                }
                
                // Map Settings
                Section(header: Text("Offline Maps")) {
                    if isDownloadingMaps {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Downloading District Map...")
                            }
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(.linear)
                            Text("\(Int(downloadProgress * 100))% complete")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button(action: downloadTulareCounty) {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text("Download District Map")
                                    Text("~30-80 MB • Requires WiFi")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        if let error = downloadError {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        if showDownloadComplete {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("District map cached for offline use!")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    
                    Button(role: .destructive, action: clearMapCache) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Map Cache")
                        }
                    }
                }
                
                // Field Polygons
                Section(header: Text("Field Data")) {
                    NavigationLink(destination: Text("Field Polygons - Coming Soon")) {
                        HStack {
                            Image(systemName: "square.on.square")
                                .foregroundColor(.green)
                            Text("Field Polygons")
                        }
                    }
                }
                
                // Data Management
                Section(header: Text("Data")) {
                    HStack {
                        Text("Today's Markers")
                        Spacer()
                        Text("\(MarkerStore.shared.todayCount)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Synced to Cloud")
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.icloud")
                                .foregroundColor(.green)
                            Text("\(MarkerStore.shared.syncedCount)")
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    if MarkerStore.shared.unsyncedCount > 0 {
                        HStack {
                            Text("Waiting to Sync")
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .foregroundColor(.orange)
                                Text("\(MarkerStore.shared.unsyncedCount)")
                            }
                            .foregroundColor(.orange)
                        }
                    }
                    
                    NavigationLink(destination: Text("Export - Coming Soon")) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.orange)
                            Text("Export Local Data")
                        }
                    }
                    
                    if MarkerStore.shared.syncedCount > 0 {
                        Button(role: .destructive, action: clearSyncedMarkers) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear Synced Markers (\(MarkerStore.shared.syncedCount))")
                            }
                        }
                    }
                    
                    if MarkerStore.shared.unsyncedCount > 0 {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("\(MarkerStore.shared.unsyncedCount) marker(s) not yet synced - these will NOT be cleared")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // About
                Section(header: Text("About")) {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Build Date")
                        Spacer()
                        Text("Feb 6, 2026")
                            .foregroundColor(.secondary)
                    }
                }
                
                // Sign Out
                Section {
                    Button(role: .destructive, action: { showSignOutConfirm = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign Out")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showTruckPicker) {
                TruckPickerView(isSheet: true)
            }
            .alert("Sign Out?", isPresented: $showSignOutConfirm) {
                Button("Sign Out", role: .destructive) {
                    truckService.clearSelection()
                    authService.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to log in again and select a truck.")
            }
        }
    }
    
    private func openFLOUI() {
        if let url = URL(string: "http://192.168.4.1") {
            UIApplication.shared.open(url)
        }
    }
    
    private func clearSyncedMarkers() {
        MarkerStore.shared.clearSyncedMarkers()
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }
    
    private func downloadTulareCounty() {
        downloadError = nil
        showDownloadComplete = false
        isDownloadingMaps = true
        downloadProgress = 0
        
        // Compute bounding box dynamically from district boundary geometry
        // Works for ANY district — no hardcoded coordinates
        let bbox = computeDistrictBoundingBox()
        
        guard let bbox = bbox else {
            isDownloadingMaps = false
            downloadError = "No district boundary loaded. Open the map first, then try again."
            return
        }
        
        // Pad slightly (~0.01°) so edges aren't cut off
        let minLat = bbox.minLat - 0.01
        let maxLat = bbox.maxLat + 0.01
        let minLon = bbox.minLon - 0.01
        let maxLon = bbox.maxLon + 0.01
        
        Task {
            do {
                try await downloadMapTiles(
                    minLat: minLat, maxLat: maxLat,
                    minLon: minLon, maxLon: maxLon,
                    minZoom: 10, maxZoom: 16
                )
                
                await MainActor.run {
                    isDownloadingMaps = false
                    showDownloadComplete = true
                    let impact = UINotificationFeedbackGenerator()
                    impact.notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    isDownloadingMaps = false
                    downloadError = "Download failed: \(error.localizedDescription)"
                    let impact = UINotificationFeedbackGenerator()
                    impact.notificationOccurred(.error)
                }
            }
        }
    }
    
    /// Downloads map tiles directly into MapCache's DiskCache so the map
    /// can read them offline. Uses the SAME url template and config as
    /// FieldMapView so cache keys match exactly.
    private func downloadMapTiles(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double, minZoom: Int, maxZoom: Int) async throws {
        
        // CRITICAL: Use the SAME url template as FieldMapView's MapCache config
        // The {s} subdomain is part of the cache key — must match exactly
        let config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        let mapCache = MapCache(withConfig: config)
        
        var totalTiles = 0
        var downloadedTiles = 0
        var failedTiles = 0
        
        // Count total tiles first for progress bar
        for zoom in minZoom...maxZoom {
            let minTileX = lonToTileX(minLon, zoom: zoom)
            let maxTileX = lonToTileX(maxLon, zoom: zoom)
            let minTileY = latToTileY(maxLat, zoom: zoom)
            let maxTileY = latToTileY(minLat, zoom: zoom)
            totalTiles += (maxTileX - minTileX + 1) * (maxTileY - minTileY + 1)
        }
        
        print("[OfflineMap] Starting download: \(totalTiles) tiles, zoom \(minZoom)-\(maxZoom)")
        
        for zoom in minZoom...maxZoom {
            let minTileX = lonToTileX(minLon, zoom: zoom)
            let maxTileX = lonToTileX(maxLon, zoom: zoom)
            let minTileY = latToTileY(maxLat, zoom: zoom)
            let maxTileY = latToTileY(minLat, zoom: zoom)
            
            for x in minTileX...maxTileX {
                for y in minTileY...maxTileY {
                    // Build MKTileOverlayPath — this is what MapCache uses as its cache key
                    let path = MKTileOverlayPath(x: x, y: y, z: zoom, contentScaleFactor: 2.0)
                    
                    // Use MapCache's own loadTile — it fetches from network AND
                    // stores into DiskCache automatically. When the map later
                    // requests this tile, it finds it already cached.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        mapCache.loadTile(at: path) { data, error in
                            if let error = error {
                                print("[OfflineMap] Tile \(zoom)/\(x)/\(y) failed: \(error.localizedDescription)")
                                failedTiles += 1
                            }
                            continuation.resume()
                        }
                    }
                    
                    downloadedTiles += 1
                    let progress = Double(downloadedTiles) / Double(totalTiles)
                    await MainActor.run {
                        self.downloadProgress = progress
                    }
                    
                    // Small delay to avoid hammering OSM servers (they rate limit)
                    // 10ms is fast enough for bulk download but respectful
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            
            print("[OfflineMap] Zoom \(zoom) complete (\(downloadedTiles)/\(totalTiles))")
        }
        
        print("[OfflineMap] Download complete. \(downloadedTiles - failedTiles)/\(totalTiles) tiles cached, \(failedTiles) failed")
    }
    
    private func lonToTileX(_ lon: Double, zoom: Int) -> Int {
        return Int(floor((lon + 180.0) / 360.0 * pow(2.0, Double(zoom))))
    }
    
    private func latToTileY(_ lat: Double, zoom: Int) -> Int {
        let latRad = lat * .pi / 180.0
        return Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * pow(2.0, Double(zoom))))
    }
    
    private func clearMapCache() {
        // Clear MapCache's DiskCache (where tiles are actually stored)
        let config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        let mapCache = MapCache(withConfig: config)
        mapCache.clear {
            print("[OfflineMap] MapCache cleared")
        }
        
        // Also clear URLCache just in case
        URLCache.shared.removeAllCachedResponses()
        
        // Clean up legacy cache directory if it exists
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let diskCacheDir = cacheDir?.appendingPathComponent("DiskCache") {
            try? FileManager.default.removeItem(at: diskCacheDir)
        }
        
        showDownloadComplete = false
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }
    
    /// Compute bounding box from district boundary geometry.
    /// Works for any district — reads from SpatialService which pulls from Supabase.
    private func computeDistrictBoundingBox() -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        let boundaries = SpatialService.shared.boundaries
        guard !boundaries.isEmpty else { return nil }
        
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        
        for boundary in boundaries {
            let coords: [CLLocationCoordinate2D]
            
            switch boundary.geometry {
            case .polygon(let poly):
                coords = poly.outerRing
            case .multiLineString(let multi):
                coords = multi.lines.flatMap { $0 }
            case .lineString(let line):
                coords = line.coordinates2D
            case .multiPolygon(let multi):
                coords = multi.polygons.flatMap { $0 }
            default:
                continue
            }
            
            for coord in coords {
                if coord.latitude < minLat { minLat = coord.latitude }
                if coord.latitude > maxLat { maxLat = coord.latitude }
                if coord.longitude < minLon { minLon = coord.longitude }
                if coord.longitude > maxLon { maxLon = coord.longitude }
            }
        }
        
        // Sanity check — make sure we got valid bounds
        guard minLat < maxLat, minLon < maxLon else { return nil }
        
        print("[OfflineMap] District bbox: \(minLat),\(minLon) → \(maxLat),\(maxLon)")
        return (minLat, maxLat, minLon, maxLon)
    }
}

// MARK: - Preview
#Preview {
    MainTabView()
}

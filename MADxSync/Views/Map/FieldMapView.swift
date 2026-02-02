//
//  FieldMapView.swift
//  MADxSync
//
//  Main map view with spatial layers and rapid tap-to-drop tools
//
//  UPDATED: Uses CompositeFieldOverlay for memory-efficient polygon rendering
//

import SwiftUI
import MapKit
import CoreLocation
import MapCache
import Combine

// MARK: - Active Tool State
enum ActiveTool: Equatable {
    case none
    case treatment
    case larvae
}

/// Main map view with rapid tap-to-drop tools
struct FieldMapView: View {
    @StateObject private var locationManager = LocationManager()
    @StateObject private var spatialService = SpatialService.shared
    @StateObject private var layerVisibility = LayerVisibility()
    @ObservedObject private var floService = FLOService.shared
    @ObservedObject private var markerStore = MarkerStore.shared
    
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.2077, longitude: -119.3473),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    
    // Tool state
    @State private var activeTool: ActiveTool = .none
    
    // Treatment context (persists while tool is active)
    @State private var treatmentFamily: TreatmentFamily = .field
    @State private var treatmentStatus: TreatmentStatus = .treated
    @State private var selectedChemical: String = "BTI Sand"
    @State private var doseValue: Double = 4.0
    @State private var doseUnit: DoseUnit = .oz
    
    // Larvae quick picker
    @State private var showLarvaePicker = false
    @State private var pendingLarvaeCoordinate: CLLocationCoordinate2D?
    
    // Layer sheet
    @State private var showLayerSheet = false
    
    // Feature identification
    @State private var selectedFeature: SelectedFeature?
    @State private var showFeatureInfo = false
    
    var body: some View {
        ZStack {
            // Map with spatial layers
            SpatialMapView(
                region: $mapRegion,
                markers: markerStore.markers,
                spatialService: spatialService,
                layerVisibility: layerVisibility,
                onTap: handleMapTap,
                onFeatureSelected: { feature in
                    selectedFeature = feature
                    showFeatureInfo = true
                    // Haptic feedback on feature tap
                    let impact = UIImpactFeedbackGenerator(style: .rigid)
                    impact.impactOccurred()
                }
            )
            .edgesIgnoringSafeArea(.all)
            
            // UI Overlay
            VStack(spacing: 0) {
                // Top bar: FLO Control + Layer button
                HStack(alignment: .top) {
                    FLOControlView()
                    
                    Spacer()
                    
                    // Layer toggle button
                    LayerButton(
                        showLayerSheet: $showLayerSheet,
                        featureCount: spatialService.totalFeatures
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
                // Context strip RIGHT UNDER FLO (when treatment tool active)
                if activeTool == .treatment {
                    treatmentContextStrip
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                // Bottom bar with GPS + active tool indicator
                bottomBar
            }
            
            // Tool FABs (right side) - positioned independently
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    toolFABColumn
                }
            }
            .padding(.bottom, 60)  // Above bottom bar
            .padding(.trailing, 16)
            
            // Larvae quick picker modal
            if showLarvaePicker {
                larvaeQuickPicker
                    .transition(.opacity)
            }
        }
        .onAppear {
            locationManager.requestPermission()
            
            // Load spatial data if not already loaded
            if !spatialService.hasData {
                Task {
                    await spatialService.loadAllLayers()
                }
            }
        }
        .sheet(isPresented: $showLayerSheet) {
            LayerToggleView(
                visibility: layerVisibility,
                spatialService: spatialService
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFeatureInfo) {
            if let feature = selectedFeature {
                FeatureInfoView(feature: feature)
                    .presentationDetents([.medium, .large])
            }
        }
    }
    
    // MARK: - Handle Map Tap
    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        switch activeTool {
        case .none:
            // No tool active - do nothing (or could show info)
            break
            
        case .treatment:
            // Instant drop treatment marker
            dropTreatmentMarker(at: coordinate)
            
        case .larvae:
            // Show quick picker for larvae level
            pendingLarvaeCoordinate = coordinate
            showLarvaePicker = true
        }
    }
    
    // MARK: - Drop Treatment Marker (instant)
    private func dropTreatmentMarker(at coordinate: CLLocationCoordinate2D) {
        let marker = FieldMarker(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            family: treatmentFamily.rawValue,
            status: treatmentStatus.rawValue,
            chemical: selectedChemical,
            doseValue: doseValue,
            doseUnit: doseUnit.rawValue
        )
        
        markerStore.addMarker(marker)
        
        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        // Sync to FLO if connected
        if floService.isConnected {
            Task {
                let payload = marker.toFLOPayload()
                let success = await floService.postViewerLog(payload: payload)
                if success {
                    markerStore.markSyncedToFLO(marker)
                }
            }
        }
    }
    
    // MARK: - Drop Larvae Marker
    private func dropLarvaeMarker(level: LarvaeLevel, pupae: Bool) {
        guard let coordinate = pendingLarvaeCoordinate else { return }
        
        let marker = FieldMarker(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            larvae: level.rawValue,
            pupaePresent: pupae
        )
        
        markerStore.addMarker(marker)
        
        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        // Sync to FLO if connected
        if floService.isConnected {
            Task {
                let payload = marker.toFLOPayload()
                _ = await floService.postViewerLog(payload: payload)
            }
        }
        
        // Reset
        showLarvaePicker = false
        pendingLarvaeCoordinate = nil
    }
    
    // MARK: - Dose Presets by Unit (matches FLO viewer.tool.js)
    private var dosePresetsForUnit: [Double] {
        switch doseUnit {
        case .oz, .flOz:
            return [0.5, 1, 2, 4, 8]
        case .gal:
            return [0.25, 0.5, 1, 2]
        case .briq:
            return [1, 2, 4]
        case .grams:
            return [10, 25, 50, 100]
        case .ml:
            return [10, 25, 50, 100]
        case .L:
            return [1, 5, 10]
        case .lb:
            return [0.5, 1, 2, 5]
        case .pouch, .packet:
            return [1, 2, 3, 4]
        case .tablet:
            return [1, 2, 4, 8]
        case .each:
            return [10, 25, 50, 100]
        }
    }
    
    // MARK: - Treatment Context Strip
    private var treatmentContextStrip: some View {
        VStack(spacing: 10) {
            // Row 1: Family picker (segmented) + Status toggle
            HStack {
                // Family picker
                Picker("", selection: $treatmentFamily) {
                    ForEach(TreatmentFamily.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                
                Spacer()
                
                // Status toggle (TREATED / OBSERVED)
                Button(action: {
                    treatmentStatus = treatmentStatus == .treated ? .observed : .treated
                }) {
                    Text(treatmentStatus.displayName)
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(treatmentStatus == .treated ? Color.green : Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            
            // Row 2: Chemical + Dose + Unit
            HStack(spacing: 10) {
                // Chemical picker
                Menu {
                    ForEach(ChemicalData.byCategory, id: \.category) { group in
                        Section(group.category.rawValue) {
                            ForEach(group.chemicals) { chem in
                                Button(chem.name) {
                                    selectedChemical = chem.name
                                    // Auto-select sensible unit for chemical
                                    updateUnitForChemical(chem.name)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedChemical)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
                
                Spacer()
                
                // Dose input
                TextField("0", value: $doseValue, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(6)
                
                // Unit picker
                Menu {
                    ForEach(DoseUnit.allCases) { unit in
                        Button(unit.rawValue) {
                            doseUnit = unit
                        }
                    }
                } label: {
                    Text(doseUnit.rawValue)
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(6)
                }
            }
            
            // Row 3: Dose presets (changes based on unit)
            HStack(spacing: 6) {
                ForEach(dosePresetsForUnit, id: \.self) { preset in
                    Button(action: {
                        doseValue = preset
                    }) {
                        Text(formatPreset(preset))
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(doseValue == preset ? Color.blue.opacity(0.3) : Color(.tertiarySystemBackground))
                            .foregroundColor(doseValue == preset ? .blue : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
    
    // Format preset display (remove trailing zeros)
    private func formatPreset(_ value: Double) -> String {
        if value == floor(value) {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.2g", value)
        }
    }
    
    // Auto-select unit based on chemical type
    private func updateUnitForChemical(_ chemName: String) {
        let name = chemName.lowercased()
        
        if name.contains("fish") {
            doseUnit = .each
            doseValue = 25
        } else if name.contains("briq") || name.contains("altosid sr") {
            doseUnit = .briq
            doseValue = 1
        } else if name.contains("pouch") || name.contains("natular") {
            doseUnit = .pouch
            doseValue = 1
        } else if name.contains("wsp") || name.contains("packet") {
            doseUnit = .packet
            doseValue = 1
        } else if name.contains("tablet") || name.contains("dt") {
            doseUnit = .tablet
            doseValue = 1
        } else if name.contains("oil") || name.contains("agnique") || name.contains("mmf") {
            doseUnit = .gal
            doseValue = 0.5
        } else if name.contains("sand") || name.contains("gs") || name.contains("fg") || name.contains("g30") {
            doseUnit = .lb
            doseValue = 1
        } else {
            // Default for liquids
            doseUnit = .oz
            doseValue = 4
        }
    }
    
    // MARK: - Tool FAB Column (right side)
    private var toolFABColumn: some View {
        VStack(spacing: 12) {
            // Treatment Tool
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    activeTool = activeTool == .treatment ? .none : .treatment
                }
            }) {
                Image(systemName: "drop.fill")
                    .font(.title2)
                    .foregroundColor(activeTool == .treatment ? .white : .blue)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .treatment ? Color.blue : Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            
            // Larvae Tool
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    activeTool = activeTool == .larvae ? .none : .larvae
                }
            }) {
                Text("🦟")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .larvae ? Color.green : Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            
            // Undo button (only if markers exist)
            if !markerStore.markers.isEmpty {
                Button(action: undoLastMarker) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title3)
                        .foregroundColor(.orange)
                        .frame(width: 48, height: 48)
                        .background(Color(.systemBackground))
                        .clipShape(Circle())
                        .shadow(radius: 2)
                }
            }
        }
    }
    
    // MARK: - Larvae Quick Picker
    @State private var selectedLarvaeLevel: LarvaeLevel = .few
    @State private var pupaeSelected: Bool = false
    
    private var larvaeQuickPicker: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    showLarvaePicker = false
                    pendingLarvaeCoordinate = nil
                }
            
            // Picker card
            VStack(spacing: 16) {
                Text("Larvae Level")
                    .font(.headline)
                
                // Level buttons - tap to select, tap again to confirm
                HStack(spacing: 12) {
                    ForEach(LarvaeLevel.allCases) { level in
                        Button(action: {
                            selectedLarvaeLevel = level
                        }) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: level.color))
                                        .frame(width: 44, height: 44)
                                    
                                    // Selection ring
                                    if selectedLarvaeLevel == level {
                                        Circle()
                                            .stroke(Color.primary, lineWidth: 3)
                                            .frame(width: 52, height: 52)
                                    }
                                }
                                
                                Text(level.displayName)
                                    .font(.caption)
                                    .foregroundColor(selectedLarvaeLevel == level ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Pupae toggle - big and obvious
                Button(action: {
                    pupaeSelected.toggle()
                }) {
                    HStack {
                        Image(systemName: pupaeSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(pupaeSelected ? .pink : .gray)
                        
                        Text("Pupae Present")
                            .font(.headline)
                        
                        if pupaeSelected {
                            Text("🔴")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(pupaeSelected ? Color.pink.opacity(0.2) : Color(.tertiarySystemBackground))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                
                // Action buttons
                HStack(spacing: 16) {
                    Button("Cancel") {
                        showLarvaePicker = false
                        pendingLarvaeCoordinate = nil
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    
                    Button(action: {
                        dropLarvaeMarker(level: selectedLarvaeLevel, pupae: pupaeSelected)
                        // Reset pupae for next marker (level persists)
                        pupaeSelected = false
                    }) {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Save")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .cornerRadius(10)
                    }
                }
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(radius: 10)
            .padding(32)
        }
    }
    
    // MARK: - Bottom Bar
    private var bottomBar: some View {
        HStack(spacing: 16) {
            // GPS status
            HStack(spacing: 6) {
                Circle()
                    .fill(locationManager.hasLocation ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                if let location = locationManager.location {
                    Text(String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude))
                        .font(.caption.monospacedDigit())
                }
            }
            
            Spacer()
            
            // Active tool indicator
            if activeTool != .none {
                Text(activeTool == .treatment ? "TAP TO DROP 💧" : "TAP FOR LARVAE 🦟")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(activeTool == .treatment ? Color.blue : Color.green)
                    .cornerRadius(12)
            }
            
            // Marker count
            if markerStore.markers.count > 0 {
                Text("\(markerStore.markers.count)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Undo
    private func undoLastMarker() {
        guard !markerStore.markers.isEmpty else { return }
        markerStore.markers.removeLast()
        
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
}

// MARK: - Spatial Map View (with layer rendering)

struct SpatialMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let markers: [FieldMarker]
    @ObservedObject var spatialService: SpatialService
    @ObservedObject var layerVisibility: LayerVisibility
    let onTap: (CLLocationCoordinate2D) -> Void
    let onFeatureSelected: (SelectedFeature) -> Void
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.setRegion(region, animated: false)
        
        // Tap gesture
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapGesture)
        
        // MapCache for offline tiles
        let config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        let mapCache = MapCache(withConfig: config)
        mapView.useCache(mapCache)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.updateCount += 1
        print("[Map] updateUIView called - count: \(context.coordinator.updateCount)")
        
        // Update spatial overlays
        context.coordinator.updateSpatialLayers(mapView: mapView)
        
        // Update marker annotations (smart diff)
        context.coordinator.updateMarkers(mapView: mapView, markers: markers)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SpatialMapView
        var updateCount = 0
        
        // Track what we've added to avoid duplicates
        private var currentBoundaryIds: Set<String> = []
        private var hasFieldOverlay = false
        private var hasPolylineOverlay = false
        private var currentPointSiteIds: Set<String> = []
        private var currentStormDrainIds: Set<String> = []
        
        // Track data versions to detect changes
        private var lastFieldCount = 0
        private var lastPolylineCount = 0
        
        init(_ parent: SpatialMapView) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            
            // When no tool is active, try to identify tapped feature
            // When a tool IS active, pass through to tool handler (drop marker)
            let service = parent.spatialService
            let visibility = parent.layerVisibility
            
            // Hit test against visible layers (only when no tool active for feature ID)
            let feature = SpatialHitTester.hitTest(
                coordinate: coordinate,
                fields: visibility.showFields ? service.fields : [],
                polylines: visibility.showPolylines ? service.polylines : [],
                pointSites: visibility.showPointSites ? service.pointSites : [],
                stormDrains: visibility.showStormDrains ? service.stormDrains : [],
                mapView: mapView
            )
            
            if let feature = feature {
                // Found a feature - show info (works regardless of tool state)
                parent.onFeatureSelected(feature)
                
                // Add highlight overlay for selected feature
                addSelectionHighlight(feature: feature, mapView: mapView)
            } else {
                // No feature found - pass to tool handler
                removeSelectionHighlight(mapView: mapView)
                parent.onTap(coordinate)
            }
        }
        
        // MARK: - Selection Highlight
        
        /// Adds a single bright overlay for the selected feature
        private func addSelectionHighlight(feature: SelectedFeature, mapView: MKMapView) {
            // Remove previous highlight
            removeSelectionHighlight(mapView: mapView)
            
            switch feature {
            case .field(let field):
                if let polygon = field.mkPolygon {
                    polygon.title = "SELECTED_FIELD"
                    mapView.addOverlay(polygon, level: .aboveLabels)
                }
            case .polyline(let line):
                if let polyline = line.mkPolyline {
                    let titled = TitledOverlay(overlay: polyline, type: .polyline, id: "SELECTED_POLYLINE")
                    mapView.addOverlay(titled, level: .aboveLabels)
                }
            default:
                break  // Points are annotations, they highlight via callout
            }
        }
        
        /// Removes highlight overlay
        private func removeSelectionHighlight(mapView: MKMapView) {
            let toRemove = mapView.overlays.filter { overlay in
                if let polygon = overlay as? MKPolygon, polygon.title == "SELECTED_FIELD" {
                    return true
                }
                if let titled = overlay as? TitledOverlay, titled.identifier == "SELECTED_POLYLINE" {
                    return true
                }
                return false
            }
            if !toRemove.isEmpty {
                mapView.removeOverlays(toRemove)
            }
        }
        
        // MARK: - Update Spatial Layers
        
        func updateSpatialLayers(mapView: MKMapView) {
            let service = parent.spatialService
            let visibility = parent.layerVisibility
            
            // Boundaries (still use individual overlays - only 4 of them)
            updateBoundaries(mapView: mapView, show: visibility.showBoundaries, data: service.boundaries)
            
            // Fields - NOW USES COMPOSITE OVERLAY
            updateFieldsComposite(mapView: mapView, show: visibility.showFields, data: service.fields)
            
            // Polylines - NOW USES COMPOSITE OVERLAY
            updatePolylinesComposite(mapView: mapView, show: visibility.showPolylines, data: service.polylines)
            
            // Point Sites (annotations - unchanged)
            updatePointSites(mapView: mapView, show: visibility.showPointSites, data: service.pointSites)
            
            // Storm Drains (annotations - unchanged)
            updateStormDrains(mapView: mapView, show: visibility.showStormDrains, data: service.stormDrains)
        }
        
        private func updateBoundaries(mapView: MKMapView, show: Bool, data: [DistrictBoundary]) {
            let newIds = show ? Set(data.map { $0.id }) : []
            
            if newIds != currentBoundaryIds {
                // Remove old
                let toRemove = mapView.overlays.filter { overlay in
                    if let titled = overlay as? TitledOverlay, titled.layerType == .boundary {
                        return !newIds.contains(titled.identifier)
                    }
                    return false
                }
                mapView.removeOverlays(toRemove)
                
                // Add new
                if show {
                    for boundary in data {
                        for overlay in boundary.mkOverlays {
                            let titled = TitledOverlay(overlay: overlay, type: .boundary, id: boundary.id)
                            mapView.addOverlay(titled, level: .aboveLabels)
                        }
                    }
                }
                
                currentBoundaryIds = newIds
            }
        }
        
        // MARK: - COMPOSITE FIELD OVERLAY (replaces individual polygons)
        
        private func updateFieldsComposite(mapView: MKMapView, show: Bool, data: [FieldPolygon]) {
            let dataChanged = data.count != lastFieldCount
            let visibilityChanged = show != hasFieldOverlay
            
            guard dataChanged || visibilityChanged else { return }
            
            // Remove existing composite overlay
            let toRemove = mapView.overlays.filter { $0 is CompositeFieldOverlay }
            if !toRemove.isEmpty {
                mapView.removeOverlays(toRemove)
                print("[Map] Removed \(toRemove.count) composite field overlay(s)")
            }
            
            // Add new composite if visible and has data
            if show && !data.isEmpty {
                let composite = CompositeFieldOverlay(fields: data)
                mapView.addOverlay(composite, level: .aboveLabels)
                print("[Map] Added CompositeFieldOverlay with \(composite.polygons.count) polygons")
            }
            
            hasFieldOverlay = show && !data.isEmpty
            lastFieldCount = data.count
        }
        
        // MARK: - COMPOSITE POLYLINE OVERLAY (replaces individual polylines)
        
        private func updatePolylinesComposite(mapView: MKMapView, show: Bool, data: [SpatialPolyline]) {
            let dataChanged = data.count != lastPolylineCount
            let visibilityChanged = show != hasPolylineOverlay
            
            guard dataChanged || visibilityChanged else { return }
            
            // Remove existing composite overlay
            let toRemove = mapView.overlays.filter { $0 is CompositePolylineOverlay }
            if !toRemove.isEmpty {
                mapView.removeOverlays(toRemove)
                print("[Map] Removed \(toRemove.count) composite polyline overlay(s)")
            }
            
            // Add new composite if visible and has data
            if show && !data.isEmpty {
                let composite = CompositePolylineOverlay(polylines: data)
                mapView.addOverlay(composite, level: .aboveLabels)
                print("[Map] Added CompositePolylineOverlay with \(composite.polylines.count) polylines")
            }
            
            hasPolylineOverlay = show && !data.isEmpty
            lastPolylineCount = data.count
        }
        
        private func updatePointSites(mapView: MKMapView, show: Bool, data: [PointSite]) {
            let newIds = show ? Set(data.map { $0.id }) : []
            
            if newIds != currentPointSiteIds {
                // Remove old annotations
                let toRemove = mapView.annotations.filter { annotation in
                    if let spatial = annotation as? SpatialAnnotation, spatial.layerType == .pointSite {
                        return !newIds.contains(spatial.identifier)
                    }
                    return false
                }
                mapView.removeAnnotations(toRemove)
                
                if show {
                    for site in data {
                        if let coord = site.coordinate {
                            let annotation = SpatialAnnotation(
                                coordinate: coord,
                                type: .pointSite,
                                id: site.id,
                                title: site.displayName,
                                color: site.markerColor
                            )
                            mapView.addAnnotation(annotation)
                        }
                    }
                }
                
                currentPointSiteIds = newIds
            }
        }
        
        private func updateStormDrains(mapView: MKMapView, show: Bool, data: [StormDrain]) {
            let newIds = show ? Set(data.map { $0.id }) : []
            
            if newIds != currentStormDrainIds {
                let toRemove = mapView.annotations.filter { annotation in
                    if let spatial = annotation as? SpatialAnnotation, spatial.layerType == .stormDrain {
                        return !newIds.contains(spatial.identifier)
                    }
                    return false
                }
                mapView.removeAnnotations(toRemove)
                
                if show {
                    for drain in data {
                        if let coord = drain.coordinate {
                            let annotation = SpatialAnnotation(
                                coordinate: coord,
                                type: .stormDrain,
                                id: drain.id,
                                title: drain.name,
                                color: drain.markerColor
                            )
                            mapView.addAnnotation(annotation)
                        }
                    }
                }
                
                currentStormDrainIds = newIds
            }
        }
        
        // MARK: - Update Markers (existing logic)
        
        func updateMarkers(mapView: MKMapView, markers: [FieldMarker]) {
            let existingAnnotations = mapView.annotations.compactMap { $0 as? MarkerAnnotation }
            let existingIds = Set(existingAnnotations.map { $0.marker.id })
            let newIds = Set(markers.map { $0.id })
            
            // Remove annotations that no longer exist
            let toRemove = existingAnnotations.filter { !newIds.contains($0.marker.id) }
            if !toRemove.isEmpty {
                mapView.removeAnnotations(toRemove)
            }
            
            // Add annotations that are new
            let idsToAdd = newIds.subtracting(existingIds)
            let toAdd = markers.filter { idsToAdd.contains($0.id) }
            for marker in toAdd {
                let annotation = MarkerAnnotation(marker: marker)
                mapView.addAnnotation(annotation)
            }
        }
        
        // MARK: - MKMapViewDelegate
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            
            // Spatial annotations (point sites, storm drains)
            if let spatial = annotation as? SpatialAnnotation {
                let identifier = "SpatialAnnotation"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = true
                }
                
                view?.annotation = annotation
                view?.image = spatial.markerImage
                
                return view
            }
            
            // Field markers (treatment/larvae)
            if let markerAnnotation = annotation as? MarkerAnnotation {
                let identifier = "FieldMarker"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                }
                
                view?.annotation = annotation
                view?.image = markerAnnotation.markerImage
                
                return view
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // SELECTED FIELD HIGHLIGHT - bright overlay for tapped field
            if let polygon = overlay as? MKPolygon, polygon.title == "SELECTED_FIELD" {
                let r = MKPolygonRenderer(polygon: polygon)
                r.strokeColor = UIColor.systemYellow
                r.fillColor = UIColor.systemYellow.withAlphaComponent(0.25)
                r.lineWidth = 3
                return r
            }
            
            // COMPOSITE FIELD OVERLAY - single renderer for all 2,009 polygons!
            if let composite = overlay as? CompositeFieldOverlay {
                return CompositeFieldRenderer(overlay: composite)
            }
            
            // COMPOSITE POLYLINE OVERLAY - single renderer for all 757 polylines!
            if let composite = overlay as? CompositePolylineOverlay {
                return CompositePolylineRenderer(overlay: composite)
            }
            
            // Spatial overlays using TitledOverlay wrapper (boundaries + selected polyline)
            if let titled = overlay as? TitledOverlay {
                switch titled.layerType {
                case .boundary:
                    if let polyline = titled.wrappedOverlay as? MKPolyline {
                        let r = MKPolylineRenderer(polyline: polyline)
                        r.strokeColor = UIColor.purple.withAlphaComponent(0.8)
                        r.lineWidth = 3
                        return r
                    } else if let polygon = titled.wrappedOverlay as? MKPolygon {
                        let r = MKPolygonRenderer(polygon: polygon)
                        r.strokeColor = UIColor.purple.withAlphaComponent(0.8)
                        r.fillColor = UIColor.purple.withAlphaComponent(0.1)
                        r.lineWidth = 3
                        return r
                    }
                    
                case .polyline:
                    if let polyline = titled.wrappedOverlay as? MKPolyline {
                        let r = MKPolylineRenderer(polyline: polyline)
                        // Selected polyline = bright yellow, normal = cyan
                        if titled.identifier == "SELECTED_POLYLINE" {
                            r.strokeColor = UIColor.systemYellow
                            r.lineWidth = 4
                        } else {
                            r.strokeColor = UIColor.cyan.withAlphaComponent(0.8)
                            r.lineWidth = 2
                        }
                        return r
                    }
                    
                default:
                    break
                }
            }
            
            // MapCache tiles
            return mapView.mapCacheRenderer(forOverlay: overlay)
        }
    }
}

// MARK: - Layer Types

enum SpatialLayerType {
    case boundary
    case field
    case polyline
    case pointSite
    case stormDrain
}

// MARK: - Titled Overlay (wrapper for identification)

class TitledOverlay: NSObject, MKOverlay {
    let wrappedOverlay: MKOverlay
    let layerType: SpatialLayerType
    let identifier: String
    let overlayTitle: String?
    
    init(overlay: MKOverlay, type: SpatialLayerType, id: String, title: String? = nil) {
        self.wrappedOverlay = overlay
        self.layerType = type
        self.identifier = id
        self.overlayTitle = title
    }
    
    var coordinate: CLLocationCoordinate2D { wrappedOverlay.coordinate }
    var boundingMapRect: MKMapRect { wrappedOverlay.boundingMapRect }
}

// MARK: - Spatial Annotation (for points)

class SpatialAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let layerType: SpatialLayerType
    let identifier: String
    let annotationTitle: String?
    let color: String
    
    var title: String? { annotationTitle }
    
    init(coordinate: CLLocationCoordinate2D, type: SpatialLayerType, id: String, title: String?, color: String) {
        self.coordinate = coordinate
        self.layerType = type
        self.identifier = id
        self.annotationTitle = title
        self.color = color
    }
    
    var markerImage: UIImage {
        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let ctx = context.cgContext
            let uiColor = UIColor(Color(hex: color))
            
            switch layerType {
            case .pointSite:
                // Circle with fill
                uiColor.setFill()
                UIColor.white.setStroke()
                ctx.setLineWidth(1.5)
                ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                
            case .stormDrain:
                // Small square
                uiColor.setFill()
                UIColor.white.setStroke()
                ctx.setLineWidth(1)
                ctx.fill(CGRect(x: 4, y: 4, width: 12, height: 12))
                ctx.stroke(CGRect(x: 4, y: 4, width: 12, height: 12))
                
            default:
                // Default circle
                uiColor.setFill()
                ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
            }
        }
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    
    @Published var location: CLLocation?
    @Published var hasLocation: Bool = false
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }
    
    func startUpdating() {
        manager.startUpdatingLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        hasLocation = location != nil
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            startUpdating()
        }
    }
}

// MARK: - Marker Annotation (existing)

class MarkerAnnotation: NSObject, MKAnnotation {
    let marker: FieldMarker
    
    var coordinate: CLLocationCoordinate2D { marker.coordinate }
    var title: String? { nil }
    
    init(marker: FieldMarker) {
        self.marker = marker
    }
    
    var markerImage: UIImage {
        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let ctx = context.cgContext
            
            if let larvae = marker.larvae {
                // Dot for larvae
                let color = UIColor(Color(hex: LarvaeLevel(rawValue: larvae)?.color ?? "#2e8b57"))
                color.setFill()
                ctx.fillEllipse(in: CGRect(x: 6, y: 6, width: 12, height: 12))
                
                if marker.pupaePresent {
                    UIColor.systemPink.setStroke()
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
                }
            } else if let family = marker.family {
                // Diamond for treatment
                let colorHex = marker.status == "OBSERVED" ? "#2e8b57" : (TreatmentFamily(rawValue: family)?.color ?? "#ffca28")
                let color = UIColor(Color(hex: colorHex))
                color.setStroke()
                ctx.setLineWidth(2)
                
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 12, y: 2))
                path.addLine(to: CGPoint(x: 22, y: 12))
                path.addLine(to: CGPoint(x: 12, y: 22))
                path.addLine(to: CGPoint(x: 2, y: 12))
                path.close()
                path.stroke()
            }
        }
    }
}

// MARK: - Selected Feature

enum SelectedFeature {
    case field(FieldPolygon)
    case polyline(SpatialPolyline)
    case pointSite(PointSite)
    case stormDrain(StormDrain)
    
    var title: String {
        switch self {
        case .field(let f): return f.displayName
        case .polyline(let p): return p.name ?? "Ditch/Canal"
        case .pointSite(let s): return s.displayName
        case .stormDrain(let d): return d.name ?? "Storm Drain"
        }
    }
    
    var layerType: String {
        switch self {
        case .field: return "Field"
        case .polyline: return "Ditch/Canal"
        case .pointSite: return "Point Site"
        case .stormDrain: return "Storm Drain"
        }
    }
}

// MARK: - Feature Info View

struct FeatureInfoView: View {
    let feature: SelectedFeature
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                switch feature {
                case .field(let field):
                    fieldInfo(field)
                case .polyline(let line):
                    polylineInfo(line)
                case .pointSite(let site):
                    pointSiteInfo(site)
                case .stormDrain(let drain):
                    stormDrainInfo(drain)
                }
            }
            .navigationTitle(feature.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    @ViewBuilder
    private func fieldInfo(_ field: FieldPolygon) -> some View {
        Section("Identification") {
            if let name = field.name {
                infoRow("Name", name)
            }
            if let zone = field.zone {
                infoRow("Zone", zone)
            }
            if let zone2 = field.zone2 {
                infoRow("Zone 2", zone2)
            }
            infoRow("ID", field.id)
        }
        
        Section("Details") {
            if let habitat = field.habitat {
                infoRow("Habitat", habitat)
            }
            if let priority = field.priority {
                infoRow("Priority", priority)
            }
            if let useType = field.use_type {
                infoRow("Use Type", useType)
            }
            if let acres = field.acres {
                infoRow("Acres", String(format: "%.2f", acres))
            }
            if let active = field.active {
                infoRow("Active", active ? "Yes" : "No")
            }
        }
    }
    
    @ViewBuilder
    private func polylineInfo(_ line: SpatialPolyline) -> some View {
        Section("Identification") {
            if let name = line.name {
                infoRow("Name", name)
            }
            if let zone = line.zone {
                infoRow("Zone", zone)
            }
            if let zone2 = line.zone2 {
                infoRow("Zone 2", zone2)
            }
            infoRow("ID", line.id)
        }
        
        Section("Details") {
            if let habitat = line.habitat {
                infoRow("Habitat", habitat)
            }
            if let length = line.length_ft {
                infoRow("Length", String(format: "%.0f ft", length))
            }
            if let width = line.width_ft {
                infoRow("Width", String(format: "%.1f ft", width))
            }
            if let active = line.active {
                infoRow("Active", active ? "Yes" : "No")
            }
        }
    }
    
    @ViewBuilder
    private func pointSiteInfo(_ site: PointSite) -> some View {
        Section("Identification") {
            if let name = site.name {
                infoRow("Name", name)
            }
            if let zone = site.zone {
                infoRow("Zone", zone)
            }
            if let zone2 = site.zone2 {
                infoRow("Zone 2", zone2)
            }
            infoRow("ID", site.id)
        }
        
        Section("Details") {
            if let habitat = site.habitat {
                infoRow("Habitat", habitat)
            }
            if let priority = site.priority {
                infoRow("Priority", priority)
            }
            if let active = site.active {
                infoRow("Active", active ? "Yes" : "No")
            }
        }
    }
    
    @ViewBuilder
    private func stormDrainInfo(_ drain: StormDrain) -> some View {
        Section("Identification") {
            if let name = drain.name {
                infoRow("Name", name)
            }
            if let zone = drain.zone {
                infoRow("Zone", zone)
            }
            if let zone2 = drain.zone2 {
                infoRow("Zone 2", zone2)
            }
            infoRow("ID", drain.id)
        }
        
        Section("Details") {
            if let symbology = drain.symbology {
                infoRow("Status", symbology)
            }
        }
    }
    
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}

// MARK: - Preview

#Preview {
    FieldMapView()
}

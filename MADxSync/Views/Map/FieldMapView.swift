//
//  FieldMapView.swift
//  MADxSync
//
//  Main map view with spatial layers and rapid tap-to-drop tools
//
//  UPDATED: Uses CompositeFieldOverlay for memory-efficient polygon rendering
//  UPDATED: NavigationService replaces LocationManager - adds heading arrow + follow mode
//  UPDATED: Note tool added — field notes sync to source_notes table
//  UPDATED: Snap to point sites and storm drains
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
    case note
}

/// Main map view with rapid tap-to-drop tools
struct FieldMapView: View {
    @StateObject private var navigationService = NavigationService()
    @StateObject private var spatialService = SpatialService.shared
    @StateObject private var layerVisibility = LayerVisibility()
    @StateObject private var treatmentStatusService = TreatmentStatusService.shared
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
    
    // Note quick picker
    @State private var showNotePicker = false
    @State private var pendingNoteCoordinate: CLLocationCoordinate2D?
    @State private var noteInputText: String = ""
    
    // Layer sheet
    @State private var showLayerSheet = false
    
    // Feature identification
    @State private var selectedFeature: SelectedFeature?
    @State private var showFeatureInfo = false
    
    // Track which features were turned green by treatment drops (for undo)
    @State private var treatedFeatureStack: [String] = []
    
    // Larvae picker state
    @State private var selectedLarvaeLevel: LarvaeLevel = .few
    @State private var pupaeSelected: Bool = false
    
    // Snap feedback
    @State private var showSnapToast = false
    @State private var snapSourceName: String = ""
    
    // Force map refresh counter
    @State private var mapRefreshTrigger: Int = 0
    
    var body: some View {
        ZStack {
            // Map with spatial layers
            SpatialMapView(
                region: $mapRegion,
                markers: markerStore.markers,
                refreshTrigger: mapRefreshTrigger,
                spatialService: spatialService,
                layerVisibility: layerVisibility,
                treatmentStatusService: treatmentStatusService,
                navigationService: navigationService,
                activeTool: activeTool,
                onTap: { coordinate, screenPoint in
                    handleMapTap(coordinate, screenPoint: screenPoint)
                },
                onFeatureSelected: { feature in
                    selectedFeature = feature
                    showFeatureInfo = true
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
                    LayerButton(
                        showLayerSheet: $showLayerSheet,
                        featureCount: spatialService.totalFeatures
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                
                // Context strip (when treatment tool active)
                if activeTool == .treatment {
                    treatmentContextStrip
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                
                // Bottom bar with GPS + nav + active tool indicator
                bottomBar
            }
            
            // Tool FABs (right side)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    toolFABColumn
                }
            }
            .padding(.bottom, 60)
            .padding(.trailing, 16)
            
            // Larvae quick picker modal
            if showLarvaePicker {
                larvaeQuickPicker
                    .transition(.opacity)
            }
            
            // Note quick picker modal
            if showNotePicker {
                noteQuickPicker
                    .transition(.opacity)
            }
            
            // Snap toast feedback
            SnapToastView(sourceName: snapSourceName, isVisible: showSnapToast)
                .allowsHitTesting(false)
        }
        .onAppear {
            navigationService.requestPermission()
            
            if !spatialService.hasData {
                Task {
                    await spatialService.loadAllLayers()
                }
            }
            
            Task {
                await treatmentStatusService.syncFromHub()
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
    private func handleMapTap(_ coordinate: CLLocationCoordinate2D, screenPoint: CGPoint) {
        // Check for snap to point sites or storm drains
        let snapResult = SnapService.checkSnap(
            coordinate: coordinate,
            pointSites: spatialService.pointSites,
            stormDrains: spatialService.stormDrains
        )
        
        // Use snapped coordinate if available, otherwise original
        let finalCoordinate = snapResult?.coordinate ?? coordinate
        
        // Show toast if snapped (only for treatment tool)
        if let snap = snapResult, activeTool == .treatment {
            snapSourceName = snap.sourceName
            withAnimation(.easeOut(duration: 0.2)) {
                showSnapToast = true
            }
            
            let impact = UIImpactFeedbackGenerator(style: .rigid)
            impact.impactOccurred()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeIn(duration: 0.2)) {
                    showSnapToast = false
                }
            }
        } else if snapResult != nil {
            // Just haptic for larvae/note snap
            let impact = UIImpactFeedbackGenerator(style: .rigid)
            impact.impactOccurred()
        }
        
        switch activeTool {
        case .none:
            break
        case .treatment:
            dropTreatmentMarker(at: finalCoordinate, snappedTo: snapResult)
        case .larvae:
            pendingLarvaeCoordinate = finalCoordinate
            showLarvaePicker = true
        case .note:
            pendingNoteCoordinate = finalCoordinate
            noteInputText = ""
            showNotePicker = true
        }
    }
    
    // MARK: - Drop Treatment Marker (instant)
    private func dropTreatmentMarker(at coordinate: CLLocationCoordinate2D, snappedTo: SnapResult? = nil) {
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
        
        // Both TREATED and OBSERVED reset the treatment clock (turn green)
        if treatmentStatus == .treated || treatmentStatus == .observed {
            var featureId: String? = nil
            var featureType: String? = nil
            
            // If we snapped to a point site or storm drain, use that directly
            if let snap = snappedTo {
                featureId = snap.sourceId
                featureType = snap.sourceType
            } else {
                // Otherwise do hit test for polygons/polylines
                let hitFeature = SpatialHitTester.hitTest(
                    coordinate: coordinate,
                    fields: spatialService.fields,
                    polylines: spatialService.polylines,
                    pointSites: spatialService.pointSites,
                    stormDrains: spatialService.stormDrains,
                    mapView: nil
                )
                
                if let feature = hitFeature {
                    switch feature {
                    case .field(let f):
                        featureId = f.id
                        featureType = "field"
                    case .polyline(let p):
                        featureId = p.id
                        featureType = "polyline"
                    case .pointSite(let s):
                        featureId = s.id
                        featureType = "pointsite"
                    case .stormDrain(let d):
                        featureId = d.id
                        featureType = "stormdrain"
                    }
                }
            }
            
            if let fId = featureId, let fType = featureType {
                treatmentStatusService.markTreatedLocally(
                    featureId: fId,
                    featureType: fType,
                    chemical: selectedChemical
                )
                treatedFeatureStack.append(fId)
            } else {
                treatedFeatureStack.append("")
            }
        } else {
            treatedFeatureStack.append("")
        }
        
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
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
        
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        if floService.isConnected {
            Task {
                let payload = marker.toFLOPayload()
                _ = await floService.postViewerLog(payload: payload)
            }
        }
        
        showLarvaePicker = false
        pendingLarvaeCoordinate = nil
        
        // Force map to refresh
        mapRefreshTrigger += 1
    }
    
    // MARK: - Drop Note Marker
    private func dropNoteMarker() {
        guard let coordinate = pendingNoteCoordinate else { return }
        guard !noteInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let marker = FieldMarker(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            noteText: noteInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        markerStore.addMarker(marker)
        
        // Notes don't affect treatment status — no feature stack tracking needed
        treatedFeatureStack.append("")
        
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        
        // Notes don't push to FLO viewer_log — they go to source_notes only
        
        showNotePicker = false
        pendingNoteCoordinate = nil
        noteInputText = ""
        
        // Force map to refresh
        mapRefreshTrigger += 1
    }
    
    // MARK: - Dose Presets by Unit
    private var dosePresetsForUnit: [Double] {
        switch doseUnit {
        case .oz, .flOz: return [0.5, 1, 2, 4, 8]
        case .gal: return [0.25, 0.5, 1, 2]
        case .briq: return [1, 2, 4]
        case .grams: return [10, 25, 50, 100]
        case .ml: return [10, 25, 50, 100]
        case .L: return [1, 5, 10]
        case .lb: return [0.5, 1, 2, 5]
        case .pouch, .packet: return [1, 2, 3, 4]
        case .tablet: return [1, 2, 4, 8]
        case .each: return [10, 25, 50, 100]
        }
    }
    
    // MARK: - Treatment Context Strip
    private var treatmentContextStrip: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("", selection: $treatmentFamily) {
                    ForEach(TreatmentFamily.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                
                Spacer()
                
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
            
            HStack(spacing: 10) {
                Menu {
                    ForEach(ChemicalData.byCategory, id: \.category) { group in
                        Section(group.category.rawValue) {
                            ForEach(group.chemicals) { chem in
                                Button(chem.name) {
                                    selectedChemical = chem.name
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
                
                TextField("0", value: $doseValue, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(6)
                
                Menu {
                    ForEach(DoseUnit.allCases) { unit in
                        Button(unit.rawValue) { doseUnit = unit }
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
            
            HStack(spacing: 6) {
                ForEach(dosePresetsForUnit, id: \.self) { preset in
                    Button(action: { doseValue = preset }) {
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
    
    private func formatPreset(_ value: Double) -> String {
        if value == floor(value) {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.2g", value)
        }
    }
    
    private func updateUnitForChemical(_ chemName: String) {
        let name = chemName.lowercased()
        if name.contains("fish") { doseUnit = .each; doseValue = 25 }
        else if name.contains("briq") || name.contains("altosid sr") { doseUnit = .briq; doseValue = 1 }
        else if name.contains("pouch") || name.contains("natular") { doseUnit = .pouch; doseValue = 1 }
        else if name.contains("wsp") || name.contains("packet") { doseUnit = .packet; doseValue = 1 }
        else if name.contains("tablet") || name.contains("dt") { doseUnit = .tablet; doseValue = 1 }
        else if name.contains("oil") || name.contains("agnique") || name.contains("mmf") { doseUnit = .gal; doseValue = 0.5 }
        else if name.contains("sand") || name.contains("gs") || name.contains("fg") || name.contains("g30") { doseUnit = .lb; doseValue = 1 }
        else { doseUnit = .oz; doseValue = 4 }
    }
    
    // MARK: - Tool FAB Column
    private var toolFABColumn: some View {
        VStack(spacing: 12) {
            // Treatment tool
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
            
            // Larvae tool
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
            
            // Note tool
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    activeTool = activeTool == .note ? .none : .note
                }
            }) {
                Image(systemName: "note.text")
                    .font(.title2)
                    .foregroundColor(activeTool == .note ? .white : .orange)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .note ? Color.orange : Color(.systemBackground))
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            
            // Undo
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
    
    // MARK: - Note Quick Picker
    private var noteQuickPicker: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    showNotePicker = false
                    pendingNoteCoordinate = nil
                    noteInputText = ""
                }
            
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "note.text")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("Field Note")
                        .font(.headline)
                }
                
                if let coord = pendingNoteCoordinate {
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                
                TextEditor(text: $noteInputText)
                    .frame(height: 100)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        Group {
                            if noteInputText.isEmpty {
                                Text("Enter note...")
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 12)
                                    .padding(.top, 16)
                                    .allowsHitTesting(false)
                            }
                        },
                        alignment: .topLeading
                    )
                
                HStack(spacing: 16) {
                    Button("Cancel") {
                        showNotePicker = false
                        pendingNoteCoordinate = nil
                        noteInputText = ""
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    
                    Button(action: dropNoteMarker) {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Save")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            noteInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.gray
                                : Color.orange
                        )
                        .cornerRadius(10)
                    }
                    .disabled(noteInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(radius: 10)
            .padding(32)
        }
    }
    
    // MARK: - Larvae Quick Picker
    private var larvaeQuickPicker: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    showLarvaePicker = false
                    pendingLarvaeCoordinate = nil
                }
            
            VStack(spacing: 16) {
                Text("Larvae Level")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    ForEach(LarvaeLevel.allCases) { level in
                        Button(action: { selectedLarvaeLevel = level }) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: level.color))
                                        .frame(width: 44, height: 44)
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
                
                Button(action: { pupaeSelected.toggle() }) {
                    HStack {
                        Image(systemName: pupaeSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(pupaeSelected ? .pink : .gray)
                        Text("Pupae Present")
                            .font(.headline)
                        if pupaeSelected { Text("🔴") }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(pupaeSelected ? Color.pink.opacity(0.2) : Color(.tertiarySystemBackground))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                
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
        HStack(spacing: 12) {
            // Follow button
            Button(action: { navigationService.toggleFollow() }) {
                Image(systemName: navigationService.isFollowing ? "location.fill" : "location")
                    .font(.body)
                    .foregroundColor(navigationService.isFollowing ? .white : .blue)
                    .frame(width: 36, height: 36)
                    .background(navigationService.isFollowing ? Color.blue : Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            
            // GPS status + coordinates
            HStack(spacing: 6) {
                Circle()
                    .fill(navigationService.hasLocation ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                if let location = navigationService.location {
                    Text(String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude))
                        .font(.caption.monospacedDigit())
                }
            }
            
            // Speed
            if let speed = navigationService.speedMPH, speed >= 1 {
                Text(String(format: "%.0f mph", speed))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundColor(.secondary)
            }
            
            // Heading cardinal
            if navigationService.hasHeading {
                Text(headingCardinal(navigationService.heading))
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Active tool indicator
            if activeTool != .none {
                Text(toolIndicatorText)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(toolIndicatorColor)
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
    
    private var toolIndicatorText: String {
        switch activeTool {
        case .none: return ""
        case .treatment: return "TAP TO DROP 💧"
        case .larvae: return "TAP FOR LARVAE 🦟"
        case .note: return "TAP TO NOTE 📝"
        }
    }
    
    private var toolIndicatorColor: Color {
        switch activeTool {
        case .none: return .clear
        case .treatment: return .blue
        case .larvae: return .green
        case .note: return .orange
        }
    }
    
    private func headingCardinal(_ degrees: CLLocationDirection) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return directions[index]
    }
    
    // MARK: - Undo
    private func undoLastMarker() {
        guard !markerStore.markers.isEmpty else { return }
        markerStore.markers.removeLast()
        if let featureId = treatedFeatureStack.popLast(), !featureId.isEmpty {
            treatmentStatusService.revertLocalTreatment(featureId: featureId)
        }
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
}

// MARK: - Spatial Map View (with layer rendering + navigation)

struct SpatialMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let markers: [FieldMarker]
    let refreshTrigger: Int  // <-- Added to force updates
    @ObservedObject var spatialService: SpatialService
    @ObservedObject var layerVisibility: LayerVisibility
    @ObservedObject var treatmentStatusService: TreatmentStatusService
    @ObservedObject var navigationService: NavigationService
    let activeTool: ActiveTool
    let onTap: (CLLocationCoordinate2D, CGPoint) -> Void
    let onFeatureSelected: (SelectedFeature) -> Void
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        context.coordinator.mapViewRef = mapView
        mapView.delegate = context.coordinator
        // We draw our own heading arrow — don't use MapKit's blue dot
        mapView.showsUserLocation = false
        mapView.setRegion(region, animated: false)
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapGesture)
        
        let config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        let mapCache = MapCache(withConfig: config)
        mapView.useCache(mapCache)
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateCount += 1
        
        // Force SwiftUI to track these for re-render
        let _ = navigationService.location
        let _ = navigationService.heading
        let _ = navigationService.isFollowing
        let _ = refreshTrigger  // <-- Track refresh trigger
        
        context.coordinator.updateSpatialLayers(mapView: mapView)
        context.coordinator.updateMarkers(mapView: mapView, markers: markers)
        context.coordinator.updateNavigation(mapView: mapView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SpatialMapView
        var updateCount = 0
        weak var mapViewRef: MKMapView?
        private var markerObserver: Any?
        private var justAddedViaNotification: Set<UUID> = []
        
        private var currentBoundaryIds: Set<String> = []
        private var hasFieldOverlay = false
        private var hasPolylineOverlay = false
        private var hasPointSiteOverlay = false
        private var hasStormDrainOverlay = false
        private var lastFieldCount = 0
        private var lastPolylineCount = 0
        private var lastPointSiteCount = 0
        private var lastStormDrainCount = 0
        private var lastStatusVersion = 0
        private var hasHeadingOverlay = false
        
        init(_ parent: SpatialMapView) {
            self.parent = parent
            super.init()
            
            markerObserver = NotificationCenter.default.addObserver(
                forName: .markerAdded, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self,
                      let marker = notification.object as? FieldMarker,
                      let mapView = self.mapViewRef else { return }
                
                self.justAddedViaNotification.insert(marker.id)
                let annotation = MarkerAnnotation(marker: marker)
                mapView.addAnnotation(annotation)
                
                // Force annotation to appear by selecting and deselecting it
                mapView.selectAnnotation(annotation, animated: false)
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }
        
        deinit {
            if let observer = markerObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            
            // Convert to screen coordinates for overlay positioning
            let screenPoint = gesture.location(in: mapView.superview ?? mapView)
            
            let service = parent.spatialService
            let visibility = parent.layerVisibility
            let toolActive = parent.activeTool != .none
            
            let feature = SpatialHitTester.hitTest(
                coordinate: coordinate,
                fields: visibility.showFields ? service.fields : [],
                polylines: visibility.showPolylines ? service.polylines : [],
                pointSites: visibility.showPointSites ? service.pointSites : [],
                stormDrains: visibility.showStormDrains ? service.stormDrains : [],
                mapView: mapView
            )
            
            if toolActive {
                // Dismiss any open annotation callouts
                mapView.selectedAnnotations.forEach { mapView.deselectAnnotation($0, animated: false) }
                
                removeSelectionHighlight(mapView: mapView)
                parent.onTap(coordinate, screenPoint)
            } else {
                if let feature = feature {
                    parent.onFeatureSelected(feature)
                    addSelectionHighlight(feature: feature, mapView: mapView)
                } else {
                    removeSelectionHighlight(mapView: mapView)
                    parent.onTap(coordinate, screenPoint)
                }
            }
        }
        
        // MARK: - Selection Highlight
        
        private func addSelectionHighlight(feature: SelectedFeature, mapView: MKMapView) {
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
                break
            }
        }
        
        private func removeSelectionHighlight(mapView: MKMapView) {
            let toRemove = mapView.overlays.filter { overlay in
                if let polygon = overlay as? MKPolygon, polygon.title == "SELECTED_FIELD" { return true }
                if let titled = overlay as? TitledOverlay, titled.identifier == "SELECTED_POLYLINE" { return true }
                return false
            }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
        }
        
        // MARK: - Navigation Update
        
        func updateNavigation(mapView: MKMapView) {
            let nav = parent.navigationService
            
            guard nav.hasLocation, let location = nav.location else {
                if hasHeadingOverlay { removeHeadingOverlay(mapView: mapView) }
                return
            }
            
            // Update heading arrow
            updateHeadingOverlay(
                mapView: mapView,
                coordinate: location.coordinate,
                heading: nav.heading,
                accuracy: location.horizontalAccuracy
            )
            
            // Follow mode: keep user centered
            if nav.isFollowing {
                let currentCenter = mapView.centerCoordinate
                let distance = location.distance(from: CLLocation(latitude: currentCenter.latitude, longitude: currentCenter.longitude))
                
                // Only pan if moved >5m (avoids jitter)
                if distance > 5 {
                    let followRegion = MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: nav.followZoomSpan, longitudeDelta: nav.followZoomSpan)
                    )
                    mapView.setRegion(followRegion, animated: true)
                }
            }
        }
        
        private func updateHeadingOverlay(mapView: MKMapView, coordinate: CLLocationCoordinate2D, heading: CLLocationDirection, accuracy: CLLocationAccuracy) {
            removeHeadingOverlay(mapView: mapView)
            let arrow = HeadingArrowOverlay(coordinate: coordinate, heading: heading, accuracy: accuracy)
            mapView.addOverlay(arrow, level: .aboveLabels)
            hasHeadingOverlay = true
        }
        
        private func removeHeadingOverlay(mapView: MKMapView) {
            let toRemove = mapView.overlays.filter { $0 is HeadingArrowOverlay }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            hasHeadingOverlay = false
        }
        
        // MARK: - Detect User Pan (disable follow)
        
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // If user is dragging/pinching the map, disable follow mode
            if let view = mapView.subviews.first,
               let recognizers = view.gestureRecognizers {
                for recognizer in recognizers {
                    if recognizer.state == .began || recognizer.state == .ended {
                        if parent.navigationService.isFollowing {
                            parent.navigationService.isFollowing = false
                        }
                        break
                    }
                }
            }
        }
        
        // MARK: - Update Spatial Layers
        
        func updateSpatialLayers(mapView: MKMapView) {
            let service = parent.spatialService
            let visibility = parent.layerVisibility
            
            updateBoundaries(mapView: mapView, show: visibility.showBoundaries, data: service.boundaries)
            updateFieldsComposite(mapView: mapView, show: visibility.showFields, data: service.fields)
            updatePolylinesComposite(mapView: mapView, show: visibility.showPolylines, data: service.polylines)
            updatePointSites(mapView: mapView, show: visibility.showPointSites, data: service.pointSites)
            updateStormDrains(mapView: mapView, show: visibility.showStormDrains, data: service.stormDrains)
            lastStatusVersion = parent.treatmentStatusService.statusVersion
        }
        
        private func updateBoundaries(mapView: MKMapView, show: Bool, data: [DistrictBoundary]) {
            let newIds = show ? Set(data.map { $0.id }) : []
            if newIds != currentBoundaryIds {
                let toRemove = mapView.overlays.filter { overlay in
                    if let titled = overlay as? TitledOverlay, titled.layerType == .boundary {
                        return !newIds.contains(titled.identifier)
                    }
                    return false
                }
                mapView.removeOverlays(toRemove)
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
        
        private func updateFieldsComposite(mapView: MKMapView, show: Bool, data: [FieldPolygon]) {
            let dataChanged = data.count != lastFieldCount
            let visibilityChanged = show != hasFieldOverlay
            let statusChanged = parent.treatmentStatusService.statusVersion != lastStatusVersion
            guard dataChanged || visibilityChanged || statusChanged else { return }
            
            let toRemove = mapView.overlays.filter { $0 is CompositeFieldOverlay }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            if show && !data.isEmpty {
                let statusService = parent.treatmentStatusService
                let composite = CompositeFieldOverlay(fields: data) { featureId in
                    statusService.colorForFeature(featureId)
                }
                mapView.addOverlay(composite, level: .aboveLabels)
            }
            hasFieldOverlay = show && !data.isEmpty
            lastFieldCount = data.count
        }
        
        private func updatePolylinesComposite(mapView: MKMapView, show: Bool, data: [SpatialPolyline]) {
            let dataChanged = data.count != lastPolylineCount
            let visibilityChanged = show != hasPolylineOverlay
            let statusChanged = parent.treatmentStatusService.statusVersion != lastStatusVersion
            guard dataChanged || visibilityChanged || statusChanged else { return }
            
            let toRemove = mapView.overlays.filter { $0 is CompositePolylineOverlay }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            if show && !data.isEmpty {
                let statusService = parent.treatmentStatusService
                let composite = CompositePolylineOverlay(polylines: data) { featureId in
                    statusService.colorForFeature(featureId)
                }
                mapView.addOverlay(composite, level: .aboveLabels)
            }
            hasPolylineOverlay = show && !data.isEmpty
            lastPolylineCount = data.count
        }
        
        private func updatePointSites(mapView: MKMapView, show: Bool, data: [PointSite]) {
            let dataChanged = data.count != lastPointSiteCount
            let visibilityChanged = show != hasPointSiteOverlay
            let statusChanged = parent.treatmentStatusService.statusVersion != lastStatusVersion
            guard dataChanged || visibilityChanged || statusChanged else { return }
            
            // Remove existing overlay
            let toRemove = mapView.overlays.filter {
                ($0 as? CompositePointOverlay)?.pointType == .pointSite
            }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            
            if show && !data.isEmpty {
                let statusService = parent.treatmentStatusService
                let composite = CompositePointOverlay(pointSites: data) { featureId in
                    statusService.colorForFeature(featureId)
                }
                mapView.addOverlay(composite, level: .aboveLabels)
            }
            
            hasPointSiteOverlay = show && !data.isEmpty
            lastPointSiteCount = data.count
        }
        
        private func updateStormDrains(mapView: MKMapView, show: Bool, data: [StormDrain]) {
            let dataChanged = data.count != lastStormDrainCount
            let visibilityChanged = show != hasStormDrainOverlay
            let statusChanged = parent.treatmentStatusService.statusVersion != lastStatusVersion
            guard dataChanged || visibilityChanged || statusChanged else { return }
            
            // Remove existing overlay
            let toRemove = mapView.overlays.filter {
                ($0 as? CompositePointOverlay)?.pointType == .stormDrain
            }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            
            if show && !data.isEmpty {
                let statusService = parent.treatmentStatusService
                let composite = CompositePointOverlay(stormDrains: data) { featureId in
                    statusService.colorForFeature(featureId)
                }
                mapView.addOverlay(composite, level: .aboveLabels)
            }
            
            hasStormDrainOverlay = show && !data.isEmpty
            lastStormDrainCount = data.count
        }
        
        // MARK: - Update Markers
        
        func updateMarkers(mapView: MKMapView, markers: [FieldMarker]) {
            let existingAnnotations = mapView.annotations.compactMap { $0 as? MarkerAnnotation }
            let existingIds = Set(existingAnnotations.map { $0.marker.id })
            let newIds = Set(markers.map { $0.id })
            
            // Only remove if marker was deleted (not in store anymore)
            // Don't remove markers that exist on map but aren't in the passed array yet
            let markersInStore = Set(MarkerStore.shared.markers.map { $0.id })
            let toRemove = existingAnnotations.filter {
                !markersInStore.contains($0.marker.id) && !justAddedViaNotification.contains($0.marker.id)
            }
            if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }
            
            // Clear the protection for IDs that are now in the markers array
            justAddedViaNotification = justAddedViaNotification.subtracting(newIds)
            
            let idsToAdd = newIds.subtracting(existingIds)
            let toAdd = markers.filter { idsToAdd.contains($0.id) }
            for marker in toAdd {
                mapView.addAnnotation(MarkerAnnotation(marker: marker))
            }
        }
        
        // MARK: - MKMapViewDelegate
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            
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
            
            // SpatialAnnotations are no longer used - point sites and storm drains
            // are now rendered via CompositePointOverlay for better performance
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Heading arrow
            if overlay is HeadingArrowOverlay {
                return HeadingArrowRenderer(overlay: overlay)
            }
            
            // Selected field highlight
            if let polygon = overlay as? MKPolygon, polygon.title == "SELECTED_FIELD" {
                let r = MKPolygonRenderer(polygon: polygon)
                r.strokeColor = UIColor.systemYellow
                r.fillColor = UIColor.systemYellow.withAlphaComponent(0.25)
                r.lineWidth = 3
                return r
            }
            
            // Composite field overlay
            if let composite = overlay as? CompositeFieldOverlay {
                return CompositeFieldRenderer(overlay: composite)
            }
            
            // Composite polyline overlay
            if let composite = overlay as? CompositePolylineOverlay {
                return CompositePolylineRenderer(overlay: composite)
            }
            
            // Composite point overlay (point sites and storm drains)
            if let composite = overlay as? CompositePointOverlay {
                return CompositePointRenderer(overlay: composite)
            }
            
            // Titled overlays (boundaries + selected polyline)
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
// MARK: - Supporting Types (shared)

enum SpatialLayerType {
    case boundary
    case field
    case polyline
    case pointSite
    case stormDrain
}

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
                uiColor.setFill()
                UIColor.white.setStroke()
                ctx.setLineWidth(1.5)
                ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
            case .stormDrain:
                uiColor.setFill()
                UIColor.white.setStroke()
                ctx.setLineWidth(1)
                ctx.fill(CGRect(x: 4, y: 4, width: 12, height: 12))
                ctx.stroke(CGRect(x: 4, y: 4, width: 12, height: 12))
            default:
                uiColor.setFill()
                ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
            }
        }
    }
}

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
            
            // Note marker — flag shape
            if marker.isNote {
                // Flag pole
                UIColor.orange.setStroke()
                ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: 6, y: 4))
                ctx.addLine(to: CGPoint(x: 6, y: 22))
                ctx.strokePath()
                
                // Flag body
                UIColor.orange.setFill()
                let flagPath = UIBezierPath()
                flagPath.move(to: CGPoint(x: 6, y: 4))
                flagPath.addLine(to: CGPoint(x: 20, y: 7))
                flagPath.addLine(to: CGPoint(x: 6, y: 12))
                flagPath.close()
                flagPath.fill()
                
                // White outline for visibility
                UIColor.white.setStroke()
                ctx.setLineWidth(1)
                flagPath.stroke()
                
                return
            }
            
            // Larvae marker — colored dot
            if let larvae = marker.larvae {
                let color = UIColor(Color(hex: LarvaeLevel(rawValue: larvae)?.color ?? "#2e8b57"))
                color.setFill()
                ctx.fillEllipse(in: CGRect(x: 6, y: 6, width: 12, height: 12))
                if marker.pupaePresent {
                    UIColor.systemPink.setStroke()
                    ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
                }
            }
            // Treatment marker — diamond outline
            else if let family = marker.family {
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

struct FeatureInfoView: View {
    let feature: SelectedFeature
    @ObservedObject var treatmentStatusService = TreatmentStatusService.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                treatmentStatusSection
                switch feature {
                case .field(let field): fieldInfo(field)
                case .polyline(let line): polylineInfo(line)
                case .pointSite(let site): pointSiteInfo(site)
                case .stormDrain(let drain): stormDrainInfo(drain)
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
    private var treatmentStatusSection: some View {
        let featureId: String = {
            switch feature {
            case .field(let f): return f.id
            case .polyline(let p): return p.id
            case .pointSite(let s): return s.id
            case .stormDrain(let d): return d.id
            }
        }()
        let status = treatmentStatusService.statusForFeature(featureId)
        Section("Treatment Status") {
            HStack {
                Circle().fill(Color(hex: status.color)).frame(width: 16, height: 16)
                Text(status.statusText).font(.headline).foregroundColor(statusTextColor(status.color))
                if status.isLocalOverride {
                    Spacer()
                    Text("⏳ pending sync").font(.caption).foregroundColor(.secondary)
                }
            }
            if let daysSince = status.daysSince { infoRow("Days Since Treatment", "\(daysSince)") }
            infoRow("Last Treated", status.formattedLastTreated)
            if let by = status.lastTreatedBy { infoRow("Treated By", by) }
            if let chemical = status.lastChemical { infoRow("Chemical", chemical) }
            infoRow("Cycle", "\(status.cycleDays) days")
        }
    }
    
    private func statusTextColor(_ hex: String) -> Color {
        switch hex {
        case TreatmentColors.fresh: return .green
        case TreatmentColors.recent: return .yellow
        case TreatmentColors.aging: return .orange
        case TreatmentColors.overdue, TreatmentColors.never: return .red
        default: return .primary
        }
    }
    
    @ViewBuilder
    private func fieldInfo(_ field: FieldPolygon) -> some View {
        Section("Identification") {
            if let name = field.name { infoRow("Name", name) }
            if let zone = field.zone { infoRow("Zone", zone) }
            if let zone2 = field.zone2 { infoRow("Zone 2", zone2) }
            infoRow("ID", field.id)
        }
        Section("Details") {
            if let habitat = field.habitat { infoRow("Habitat", habitat) }
            if let priority = field.priority { infoRow("Priority", priority) }
            if let useType = field.use_type { infoRow("Use Type", useType) }
            if let acres = field.acres { infoRow("Acres", String(format: "%.2f", acres)) }
            if let active = field.active { infoRow("Active", active ? "Yes" : "No") }
        }
    }
    
    @ViewBuilder
    private func polylineInfo(_ line: SpatialPolyline) -> some View {
        Section("Identification") {
            if let name = line.name { infoRow("Name", name) }
            if let zone = line.zone { infoRow("Zone", zone) }
            if let zone2 = line.zone2 { infoRow("Zone 2", zone2) }
            infoRow("ID", line.id)
        }
        Section("Details") {
            if let habitat = line.habitat { infoRow("Habitat", habitat) }
            if let length = line.length_ft { infoRow("Length", String(format: "%.0f ft", length)) }
            if let width = line.width_ft { infoRow("Width", String(format: "%.1f ft", width)) }
            if let active = line.active { infoRow("Active", active ? "Yes" : "No") }
        }
    }
    
    @ViewBuilder
    private func pointSiteInfo(_ site: PointSite) -> some View {
        Section("Identification") {
            if let name = site.name { infoRow("Name", name) }
            if let zone = site.zone { infoRow("Zone", zone) }
            if let zone2 = site.zone2 { infoRow("Zone 2", zone2) }
            infoRow("ID", site.id)
        }
        Section("Details") {
            if let habitat = site.habitat { infoRow("Habitat", habitat) }
            if let priority = site.priority { infoRow("Priority", priority) }
            if let active = site.active { infoRow("Active", active ? "Yes" : "No") }
        }
    }
    
    @ViewBuilder
    private func stormDrainInfo(_ drain: StormDrain) -> some View {
        Section("Identification") {
            if let name = drain.name { infoRow("Name", name) }
            if let zone = drain.zone { infoRow("Zone", zone) }
            if let zone2 = drain.zone2 { infoRow("Zone 2", zone2) }
            infoRow("ID", drain.id)
        }
        Section("Details") {
            if let symbology = drain.symbology { infoRow("Status", symbology) }
        }
    }
    
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}

#Preview {
    FieldMapView()
}

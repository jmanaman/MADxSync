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
//  UPDATED: HeadingArrowView replaces HeadingArrowOverlay for smooth GPU-composited navigation
//  UPDATED: Dirty flags decouple spatial layer updates from GPS tick updates
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
    case navigate
    case addSource
}

/// Main map view with rapid tap-to-drop tools
struct FieldMapView: View {
    @StateObject private var navigationService = NavigationService()
    @StateObject private var spatialService = SpatialService.shared
    @StateObject private var layerVisibility = LayerVisibility()
    @StateObject private var treatmentStatusService = TreatmentStatusService.shared
    @StateObject private var routeService = RouteService.shared
    @ObservedObject private var floService = FLOService.shared
    @ObservedObject private var markerStore = MarkerStore.shared
    @StateObject private var addSourceTool = AddSourceToolState()
    @ObservedObject private var addSourceService = AddSourceService.shared
    @StateObject private var sourceFinderController = SourceFinderMapController()
    @ObservedObject private var sourceFinderService = SourceFinderService.shared
    @StateObject private var serviceRequestController = ServiceRequestMapController()
    @ObservedObject private var serviceRequestService = ServiceRequestService.shared
    
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.2077, longitude: -119.3473),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    
    @State private var activeTool: ActiveTool = .none
    @State private var treatmentFamily: TreatmentFamily = .field
    @State private var treatmentStatus: TreatmentStatus = .treated
    @State private var selectedChemical: String = "BTI Sand"
    @State private var doseValue: Double = 4.0
    @State private var doseUnit: DoseUnit = .oz
    @State private var showLarvaePicker = false
    @State private var pendingLarvaeCoordinate: CLLocationCoordinate2D?
    @State private var showNotePicker = false
    @State private var pendingNoteCoordinate: CLLocationCoordinate2D?
    @State private var noteInputText: String = ""
    @State private var showLayerSheet = false
    @State private var selectedFeature: SelectedFeature?
    @State private var showFeatureInfo = false
    @State private var treatedFeatureStack: [String] = []
    @State private var selectedLarvaeLevel: LarvaeLevel = .few
    @State private var pupaeSelected: Bool = false
    @State private var showSnapToast = false
    @State private var snapSourceName: String = ""
    @State private var mapRefreshTrigger: Int = 0
    @State private var showRoutePolyline: Bool = false
    
    var body: some View {
        ZStack {
            SpatialMapView(
                region: $mapRegion,
                markers: markerStore.markers,
                refreshTrigger: mapRefreshTrigger,
                spatialService: spatialService,
                layerVisibility: layerVisibility,
                treatmentStatusService: treatmentStatusService,
                navigationService: navigationService,
                routeService: routeService,
                activeTool: activeTool,
                sourceFinderController: sourceFinderController,
                serviceRequestController: serviceRequestController,
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
            
            VStack(spacing: 0) {
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
                
                NavigationBannerView(routeService: routeService) {
                    routeService.cancelNavigation()
                    activeTool = .none
                }
                
                // Source Finder shout-out banner
                if sourceFinderController.showBanner {
                    SourceFinderBannerView(
                        pin: sourceFinderController.bannerPin,
                        currentIndex: sourceFinderController.bannerCurrentIndex,
                        totalCount: sourceFinderController.bannerTotalCount,
                        onDismiss: { sourceFinderController.dismissBanner() },
                        onNavigate: {
                            if let pin = sourceFinderController.bannerPin {
                                sourceFinderController.dismissBanner()
                                Task { await sourceFinderController.navigateToPin(pin) }
                                activeTool = .navigate
                            }
                        }
                    )
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Service Request shout-out banner
                if serviceRequestController.showBanner {
                    ServiceRequestBannerView(
                        request: serviceRequestController.bannerRequest,
                        currentIndex: serviceRequestController.bannerCurrentIndex,
                        totalCount: serviceRequestController.bannerTotalCount,
                        onDismiss: { serviceRequestController.dismissBanner() },
                        onNavigate: {
                            if let req = serviceRequestController.bannerRequest {
                                serviceRequestController.dismissBanner()
                                Task { await serviceRequestController.navigateToRequest(req) }
                                activeTool = .navigate
                            }
                        }
                    )
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if activeTool == .treatment {
                    treatmentContextStrip
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if activeTool == .addSource && addSourceTool.isArmed {
                    AddSourceContextStrip(
                        toolState: addSourceTool,
                        onDone: { finishMultiPointSource() },
                        onUndoVertex: { undoLastAddSourceVertex() },
                        onCancel: { cancelAddSource() }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Spacer()
                bottomBar
            }
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    toolFABColumn
                }
            }
            .padding(.bottom, 60)
            .padding(.trailing, 16)
            
            if showLarvaePicker {
                larvaeQuickPicker
                    .transition(.opacity)
            }
            
            if showNotePicker {
                noteQuickPicker
                    .transition(.opacity)
            }
            
            // Source Finder post-treatment inspection modal
            if sourceFinderController.showInspectionModal, let pin = sourceFinderController.inspectionPin {
                SourceFinderInspectionModal(
                    pin: pin,
                    onSubmit: { findings, recommend in
                        sourceFinderController.submitInspection(findings: findings, recommendPermanent: recommend)
                        mapRefreshTrigger += 1
                    },
                    onCancel: {
                        sourceFinderController.showInspectionModal = false
                        sourceFinderController.inspectionPin = nil
                    }
                )
                .transition(.opacity)
            }
            
            // Service Request post-treatment inspection modal
            if serviceRequestController.showInspectionModal, let req = serviceRequestController.inspectionRequest {
                ServiceRequestInspectionModal(
                    request: req,
                    onSubmit: { findings, recommend in
                        serviceRequestController.submitInspection(findings: findings, recommendPermanent: recommend)
                        mapRefreshTrigger += 1
                    },
                    onCancel: {
                        serviceRequestController.showInspectionModal = false
                        serviceRequestController.inspectionRequest = nil
                    }
                )
                .transition(.opacity)
            }
            
            SnapToastView(sourceName: snapSourceName, isVisible: showSnapToast)
                .allowsHitTesting(false)
        }
        .onAppear {
            navigationService.requestPermission()
            routeService.setNavigationService(navigationService)
            
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
        .sheet(isPresented: $addSourceTool.showForm) {
            AddSourceFormSheet(toolState: addSourceTool)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $sourceFinderController.showDetailSheet) {
            if let pin = sourceFinderController.detailPin {
                SourceFinderDetailView(
                    pin: pin,
                    onNavigate: {
                        sourceFinderController.showDetailSheet = false
                        Task { await sourceFinderController.navigateToPin(pin) }
                        activeTool = .navigate
                    },
                    onMarkInspected: {
                        sourceFinderController.showDetailSheet = false
                        sourceFinderController.inspectionPin = pin
                        sourceFinderController.showInspectionModal = true
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $serviceRequestController.showDetailSheet) {
            if let req = serviceRequestController.detailRequest {
                ServiceRequestDetailView(
                    request: req,
                    onNavigate: {
                        serviceRequestController.showDetailSheet = false
                        Task { await serviceRequestController.navigateToRequest(req) }
                        activeTool = .navigate
                    },
                    onMarkInspected: {
                        serviceRequestController.showDetailSheet = false
                        serviceRequestController.inspectionRequest = req
                        serviceRequestController.showInspectionModal = true
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: routeService.hasArrived) { arrived in
            if arrived {
                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()
                impact.impactOccurred()
            }
        }
    }
    
    // MARK: - Handle Map Tap
    private func handleMapTap(_ coordinate: CLLocationCoordinate2D, screenPoint: CGPoint) {
        let snapResult = SnapService.checkSnap(
            coordinate: coordinate,
            pointSites: layerVisibility.showPointSites ? spatialService.pointSites : [],
            stormDrains: layerVisibility.showStormDrains ? spatialService.stormDrains : [],
            pendingSources: layerVisibility.showPendingSources ? AddSourceService.shared.sources : [],
            sourceFinderPins: SourceFinderService.shared.pins,
            serviceRequestPins: ServiceRequestService.shared.requests
        )
        
        let finalCoordinate = snapResult?.coordinate ?? coordinate
        
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
        case .navigate:
            let feature = SpatialHitTester.hitTest(
                coordinate: finalCoordinate,
                fields: spatialService.fields,
                polylines: spatialService.polylines,
                pointSites: spatialService.pointSites,
                stormDrains: spatialService.stormDrains,
                mapView: nil
            )
            if let feature = feature {
                Task { await startNavigation(to: feature) }
            }
        case .addSource:
            handleAddSourceTap(finalCoordinate)
        }
    }
    
    

        // MARK: - Drop Treatment Marker (with Polyline Snap)
        private func dropTreatmentMarker(at coordinate: CLLocationCoordinate2D, snappedTo: SnapResult? = nil) {
            
            var finalCoordinate = coordinate
            var featureId: String? = nil
            var featureType: String? = nil
            
            // 1. Point site / storm drain snap (existing behavior)
            if let snap = snappedTo {
                finalCoordinate = snap.coordinate
                featureId = snap.sourceId
                featureType = snap.sourceType
            }
            
            // 2. Polyline snap — if not already snapped to a point source
            // Only snap to polylines if the polyline layer is visible
            if featureId == nil && layerVisibility.showPolylines {
                if let snapResult = SpatialHitTester.snapToPolyline(
                    coordinate: coordinate,
                    polylines: spatialService.polylines
                ) {
                    // Snap marker to the nearest point on the polyline
                    finalCoordinate = snapResult.snappedCoordinate
                    featureId = snapResult.polyline.id
                    featureType = "polyline"
                    
                    // Show snap toast
                    snapSourceName = snapResult.polyline.name ?? "Canal/Ditch"
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
                }
            }
            
            // 3. Polygon / other hit test — if still no feature matched
            if featureId == nil {
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
                    case .field(let f): featureId = f.id; featureType = "field"
                    case .polyline(let p): featureId = p.id; featureType = "polyline"
                    case .pointSite(let s): featureId = s.id; featureType = "pointsite"
                    case .stormDrain(let d): featureId = d.id; featureType = "stormdrain"
                    }
                }
            }
            
            // 4. Create marker with snapped coordinate and feature info
            let marker = FieldMarker(
                lat: finalCoordinate.latitude,
                lon: finalCoordinate.longitude,
                family: treatmentFamily.rawValue,
                status: treatmentStatus.rawValue,
                chemical: selectedChemical,
                doseValue: doseValue,
                doseUnit: doseUnit.rawValue,
                featureId: featureId,       // NEW — stored for HUB matching
                featureType: featureType    // NEW — stored for HUB matching
            )
            
            markerStore.addMarker(marker)
            
            // 5. Optimistic local treatment status update
            if treatmentStatus == .treated || treatmentStatus == .observed {
                if let fId = featureId, let fType = featureType {
                    treatmentStatusService.markTreatedLocally(featureId: fId, featureType: fType, chemical: selectedChemical)
                    treatedFeatureStack.append(fId)
                } else {
                    treatedFeatureStack.append("")
                }
            } else {
                treatedFeatureStack.append("")
            }
            
            
            
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            
            // 6. Sync to FLO if connected
            if floService.isConnected {
                Task {
                    let payload = marker.toFLOPayload()
                    let success = await floService.postViewerLog(payload: payload)
                    if success { markerStore.markSyncedToFLO(marker) }
                }
            }
        }
    
    // MARK: - Drop Larvae Marker
    private func dropLarvaeMarker(level: LarvaeLevel, pupae: Bool) {
        guard let coordinate = pendingLarvaeCoordinate else { return }
        let marker = FieldMarker(lat: coordinate.latitude, lon: coordinate.longitude, larvae: level.rawValue, pupaePresent: pupae)
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
        mapRefreshTrigger += 1
    }
    
    // MARK: - Drop Note Marker
    private func dropNoteMarker() {
        guard let coordinate = pendingNoteCoordinate else { return }
        guard !noteInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let marker = FieldMarker(lat: coordinate.latitude, lon: coordinate.longitude, noteText: noteInputText.trimmingCharacters(in: .whitespacesAndNewlines))
        markerStore.addMarker(marker)
        treatedFeatureStack.append("")
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        showNotePicker = false
        pendingNoteCoordinate = nil
        noteInputText = ""
        mapRefreshTrigger += 1
    }
    
    // MARK: - Start Navigation
    private func startNavigation(to feature: SelectedFeature) async {
        let coordinate: CLLocationCoordinate2D
        let name: String
        let type: String
        let id: String
        
        switch feature {
        case .field(let f):
            guard let centroid = f.centroid else { return }
            coordinate = centroid; name = f.displayName; type = "field"; id = f.id
        case .polyline(let p):
            guard let midpoint = p.midpoint else { return }
            coordinate = midpoint; name = p.name ?? "Ditch/Canal"; type = "polyline"; id = p.id
        case .pointSite(let s):
            guard let coord = s.coordinate else { return }
            coordinate = coord; name = s.displayName; type = "pointsite"; id = s.id
        case .stormDrain(let d):
            guard let coord = d.coordinate else { return }
            coordinate = coord; name = d.name ?? "Storm Drain"; type = "stormdrain"; id = d.id
        }
        
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        await routeService.navigateTo(coordinate: coordinate, name: name, type: type, id: id)
    }
    
    // MARK: - Dose Presets
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
                        Text(selectedChemical).font(.subheadline).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground)).cornerRadius(8)
                }
                Spacer()
                TextField("0", value: $doseValue, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60).multilineTextAlignment(.center)
                    .padding(.vertical, 6).background(Color(.secondarySystemBackground)).cornerRadius(6)
                Menu {
                    ForEach(DoseUnit.allCases) { unit in
                        Button(unit.rawValue) { doseUnit = unit }
                    }
                } label: {
                    Text(doseUnit.rawValue).font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground)).cornerRadius(6)
                }
            }
            HStack(spacing: 6) {
                ForEach(dosePresetsForUnit, id: \.self) { preset in
                    Button(action: { doseValue = preset }) {
                        Text(formatPreset(preset))
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 12).padding(.vertical, 6)
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
        value == floor(value) ? String(format: "%.0f", value) : String(format: "%.2g", value)
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
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { activeTool = activeTool == .treatment ? .none : .treatment } }) {
                Image(systemName: "drop.fill").font(.title2)
                    .foregroundColor(activeTool == .treatment ? .white : .blue)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .treatment ? Color.blue : Color(.systemBackground))
                    .clipShape(Circle()).shadow(radius: 4)
            }
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { activeTool = activeTool == .larvae ? .none : .larvae } }) {
                Text("🦟").font(.title2).frame(width: 56, height: 56)
                    .background(activeTool == .larvae ? Color.green : Color(.systemBackground))
                    .clipShape(Circle()).shadow(radius: 4)
            }
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { activeTool = activeTool == .note ? .none : .note } }) {
                Image(systemName: "note.text").font(.title2)
                    .foregroundColor(activeTool == .note ? .white : .orange)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .note ? Color.orange : Color(.systemBackground))
                    .clipShape(Circle()).shadow(radius: 4)
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if activeTool == .navigate { activeTool = .none; routeService.cancelNavigation() }
                    else { activeTool = .navigate }
                }
            }) {
                Image(systemName: "location.circle.fill").font(.title2)
                    .foregroundColor(activeTool == .navigate ? .white : .purple)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .navigate ? Color.purple : Color(.systemBackground))
                    .clipShape(Circle()).shadow(radius: 4)
            }
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if activeTool == .addSource {
                        cancelAddSource()
                    } else {
                        // Safety: clean up any orphaned source from a stuck session
                        if let orphanedId = addSourceTool.activeSourceId {
                            AddSourceService.shared.deleteSource(orphanedId)
                            addSourceTool.reset()
                        }
                        activeTool = .addSource
                        addSourceTool.isActive = true
                        addSourceTool.showForm = true
                    }
                }
            }) {
                Image(systemName: "plus.circle.fill").font(.title2)
                    .foregroundColor(activeTool == .addSource ? .white : .teal)
                    .frame(width: 56, height: 56)
                    .background(activeTool == .addSource ? Color.teal : Color(.systemBackground))
                    .clipShape(Circle()).shadow(radius: 4)
            }
            if !markerStore.markers.isEmpty {
                Button(action: undoLastMarker) {
                    Image(systemName: "arrow.uturn.backward").font(.title3).foregroundColor(.orange)
                        .frame(width: 48, height: 48)
                        .background(Color(.systemBackground)).clipShape(Circle()).shadow(radius: 2)
                }
            }
        }
    }
    
    // MARK: - Note Quick Picker
    private var noteQuickPicker: some View {
        ZStack {
            Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                .onTapGesture { showNotePicker = false; pendingNoteCoordinate = nil; noteInputText = "" }
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "note.text").font(.title2).foregroundColor(.orange)
                    Text("Field Note").font(.headline)
                }
                if let coord = pendingNoteCoordinate {
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                TextEditor(text: $noteInputText)
                    .frame(height: 100).padding(8)
                    .background(Color(.secondarySystemBackground)).cornerRadius(8)
                    .overlay(
                        Group {
                            if noteInputText.isEmpty {
                                Text("Enter note...").foregroundColor(.secondary)
                                    .padding(.leading, 12).padding(.top, 16).allowsHitTesting(false)
                            }
                        }, alignment: .topLeading
                    )
                HStack(spacing: 16) {
                    Button("Cancel") { showNotePicker = false; pendingNoteCoordinate = nil; noteInputText = "" }
                        .foregroundColor(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                    Button(action: dropNoteMarker) {
                        HStack { Image(systemName: "checkmark"); Text("Save") }
                            .font(.headline).foregroundColor(.white)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(noteInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.orange)
                            .cornerRadius(10)
                    }
                    .disabled(noteInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24).background(Color(.systemBackground)).cornerRadius(16).shadow(radius: 10).padding(32)
        }
    }
    
    // MARK: - Larvae Quick Picker
    private var larvaeQuickPicker: some View {
        ZStack {
            Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                .onTapGesture { showLarvaePicker = false; pendingLarvaeCoordinate = nil }
            VStack(spacing: 16) {
                Text("Larvae Level").font(.headline)
                HStack(spacing: 12) {
                    ForEach(LarvaeLevel.allCases) { level in
                        Button(action: { selectedLarvaeLevel = level }) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(Color(hex: level.color)).frame(width: 44, height: 44)
                                    if selectedLarvaeLevel == level {
                                        Circle().stroke(Color.primary, lineWidth: 3).frame(width: 52, height: 52)
                                    }
                                }
                                Text(level.displayName).font(.caption)
                                    .foregroundColor(selectedLarvaeLevel == level ? .primary : .secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                Button(action: { pupaeSelected.toggle() }) {
                    HStack {
                        Image(systemName: pupaeSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundColor(pupaeSelected ? .pink : .gray)
                        Text("Pupae Present").font(.headline)
                        if pupaeSelected { Text("🔴") }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(pupaeSelected ? Color.pink.opacity(0.2) : Color(.tertiarySystemBackground))
                    .cornerRadius(10)
                }.buttonStyle(.plain)
                HStack(spacing: 16) {
                    Button("Cancel") { showLarvaePicker = false; pendingLarvaeCoordinate = nil }
                        .foregroundColor(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                    Button(action: {
                        dropLarvaeMarker(level: selectedLarvaeLevel, pupae: pupaeSelected)
                        pupaeSelected = false
                    }) {
                        HStack { Image(systemName: "checkmark"); Text("Save") }
                            .font(.headline).foregroundColor(.white)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color.green).cornerRadius(10)
                    }
                }
            }
            .padding(24).background(Color(.systemBackground)).cornerRadius(16).shadow(radius: 10).padding(32)
        }
    }
    
    // MARK: - Bottom Bar
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(action: { navigationService.toggleFollow() }) {
                Image(systemName: navigationService.isFollowing ? "location.fill" : "location")
                    .font(.body)
                    .foregroundColor(navigationService.isFollowing ? .white : .blue)
                    .frame(width: 36, height: 36)
                    .background(navigationService.isFollowing ? Color.blue : Color(.secondarySystemBackground))
                    .clipShape(Circle())
            }
            HStack(spacing: 6) {
                Circle().fill(navigationService.hasLocation ? Color.green : Color.red).frame(width: 8, height: 8)
                if let location = navigationService.location {
                    Text(String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude))
                        .font(.caption.monospacedDigit())
                }
            }
            if let speed = navigationService.speedMPH, speed >= 1 {
                Text(String(format: "%.0f mph", speed)).font(.caption.bold().monospacedDigit()).foregroundColor(.secondary)
            }
            if navigationService.hasHeading {
                Text(headingCardinal(navigationService.heading)).font(.caption.bold()).foregroundColor(.secondary)
            }
            Spacer()
            if activeTool != .none {
                Text(toolIndicatorText).font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(toolIndicatorColor).cornerRadius(12)
            }
            if markerStore.markers.count > 0 {
                Text("\(markerStore.markers.count)").font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial)
    }
    
    private var toolIndicatorText: String {
        switch activeTool {
        case .none: return ""
        case .treatment: return "TAP TO DROP 💧"
        case .larvae: return "TAP FOR LARVAE 🦟"
        case .note: return "TAP TO NOTE 📝"
        case .navigate: return "TAP SOURCE TO NAVIGATE 🧭"
        case .addSource:
            if addSourceTool.selectedType.isMultiPoint {
                return "TAP TO DROP VERTEX 📌"
            }
            return "TAP TO PLACE SOURCE 📌"
        }
    }
    
    private var toolIndicatorColor: Color {
        switch activeTool {
        case .none: return .clear
        case .treatment: return .blue
        case .larvae: return .green
        case .note: return .orange
        case .navigate: return .purple
        case .addSource: return .teal
        }
    }
    
    private func headingCardinal(_ degrees: CLLocationDirection) -> String {
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return directions[index]
    }
    
    private func undoLastMarker() {
        guard !markerStore.markers.isEmpty else { return }
        
        // Get the feature ID before undo removes the marker
        let featureId = treatedFeatureStack.popLast() ?? ""
        
        markerStore.undoLast()
        
        // Only revert polygon color if NO other markers remain on this feature
        if !featureId.isEmpty {
            let stillHasMarkers = markerStore.markers.contains { marker in
                marker.featureId == featureId && marker.family != nil
            }
            if !stillHasMarkers {
                treatmentStatusService.revertLocalTreatment(featureId: featureId)
            }
        }
        
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
    
    // MARK: - Add Source Methods
    
    private func handleAddSourceTap(_ coordinate: CLLocationCoordinate2D) {
        guard addSourceTool.isArmed else { return }
        
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            print("[AddSource] ⚠️ Cannot create source — no district_id. Auth may be stale.")
            cancelAddSource()
            return
        }
        
        let service = AddSourceService.shared
        let createdBy = AuthService.shared.currentUser?.userName
            ?? AuthService.shared.currentUser?.email
            ?? "app"
        
        if addSourceTool.selectedType.isMultiPoint {
            if let sourceId = addSourceTool.activeSourceId {
                service.addVertex(to: sourceId, coordinate: coordinate)
            } else {
                let source = PendingSource(
                    districtId: districtId,
                    sourceType: addSourceTool.selectedType,
                    name: addSourceTool.formName,
                    sourceSubtype: addSourceTool.formSubtype,
                    condition: addSourceTool.formCondition,
                    description: addSourceTool.formDescription,
                    geometry: .multiPoint([coordinate]),
                    createdBy: createdBy
                )
                service.createSource(source)
                addSourceTool.activeSourceId = source.id
            }
                addSourceTool.refreshVertexCount()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                mapRefreshTrigger += 1
            
        } else {
            let source = PendingSource(
                districtId: districtId,
                sourceType: addSourceTool.selectedType,
                name: addSourceTool.formName,
                sourceSubtype: addSourceTool.formSubtype,
                condition: addSourceTool.formCondition,
                description: addSourceTool.formDescription,
                geometry: .point(coordinate),
                createdBy: createdBy
            )
            service.createSource(source)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            addSourceTool.reset()
            activeTool = .none
            mapRefreshTrigger += 1
        }
    }
    
    private func finishMultiPointSource() {
            // Set activeTool FIRST — the context strip checks
            // `activeTool == .addSource && addSourceTool.isArmed`
            // so killing activeTool first prevents any partial-state frames
            activeTool = .none
            addSourceTool.reset()
            mapRefreshTrigger += 1
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        
        private func undoLastAddSourceVertex() {
            guard let sourceId = addSourceTool.activeSourceId else { return }
            if AddSourceService.shared.undoLastVertex(sourceId: sourceId) {
                addSourceTool.refreshVertexCount()
                mapRefreshTrigger += 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        
        private func cancelAddSource() {
            if let sourceId = addSourceTool.activeSourceId {
                AddSourceService.shared.deleteSource(sourceId)
            }
            activeTool = .none
            addSourceTool.reset()
            mapRefreshTrigger += 1
        }
}

// MARK: - Spatial Map View (with layer rendering + navigation)

struct SpatialMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let markers: [FieldMarker]
    let refreshTrigger: Int
    @ObservedObject var spatialService: SpatialService
    @ObservedObject var layerVisibility: LayerVisibility
    @ObservedObject var treatmentStatusService: TreatmentStatusService
    @ObservedObject var navigationService: NavigationService
    @ObservedObject var routeService: RouteService
    let activeTool: ActiveTool
    var sourceFinderController: SourceFinderMapController?
    var serviceRequestController: ServiceRequestMapController?
    let onTap: (CLLocationCoordinate2D, CGPoint) -> Void
    let onFeatureSelected: (SelectedFeature) -> Void
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        context.coordinator.mapViewRef = mapView
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.setRegion(region, animated: false)
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapGesture)
        
        let config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        let mapCache = MapCache(withConfig: config)
        mapView.useCache(mapCache)
        
        // Add HeadingArrowView as a subview — NOT an overlay
        let arrowView = HeadingArrowView()
        arrowView.mapView = mapView
        mapView.addSubview(arrowView)
        context.coordinator.headingArrowView = arrowView
        
        // Wire direct GPS callback (bypasses SwiftUI entirely for arrow updates)
        context.coordinator.setupDirectGPSCallback()
        
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        
        // --- DIRTY FLAG EVALUATION ---
        // GPS ticks do NOT trigger spatial updates. The arrow view handles those
        // directly via onLocationUpdate callback from NavigationService.
        
        let coord = context.coordinator
        let spatialDirty = coord.checkSpatialDirty()
        let markersDirty = coord.checkMarkersDirty(markers: markers)
        let routeDirty = coord.checkRouteDirty(routePolyline: routeService.routePolyline)
        
        if spatialDirty { coord.updateSpatialLayers(mapView: mapView) }
        if markersDirty { coord.updateMarkers(mapView: mapView, markers: markers) }
        if routeDirty { coord.updateRouteOverlay(mapView: mapView, routePolyline: routeService.routePolyline) }
        
        // Still read these so SwiftUI calls us when they change (for bottom bar)
        let _ = navigationService.location
        let _ = navigationService.heading
        let _ = navigationService.isFollowing
        let _ = refreshTrigger
        
        // Snap to truck immediately when follow mode is activated
        let isFollowing = navigationService.isFollowing
        if isFollowing && !coord.lastIsFollowing {
            coord.snapToTruck()
        }
        coord.lastIsFollowing = isFollowing
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SpatialMapView
        weak var mapViewRef: MKMapView?
        private var markerObserver: Any?
        private var justAddedViaNotification: Set<UUID> = []
        
        /// GPU-composited heading arrow (replaces HeadingArrowOverlay)
        var headingArrowView: HeadingArrowView?
        
        // Spatial layer tracking
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
        private var hasRouteOverlay = false
        
        // Dirty flag snapshots
        private var lastBoundaryCount = 0
        private var lastShowFields = true
        private var lastShowPolylines = true
        private var lastShowPointSites = true
        private var lastShowStormDrains = true
        private var lastShowBoundaries = true
        private var lastShowPendingSources = true
        private var lastPendingSourceCount = 0
        private var lastPendingVertexCount = 0
        private var lastMarkerCount = 0
        private var lastRoutePolyline: MKPolyline? = nil
        var lastIsFollowing = false
        private var lastSourceFinderCount = 0
        private var lastSourceFinderVersion = 0
        private var lastServiceRequestCount = 0
        private var lastServiceRequestVersion = 0
        
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
                mapView.selectAnnotation(annotation, animated: false)
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }
        
        deinit {
            if let observer = markerObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            parent.navigationService.onLocationUpdate = nil
        }
        
        // MARK: - Direct GPS Callback (bypasses SwiftUI entirely)
        
        func setupDirectGPSCallback() {
            parent.navigationService.onLocationUpdate = { [weak self] location, heading in
                guard let self,
                      let mapView = self.mapViewRef,
                      let arrowView = self.headingArrowView,
                      UIApplication.shared.applicationState == .active else { return }
                
                // Move arrow — GPU composited, sub-millisecond
                arrowView.updatePosition(
                    coordinate: location.coordinate,
                    heading: heading,
                    accuracy: location.horizontalAccuracy,
                    animated: true
                )
                
                // Follow mode — pan map to keep truck centered
                let nav = self.parent.navigationService
                if nav.isFollowing {
                    let currentCenter = mapView.centerCoordinate
                    let distance = location.distance(from: CLLocation(
                        latitude: currentCenter.latitude,
                        longitude: currentCenter.longitude
                    ))
                    if distance > 5 {
                        let followRegion = MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: nav.followZoomSpan, longitudeDelta: nav.followZoomSpan)
                        )
                        mapView.setRegion(followRegion, animated: true)
                    }
                }
            }
        }
        
        /// Called when follow mode is toggled — immediately pans to truck
        func snapToTruck() {
            let nav = parent.navigationService
            guard let mapView = mapViewRef,
                  let location = nav.location else { return }
            
            let followRegion = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: nav.followZoomSpan, longitudeDelta: nav.followZoomSpan)
            )
            mapView.setRegion(followRegion, animated: true)
        }
        
        // MARK: - Dirty Flag Checks
        
        func checkSpatialDirty() -> Bool {
            let service = parent.spatialService
            let visibility = parent.layerVisibility
            let statusVersion = parent.treatmentStatusService.statusVersion
            
            let dirty = service.fields.count != lastFieldCount
                || service.polylines.count != lastPolylineCount
                || service.pointSites.count != lastPointSiteCount
                || service.stormDrains.count != lastStormDrainCount
                || service.boundaries.count != lastBoundaryCount
                || visibility.showFields != lastShowFields
                || visibility.showPolylines != lastShowPolylines
                || visibility.showPointSites != lastShowPointSites
                || visibility.showStormDrains != lastShowStormDrains
                || visibility.showBoundaries != lastShowBoundaries
                || visibility.showPendingSources != lastShowPendingSources
                || AddSourceService.shared.sources.count != lastPendingSourceCount
                || AddSourceService.shared.sources.reduce(0, { $0 + $1.vertexCount }) != lastPendingVertexCount
                || statusVersion != lastStatusVersion
                || SourceFinderService.shared.pins.count != lastSourceFinderCount
                || TreatmentStatusService.shared.statusVersion != lastSourceFinderVersion
                || ServiceRequestService.shared.requests.count != lastServiceRequestCount
            
            lastBoundaryCount = service.boundaries.count
            lastShowFields = visibility.showFields
            lastShowPolylines = visibility.showPolylines
            lastShowPointSites = visibility.showPointSites
            lastShowStormDrains = visibility.showStormDrains
            lastShowBoundaries = visibility.showBoundaries
            lastShowPendingSources = visibility.showPendingSources
            lastPendingSourceCount = AddSourceService.shared.sources.count
            lastPendingVertexCount = AddSourceService.shared.sources.reduce(0, { $0 + $1.vertexCount })
            
            return dirty
        }
        
        func checkMarkersDirty(markers: [FieldMarker]) -> Bool {
            let dirty = markers.count != lastMarkerCount
            lastMarkerCount = markers.count
            return dirty
        }
        
        func checkRouteDirty(routePolyline: MKPolyline?) -> Bool {
            let dirty = routePolyline !== lastRoutePolyline
            lastRoutePolyline = routePolyline
            return dirty
        }
        
        // MARK: - Tap Handling
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
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
                mapView.selectedAnnotations.forEach { mapView.deselectAnnotation($0, animated: false) }
                removeSelectionHighlight(mapView: mapView)
                parent.onTap(coordinate, screenPoint)
            } else {
                // Check Source Finder pins first (they sit above spatial features)
                var handledPin = false
                for annotation in mapView.annotations {
                    if let sfAnnotation = annotation as? SourceFinderAnnotation {
                        let annotationPoint = mapView.convert(sfAnnotation.coordinate, toPointTo: mapView)
                        let distance = hypot(annotationPoint.x - point.x, annotationPoint.y - point.y)
                        if distance < 30 {
                            parent.sourceFinderController?.handlePinTap(sfAnnotation.pin)
                            handledPin = true
                            break
                        }
                    } else if let srAnnotation = annotation as? ServiceRequestAnnotation {
                        let annotationPoint = mapView.convert(srAnnotation.coordinate, toPointTo: mapView)
                        let distance = hypot(annotationPoint.x - point.x, annotationPoint.y - point.y)
                        if distance < 30 {
                            parent.serviceRequestController?.handlePinTap(srAnnotation.request)
                            handledPin = true
                            break
                        }
                    }
                }

                if !handledPin {
                    if let feature = feature {
                        parent.onFeatureSelected(feature)
                        addSelectionHighlight(feature: feature, mapView: mapView)
                    } else {
                        removeSelectionHighlight(mapView: mapView)
                        parent.onTap(coordinate, screenPoint)
                    }
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
            default: break
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
        
        // MARK: - Route Overlay
        
        func updateRouteOverlay(mapView: MKMapView, routePolyline: MKPolyline?) {
            let toRemove = mapView.overlays.filter { $0 is MKPolyline && ($0 as? MKPolyline)?.title == "ROUTE" }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            if let polyline = routePolyline {
                polyline.title = "ROUTE"
                mapView.addOverlay(polyline, level: .aboveLabels)
                hasRouteOverlay = true
            } else {
                hasRouteOverlay = false
            }
        }
        
        // MARK: - Map Region Change Delegates
        
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
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
        
        // Reposition arrow DURING pan/zoom (fires continuously while gesture is active)
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            headingArrowView?.repositionOnMap()
        }
        
        // Reposition arrow AFTER pan/zoom completes (final snap to correct position)
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            headingArrowView?.repositionOnMap()
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
            updatePendingSourceOverlays(mapView: mapView, show: visibility.showPendingSources)
            lastStatusVersion = parent.treatmentStatusService.statusVersion
            updateSourceFinderPins(mapView: mapView)
            updateServiceRequestPins(mapView: mapView)
        }
        
        private func updateServiceRequestPins(mapView: MKMapView) {
            let requests = ServiceRequestService.shared.requests
            let count = requests.count
            let version = TreatmentStatusService.shared.statusVersion

            guard count != lastServiceRequestCount || version != lastServiceRequestVersion else { return }
            lastServiceRequestCount = count
            lastServiceRequestVersion = version

            let existingAnnotations = mapView.annotations.compactMap { $0 as? ServiceRequestAnnotation }
            if !existingAnnotations.isEmpty { mapView.removeAnnotations(existingAnnotations) }

            let existingOverlays = mapView.overlays.filter { $0 is ServiceRequestPulseOverlay }
            if !existingOverlays.isEmpty { mapView.removeOverlays(existingOverlays) }

            guard !requests.isEmpty else { return }

            for req in requests {
                mapView.addAnnotation(ServiceRequestAnnotation(request: req))
            }

            let pendingOnly = requests.filter { ServiceRequestMapController.shouldPulse($0) }
            if !pendingOnly.isEmpty {
                mapView.addOverlay(ServiceRequestPulseOverlay(requests: pendingOnly), level: .aboveLabels)
            }
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
                let composite = CompositeFieldOverlay(fields: data) { featureId in statusService.colorForFeature(featureId) }
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
                let composite = CompositePolylineOverlay(polylines: data) { featureId in statusService.colorForFeature(featureId) }
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
            let toRemove = mapView.overlays.filter { ($0 as? CompositePointOverlay)?.pointType == .pointSite }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            if show && !data.isEmpty {
                let statusService = parent.treatmentStatusService
                let composite = CompositePointOverlay(pointSites: data) { featureId in statusService.colorForFeature(featureId) }
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
            let toRemove = mapView.overlays.filter { ($0 as? CompositePointOverlay)?.pointType == .stormDrain }
            if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }
            if show && !data.isEmpty {
                let statusService = parent.treatmentStatusService
                let composite = CompositePointOverlay(stormDrains: data) { featureId in statusService.colorForFeature(featureId) }
                mapView.addOverlay(composite, level: .aboveLabels)
            }
            hasStormDrainOverlay = show && !data.isEmpty
            lastStormDrainCount = data.count
        }
        
        private func updatePendingSourceOverlays(mapView: MKMapView, show: Bool) {
            // Remove existing pending overlays
            let overlaysToRemove = mapView.overlays.filter { overlay in
                if let composite = overlay as? CompositePointOverlay {
                    return composite.pointType == .pendingPointSite
                        || composite.pointType == .pendingStormDrain
                }
                if let polyline = overlay as? MKPolyline,
                   let title = polyline.title, title.hasPrefix("PENDING_VERTICES_") {
                    return true
                }
                return false
            }
            if !overlaysToRemove.isEmpty { mapView.removeOverlays(overlaysToRemove) }
            
            // Remove existing vertex annotations
            let annotationsToRemove = mapView.annotations.compactMap { $0 as? PendingVertexAnnotation }
            if !annotationsToRemove.isEmpty { mapView.removeAnnotations(annotationsToRemove) }
            
            guard show else { return }
            
            let sources = AddSourceService.shared.sources
            guard !sources.isEmpty else { return }
            
            let statusService = parent.treatmentStatusService
            
            // Pending point sites
            let pendingPoints = sources.filter { $0.sourceType == .pointsite }
            if !pendingPoints.isEmpty {
                let overlay = CompositePointOverlay(
                    pendingSources: pendingPoints,
                    sourceType: .pendingPointSite,
                    colorForFeature: { statusService.colorForFeature($0) }
                )
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
            
            // Pending storm drains
            let pendingDrains = sources.filter { $0.sourceType == .stormdrain }
            if !pendingDrains.isEmpty {
                let overlay = CompositePointOverlay(
                    pendingSources: pendingDrains,
                    sourceType: .pendingStormDrain,
                    colorForFeature: { statusService.colorForFeature($0) }
                )
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
            
            // Multi-point sources → numbered vertex annotations + dotted connecting lines
            let multiPointSources = sources.filter { $0.sourceType.isMultiPoint }
            for source in multiPointSources {
                let coords = source.allCoordinates
                guard !coords.isEmpty else { continue }
                
                for (index, coord) in coords.enumerated() {
                    let annotation = PendingVertexAnnotation(
                        coordinate: coord,
                        vertexNumber: index + 1,
                        sourceId: source.id,
                        sourceType: source.sourceType
                    )
                    mapView.addAnnotation(annotation)
                }
                
                if coords.count >= 2 {
                    var lineCoords = coords
                    // Auto-close polygon shapes so tech sees the actual boundary
                    if source.sourceType == .polygon && coords.count >= 3 {
                        lineCoords.append(coords[0])
                }
                    let polyline = MKPolyline(coordinates: &lineCoords, count: lineCoords.count)
                    polyline.title = "PENDING_VERTICES_\(source.id)"
                    mapView.addOverlay(polyline, level: .aboveLabels)
                }
            }
            
            lastPendingSourceCount = sources.count
        }

        // MARK: - Source Finder Pins

        private func updateSourceFinderPins(mapView: MKMapView) {
            let pins = SourceFinderService.shared.pins
            let count = pins.count
            let version = TreatmentStatusService.shared.statusVersion

            // Rebuild if pin count changed OR treatment status changed (color rotation)
            guard count != lastSourceFinderCount || version != lastSourceFinderVersion else { return }
            lastSourceFinderCount = count
            lastSourceFinderVersion = version

            // Remove existing SF annotations and overlays
            let existingAnnotations = mapView.annotations.compactMap { $0 as? SourceFinderAnnotation }
            if !existingAnnotations.isEmpty { mapView.removeAnnotations(existingAnnotations) }

            let existingOverlays = mapView.overlays.filter { $0 is SourceFinderPulseOverlay }
            if !existingOverlays.isEmpty { mapView.removeOverlays(existingOverlays) }

            guard !pins.isEmpty else { return }

            // Add annotations for all pins
            for pin in pins {
                mapView.addAnnotation(SourceFinderAnnotation(pin: pin))
            }

            // Pulse overlay ONLY for pending pins (not inspected, not treated)
            let pendingOnly = pins.filter { SourceFinderMapController.shouldPulse($0) }
            if !pendingOnly.isEmpty {
                mapView.addOverlay(SourceFinderPulseOverlay(pins: pendingOnly), level: .aboveLabels)
            }
        }
        
        // MARK: - Update Markers
        
        func updateMarkers(mapView: MKMapView, markers: [FieldMarker]) {
            let existingAnnotations = mapView.annotations.compactMap { $0 as? MarkerAnnotation }
            let existingIds = Set(existingAnnotations.map { $0.marker.id })
            let newIds = Set(markers.map { $0.id })
            let markersInStore = Set(MarkerStore.shared.markers.map { $0.id })
            let toRemove = existingAnnotations.filter {
                !markersInStore.contains($0.marker.id) && !justAddedViaNotification.contains($0.marker.id)
            }
            if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }
            justAddedViaNotification = justAddedViaNotification.subtracting(newIds)
            let idsToAdd = newIds.subtracting(existingIds)
            let toAdd = markers.filter { idsToAdd.contains($0.id) }
            for marker in toAdd { mapView.addAnnotation(MarkerAnnotation(marker: marker)) }
        }
        
        // MARK: - MKMapViewDelegate
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            
            if let sfAnnotation = annotation as? SourceFinderAnnotation {
                let id = "SourceFinderPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation

                // Color from TreatmentStatusService — same rotation as all other sources
                view.image = sfAnnotation.markerImage
                view.canShowCallout = false

                // Pulse ONLY if pending (not yet inspected or treated)
                if SourceFinderMapController.shouldPulse(sfAnnotation.pin) {
                    let pulse = CABasicAnimation(keyPath: "transform.scale")
                    pulse.fromValue = 1.0
                    pulse.toValue = 1.3
                    pulse.duration = 1.0
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    view.layer.add(pulse, forKey: "sfPulse")
                } else {
                    view.layer.removeAnimation(forKey: "sfPulse")
                }

                return view
            }
            
            if let srAnnotation = annotation as? ServiceRequestAnnotation {
                let id = "ServiceRequestPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = srAnnotation.markerImage
                view.canShowCallout = false

                if ServiceRequestMapController.shouldPulse(srAnnotation.request) {
                    let pulse = CABasicAnimation(keyPath: "transform.scale")
                    pulse.fromValue = 1.0
                    pulse.toValue = 1.3
                    pulse.duration = 1.0
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    view.layer.add(pulse, forKey: "srPulse")
                } else {
                    view.layer.removeAnimation(forKey: "srPulse")
                }

                return view
            }
            
            if let vertex = annotation as? PendingVertexAnnotation {
                let id = "PendingVertex"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = vertex.markerImage
                view.canShowCallout = false
                return view
            }
            
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
            if let sfOverlay = overlay as? SourceFinderPulseOverlay {
                return SourceFinderPulseRenderer(overlay: sfOverlay)
            }
            
            if let srOverlay = overlay as? ServiceRequestPulseOverlay {
                return ServiceRequestPulseRenderer(overlay: srOverlay)
            }
            
            // Pending source vertex connecting lines (dotted)
            if let polyline = overlay as? MKPolyline,
               let title = polyline.title, title.hasPrefix("PENDING_VERTICES_") {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor.systemTeal.withAlphaComponent(0.6)
                r.lineWidth = 2
                r.lineDashPattern = [8, 6]
                return r
            }
            
            if let polygon = overlay as? MKPolygon, polygon.title == "SELECTED_FIELD" {
                let r = MKPolygonRenderer(polygon: polygon)
                r.strokeColor = UIColor.systemYellow
                r.fillColor = UIColor.systemYellow.withAlphaComponent(0.25)
                r.lineWidth = 3
                return r
            }
            if let polyline = overlay as? MKPolyline, polyline.title == "ROUTE" {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor.systemBlue
                r.lineWidth = 6
                return r
            }
            if let composite = overlay as? CompositeFieldOverlay {
                return CompositeFieldRenderer(overlay: composite)
            }
            if let composite = overlay as? CompositePolylineOverlay {
                return CompositePolylineRenderer(overlay: composite)
            }
            if let composite = overlay as? CompositePointOverlay {
                return CompositePointRenderer(overlay: composite)
            }
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
                            r.strokeColor = UIColor.systemYellow; r.lineWidth = 4
                        } else {
                            r.strokeColor = UIColor.cyan.withAlphaComponent(0.8); r.lineWidth = 2
                        }
                        return r
                    }
                default: break
                }
            }
            return mapView.mapCacheRenderer(forOverlay: overlay)
        }
    }
}

// MARK: - Supporting Types

enum SpatialLayerType { case boundary, field, polyline, pointSite, stormDrain }

class TitledOverlay: NSObject, MKOverlay {
    let wrappedOverlay: MKOverlay; let layerType: SpatialLayerType; let identifier: String; let overlayTitle: String?
    init(overlay: MKOverlay, type: SpatialLayerType, id: String, title: String? = nil) {
        self.wrappedOverlay = overlay; self.layerType = type; self.identifier = id; self.overlayTitle = title
    }
    var coordinate: CLLocationCoordinate2D { wrappedOverlay.coordinate }
    var boundingMapRect: MKMapRect { wrappedOverlay.boundingMapRect }
}

class SpatialAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D; let layerType: SpatialLayerType; let identifier: String
    let annotationTitle: String?; let color: String
    var title: String? { annotationTitle }
    init(coordinate: CLLocationCoordinate2D, type: SpatialLayerType, id: String, title: String?, color: String) {
        self.coordinate = coordinate; self.layerType = type; self.identifier = id; self.annotationTitle = title; self.color = color
    }
    var markerImage: UIImage {
        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            let uiColor = UIColor(Color(hex: color))
            switch layerType {
            case .pointSite:
                uiColor.setFill(); UIColor.white.setStroke(); ctx.setLineWidth(1.5)
                ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                ctx.strokeEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
            case .stormDrain:
                uiColor.setFill(); UIColor.white.setStroke(); ctx.setLineWidth(1)
                ctx.fill(CGRect(x: 4, y: 4, width: 12, height: 12))
                ctx.stroke(CGRect(x: 4, y: 4, width: 12, height: 12))
            default:
                uiColor.setFill(); ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
            }
        }
    }
}

class MarkerAnnotation: NSObject, MKAnnotation {
    let marker: FieldMarker
    var coordinate: CLLocationCoordinate2D { marker.coordinate }
    var title: String? { nil }
    init(marker: FieldMarker) { self.marker = marker }
    var markerImage: UIImage {
        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            if marker.isNote {
                UIColor.orange.setStroke(); ctx.setLineWidth(2)
                ctx.move(to: CGPoint(x: 6, y: 4)); ctx.addLine(to: CGPoint(x: 6, y: 22)); ctx.strokePath()
                UIColor.orange.setFill()
                let flagPath = UIBezierPath()
                flagPath.move(to: CGPoint(x: 6, y: 4))
                flagPath.addLine(to: CGPoint(x: 20, y: 7))
                flagPath.addLine(to: CGPoint(x: 6, y: 12))
                flagPath.close(); flagPath.fill()
                UIColor.white.setStroke(); ctx.setLineWidth(1); flagPath.stroke()
                return
            }
            if let larvae = marker.larvae {
                let color = UIColor(Color(hex: LarvaeLevel(rawValue: larvae)?.color ?? "#2e8b57"))
                color.setFill(); ctx.fillEllipse(in: CGRect(x: 6, y: 6, width: 12, height: 12))
                if marker.pupaePresent {
                    UIColor.systemPink.setStroke(); ctx.setLineWidth(2)
                    ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
                }
            } else if let family = marker.family {
                let colorHex = marker.status == "OBSERVED" ? "#2e8b57" : (TreatmentFamily(rawValue: family)?.color ?? "#ffca28")
                let color = UIColor(Color(hex: colorHex))
                color.setStroke(); ctx.setLineWidth(2)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 12, y: 2)); path.addLine(to: CGPoint(x: 22, y: 12))
                path.addLine(to: CGPoint(x: 12, y: 22)); path.addLine(to: CGPoint(x: 2, y: 12))
                path.close(); path.stroke()
            }
        }
    }
}

enum SelectedFeature {
    case field(FieldPolygon), polyline(SpatialPolyline), pointSite(PointSite), stormDrain(StormDrain)
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
        case .field: return "Field"; case .polyline: return "Ditch/Canal"
        case .pointSite: return "Point Site"; case .stormDrain: return "Storm Drain"
        }
    }
}



struct FeatureInfoView: View {
    let feature: SelectedFeature
    @ObservedObject var treatmentStatusService = TreatmentStatusService.shared
    @Environment(\.dismiss) var dismiss
    @State private var showCycleConfirm = false
    @State private var pendingCycleDays: Int = 7
    
    /// Feature identifiers extracted once
    private var featureId: String {
        switch feature {
        case .field(let f): return f.id
        case .polyline(let p): return p.id
        case .pointSite(let s): return s.id
        case .stormDrain(let d): return d.id
        }
    }
    
    private var featureType: String {
        switch feature {
        case .field: return "field"
        case .polyline: return "polyline"
        case .pointSite: return "pointsite"
        case .stormDrain: return "stormdrain"
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                treatmentStatusSection
                cycleDaysSection
                
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
            .alert("Change Cycle?", isPresented: $showCycleConfirm) {
                Button("Set to \(pendingCycleDays) days", role: .none) {
                    applyCycleChange(pendingCycleDays)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This source will rotate green → yellow → orange → red over \(pendingCycleDays) days instead of \(treatmentStatusService.statusForFeature(featureId).cycleDays) days.")
            }
        }
    }
    
    // MARK: - Treatment Status Section
    
    @ViewBuilder private var treatmentStatusSection: some View {
        let status = treatmentStatusService.statusForFeature(featureId)
        
        Section("Treatment Status") {
            HStack {
                Circle()
                    .fill(Color(hex: status.color))
                    .frame(width: 16, height: 16)
                Text(status.statusText)
                    .font(.headline)
                    .foregroundColor(statusTextColor(status.color))
                if status.isLocalOverride {
                    Spacer()
                    Text("⏳ pending sync")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let daysSince = status.daysSince {
                infoRow("Days Since Treatment", "\(daysSince)")
            }
            infoRow("Last Treated", status.formattedLastTreated)
            if let by = status.lastTreatedBy { infoRow("Treated By", by) }
            if let chemical = status.lastChemical { infoRow("Chemical", chemical) }
            infoRow("Cycle", "\(status.cycleDays) days")
        }
    }
    
    // MARK: - Cycle Days Section (The Push-Off Tool)
    
    @ViewBuilder private var cycleDaysSection: some View {
        let status = treatmentStatusService.statusForFeature(featureId)
        let currentCycle = status.cycleDays
        
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .foregroundColor(.blue)
                    Text("Treatment Cycle")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(currentCycle)d")
                        .font(.caption.monospacedDigit().bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                }
                
                // Chip row — wrapping layout for all presets
                CycleDayChipRow(
                    currentCycle: currentCycle,
                    onSelect: { days in
                        if days != currentCycle {
                            pendingCycleDays = days
                            showCycleConfirm = true
                        }
                    }
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("Push Off")
        } footer: {
            Text("How often this source needs treatment. Colors rotate proportionally across the cycle.")
                .font(.caption2)
        }
    }
    
    // MARK: - Apply Cycle Change
    
    private func applyCycleChange(_ days: Int) {
        Task {
            _ = await treatmentStatusService.updateCycleDays(
                featureId: featureId,
                featureType: featureType,
                cycleDays: days
            )
            
            // Haptic feedback
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        }
    }
    
    // MARK: - Existing Detail Sections (unchanged)
    
    private func statusTextColor(_ hex: String) -> Color {
        switch hex {
        case TreatmentColors.fresh: return .green
        case TreatmentColors.recent: return .yellow
        case TreatmentColors.aging: return .orange
        case TreatmentColors.overdue, TreatmentColors.never: return .red
        default: return .primary
        }
    }
    
    @ViewBuilder private func fieldInfo(_ field: FieldPolygon) -> some View {
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
    
    @ViewBuilder private func polylineInfo(_ line: SpatialPolyline) -> some View {
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
    
    @ViewBuilder private func pointSiteInfo(_ site: PointSite) -> some View {
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
    
    @ViewBuilder private func stormDrainInfo(_ drain: StormDrain) -> some View {
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

// MARK: - Cycle Day Chip Row

struct CycleDayChipRow: View {
    let currentCycle: Int
    let onSelect: (Int) -> Void
    
    // Preset values — covers all practical scenarios
    private let presets = [7, 14, 21, 30, 60, 90, 120, 180, 360]
    
    var body: some View {
        // Two rows of chips for easy tapping with gloves
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(presets.prefix(5), id: \.self) { days in
                    CycleDayChip(
                        days: days,
                        isSelected: currentCycle == days,
                        onTap: { onSelect(days) }
                    )
                }
            }
            HStack(spacing: 6) {
                ForEach(presets.suffix(4), id: \.self) { days in
                    CycleDayChip(
                        days: days,
                        isSelected: currentCycle == days,
                        onTap: { onSelect(days) }
                    )
                }
                Spacer()
            }
            
            // Show indicator if current cycle isn't a preset
            if !presets.contains(currentCycle) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("Custom: \(currentCycle) days (set from Hub)")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Individual Chip

struct CycleDayChip: View {
    let days: Int
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            Text(chipLabel)
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minWidth: 44, minHeight: 36)  // Minimum tap target for gloves
                .background(isSelected ? Color.blue : Color(.tertiarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    private var chipLabel: String {
        if days < 30 { return "\(days)d" }
        if days == 30 { return "30d" }
        if days == 60 { return "60d" }
        if days == 90 { return "90d" }
        if days == 120 { return "120d" }
        if days == 180 { return "6mo" }
        if days == 360 { return "1yr" }
        return "\(days)d"
    }
}
#Preview { FieldMapView() }

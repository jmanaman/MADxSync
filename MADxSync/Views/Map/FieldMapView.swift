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
    
    var body: some View {
        ZStack {
            // Map - isolated from animations
            MapViewRepresentable(
                region: $mapRegion,
                markers: markerStore.markers,
                onTap: handleMapTap
            )
            .edgesIgnoringSafeArea(.all)
            
            // UI Overlay
            VStack(spacing: 0) {
                // FLO Control Panel (top)
                FLOControlView()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                
                Spacer()
                
                // Context strip (visible when treatment tool active)
                if activeTool == .treatment {
                    treatmentContextStrip
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.2), value: activeTool)
                }
                
                // Bottom bar with GPS + tool buttons
                bottomBar
            }
            
            // Tool FABs (right side)
            toolFABs
                .animation(.easeInOut(duration: 0.15), value: activeTool)
            
            // Larvae quick picker modal
            if showLarvaePicker {
                larvaeQuickPicker
                    .transition(.opacity)
            }
        }
        .onAppear {
            locationManager.requestPermission()
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
    
    // MARK: - Tool FABs
    private var toolFABs: some View {
        VStack(spacing: 12) {
            Spacer()
            
            // Treatment Tool
            Button(action: {
                withAnimation {
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
                withAnimation {
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
            
            // Undo button
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
        .padding(.trailing, 16)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .trailing)
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

// MARK: - Map View Representable
struct MapViewRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let markers: [FieldMarker]
    let onTap: (CLLocationCoordinate2D) -> Void
    
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
        // Smart diff - only update what changed (prevents flickering)
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
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewRepresentable
        
        init(_ parent: MapViewRepresentable) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onTap(coordinate)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let markerAnnotation = annotation as? MarkerAnnotation else { return nil }
            
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
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            return mapView.mapCacheRenderer(forOverlay: overlay)
        }
    }
}

// MARK: - Marker Annotation
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

// MARK: - Preview
#Preview {
    FieldMapView()
}

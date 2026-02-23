//
//  SourceFinderMapController.swift
//  MADxSync
//
//  Manages Source Finder pin rendering on the MapKit map, tap interaction,
//  shout-out banner display, and the post-treatment recommendation modal.
//
//  COLOR RULES (simple, status-based):
//  - pending + not inspected  = orange (urgent = red), pulsing
//  - inspected (not treated)  = orange (urgent = red), NO pulse (acknowledged)
//  - treated (diamond dropped) = green, no pulse
//
//  PULSE RULES:
//  - Pending (not yet inspected) = pulsing (the nag)
//  - Inspected = pulse stops (acknowledged, but not yet treated)
//  - Treated = pulse stops, pin turns green
//
//  The inspection modal ONLY appears when the tech taps a pin (no tool active)
//  and hits "Mark Inspected" from the detail sheet. The diamond tool just
//  treats it like any other source — snap, drop, green.
//

import SwiftUI
import MapKit
import Combine

// MARK: - Source Finder Map Controller

@MainActor
final class SourceFinderMapController: ObservableObject {
    
    // MARK: - Published State (drives SwiftUI overlays in FieldMapView)
    
    /// Currently showing the shout-out banner
    @Published var showBanner: Bool = false
    @Published var bannerPin: SourceFinderPin?
    
    /// Post-treatment recommendation modal (triggered from detail sheet only)
    @Published var showInspectionModal: Bool = false
    @Published var inspectionPin: SourceFinderPin?
    
    /// Detail sheet when tech taps a Source Finder pin
    @Published var showDetailSheet: Bool = false
    @Published var detailPin: SourceFinderPin?
    
    // MARK: - Banner Queue
    
    private var bannerQueue: [SourceFinderPin] = []
    
    /// Banner position tracking — "2 of 6"
    @Published var bannerCurrentIndex: Int = 0
    @Published var bannerTotalCount: Int = 0
    
    // MARK: - Observation
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Watch for new pins that need banner display
        SourceFinderService.shared.$newPinsForBanner
            .receive(on: RunLoop.main)
            .sink { [weak self] newPins in
                guard let self, !newPins.isEmpty else { return }
                self.enqueueBanners(newPins)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Pin State Helpers
    
    /// Should this pin pulse? Only if pending (not yet inspected).
    /// Once inspected OR treated, pulse stops.
    static func shouldPulse(_ pin: SourceFinderPin) -> Bool {
        return pin.isPending
    }
    
    /// Get the display color for a Source Finder pin.
    /// Simple status-based logic:
    ///   - Treated (has local override in TreatmentStatusService) = green
    ///   - Urgent = red
    ///   - Everything else (pending, inspected) = orange
    static func pinColor(_ pin: SourceFinderPin) -> UIColor {
            // Treated locally (diamond tool) = green
            if TreatmentStatusService.shared.localOverrides[pin.id] != nil {
                return UIColor(hexString: TreatmentColors.fresh)
            }
            // Untreated — orange or red based on priority
            if pin.isUrgent {
                return .systemRed
            }
            return .systemOrange
        }
    
    // MARK: - Tap Handling
    
    /// Handle tap on a Source Finder pin. Called from Coordinator.
    func handlePinTap(_ pin: SourceFinderPin) {
        detailPin = pin
        showDetailSheet = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - Mark Inspected (from detail sheet only)
    
    /// Tech submits inspection result from the detail sheet's "Mark Inspected" button.
    func submitInspection(findings: String?, recommendPermanent: Bool) {
        guard let pin = inspectionPin else { return }
        
        SourceFinderService.shared.markInspected(
            pinId: pin.id,
            findings: findings,
            recommendPermanent: recommendPermanent
        )
        
        // If recommending permanent, create a pending source via AddSourceService
        if recommendPermanent {
            submitAsPendingSource(pin: pin)
        }
        
        showInspectionModal = false
        inspectionPin = nil
        
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    
    /// Route a permanent recommendation into the existing pending sources approval queue
    private func submitAsPendingSource(pin: SourceFinderPin) {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            print("[SourceFinder] ⚠️ Cannot create pending source — no district_id")
            return
        }
        
        let createdBy = AuthService.shared.currentUser?.email
            ?? TruckService.shared.selectedTruckName
            ?? "tech"
        
        let source = PendingSource(
            districtId: districtId,
            sourceType: .pointsite,
            name: pin.address ?? pin.sourceTypeLabel,
            sourceSubtype: pin.sourceType,
            condition: .unknown,
            description: "Source Finder recommendation: \(pin.mainMessage ?? pin.sourceTypeLabel). \(pin.techFindings ?? "")",
            geometry: .point(pin.coordinate),
            createdBy: createdBy
        )
        
        AddSourceService.shared.createSource(source)
        print("[SourceFinder] Submitted permanent source recommendation for \(pin.id.prefix(8))")
    }
    
    // MARK: - Banner Queue
    
    private func enqueueBanners(_ pins: [SourceFinderPin]) {
        let existingIds = Set(bannerQueue.map { $0.id })
        let currentId = bannerPin?.id
        let newOnly = pins.filter { $0.id != currentId && !existingIds.contains($0.id) }
        guard !newOnly.isEmpty else { return }
        
        bannerQueue.append(contentsOf: newOnly)
        bannerTotalCount = bannerQueue.count + (showBanner ? 1 : 0)
        if !showBanner {
            bannerCurrentIndex = 0
            showNextBanner()
        }
    }
    
    private func showNextBanner() {
        guard let pin = bannerQueue.first else {
            showBanner = false
            bannerPin = nil
            bannerCurrentIndex = 0
            bannerTotalCount = 0
            return
        }
        
        bannerQueue.removeFirst()
        bannerPin = pin
        bannerCurrentIndex += 1
        showBanner = true
        
    
    }
    
    /// Dismiss the current banner (manual or auto)
    func dismissBanner() {
        showBanner = false
        bannerPin = nil
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !bannerQueue.isEmpty {
                showNextBanner()
            }
        }
    }
    
    // MARK: - Navigate to Pin
    
    func navigateToPin(_ pin: SourceFinderPin) async {
        await RouteService.shared.navigateTo(
            coordinate: pin.coordinate,
            name: pin.displayTitle,
            type: "sourcefinder",
            id: pin.id
        )
    }
}

// MARK: - Source Finder Annotation

class SourceFinderAnnotation: NSObject, MKAnnotation {
    let pin: SourceFinderPin
    
    var coordinate: CLLocationCoordinate2D { pin.coordinate }
    var title: String? { pin.displayTitle }
    var subtitle: String? { pin.sourceTypeLabel }
    
    init(pin: SourceFinderPin) {
        self.pin = pin
    }
    
    /// Marker image — color based on pin status. Crosshair icon distinguishes from other sources.
    var markerImage: UIImage {
        let color = SourceFinderMapController.pinColor(pin)
        return SourceFinderAnnotation.renderImage(color: color)
    }
    
    /// Render the marker with a given UIColor.
    static func renderImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            
            // Filled circle with white border
            UIColor.white.setStroke()
            ctx.setLineWidth(2.5)
            color.setFill()
            
            let circleRect = CGRect(x: 3, y: 3, width: 22, height: 22)
            ctx.fillEllipse(in: circleRect)
            ctx.strokeEllipse(in: circleRect)
            
            // Crosshair lines (distinguishes from plain point sites)
            UIColor.white.setStroke()
            ctx.setLineWidth(1.5)
            
            ctx.move(to: CGPoint(x: 8, y: 14))
            ctx.addLine(to: CGPoint(x: 20, y: 14))
            ctx.strokePath()
            
            ctx.move(to: CGPoint(x: 14, y: 8))
            ctx.addLine(to: CGPoint(x: 14, y: 20))
            ctx.strokePath()
        }
    }
}

// MARK: - Source Finder Pulse Overlay (pending pins only)

class SourceFinderPulseOverlay: NSObject, MKOverlay {
    let pins: [SourceFinderPin]
    
    var coordinate: CLLocationCoordinate2D {
        pins.first?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }
    
    var boundingMapRect: MKMapRect {
        guard !pins.isEmpty else { return .null }
        var rect = MKMapRect.null
        for pin in pins {
            let point = MKMapPoint(pin.coordinate)
            let pinRect = MKMapRect(x: point.x - 1000, y: point.y - 1000, width: 2000, height: 2000)
            rect = rect.union(pinRect)
        }
        return rect
    }
    
    init(pins: [SourceFinderPin]) {
        self.pins = pins
    }
}

// MARK: - Source Finder Pulse Renderer

class SourceFinderPulseRenderer: MKOverlayRenderer {
    let pulseOverlay: SourceFinderPulseOverlay
    
    init(overlay: SourceFinderPulseOverlay) {
        self.pulseOverlay = overlay
        super.init(overlay: overlay)
    }
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        for pin in pulseOverlay.pins {
            let mapPoint = MKMapPoint(pin.coordinate)
            let drawPoint = point(for: mapPoint)
            
            let ringRadius: CGFloat = 18.0 / zoomScale
            let color: UIColor = pin.isUrgent ? .systemRed : .systemOrange
            
            context.setStrokeColor(color.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(2.0 / zoomScale)
            context.strokeEllipse(in: CGRect(
                x: drawPoint.x - ringRadius,
                y: drawPoint.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
        }
    }
}

// MARK: - Source Finder Banner View

struct SourceFinderBannerView: View {
    let pin: SourceFinderPin?
    let currentIndex: Int
    let totalCount: Int
    let onDismiss: () -> Void
    let onNavigate: () -> Void
    
    var body: some View {
        if let pin = pin {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(pin.isUrgent ? Color.red : Color.orange)
                        .frame(width: 12, height: 12)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("🔍 SOURCE FINDER")
                                .font(.caption2.bold())
                                .foregroundColor(.orange.opacity(0.8))
                            
                            if totalCount > 1 {
                                Text("\(currentIndex) of \(totalCount)")
                                    .font(.caption2.bold().monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.15))
                                    .foregroundColor(.white.opacity(0.9))
                                    .cornerRadius(4)
                            }
                        }
                        
                        Text(pin.shoutOut ?? pin.displayTitle)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }
                    
                    Spacer()
                    
                    Button(action: onNavigate) {
                        Image(systemName: "location.fill")
                            .font(.body.bold())
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                    
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.1, green: 0.1, blue: 0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(pin.isUrgent ? Color.red.opacity(0.6) : Color.orange.opacity(0.4), lineWidth: 1.5)
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Source Finder Detail Sheet

struct SourceFinderDetailView: View {
    let pin: SourceFinderPin
    let onNavigate: () -> Void
    let onMarkInspected: () -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                // Status & Priority
                Section("Status") {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 14, height: 14)
                        Text(pin.status.capitalized)
                            .font(.headline)
                        Spacer()
                        Text(pin.priorityLabel)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(priorityColor.opacity(0.2))
                            .foregroundColor(priorityColor)
                            .cornerRadius(6)
                    }
                }
                
                // Source Info
                Section("Source Details") {
                    infoRow("Type", pin.sourceTypeLabel)
                    if let address = pin.address, !address.isEmpty {
                        infoRow("Address", address)
                    }
                    infoRow("Coords", String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                    if let message = pin.mainMessage, !message.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Message from OD")
                                .font(.caption).foregroundColor(.secondary)
                            Text(message).font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                    if let shout = pin.shoutOut, !shout.isEmpty {
                        infoRow("Shout-Out", shout)
                    }
                }
                
                // Created info
                Section("Created") {
                    infoRow("By", pin.createdBy ?? "Unknown")
                    infoRow("Date", formatDate(pin.createdAt))
                }
                
                // Inspection results (if inspected)
                if pin.isInspected {
                    Section("Inspection") {
                        infoRow("Inspected By", pin.inspectedBy ?? "Unknown")
                        if let at = pin.inspectedAt { infoRow("Date", formatDate(at)) }
                        if let findings = pin.techFindings, !findings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Findings").font(.caption).foregroundColor(.secondary)
                                Text(findings)
                            }
                        }
                        infoRow("Recommended Permanent", pin.recommendedPermanent ? "Yes" : "No")
                    }
                }
                
                // Actions
                Section {
                    Button(action: onNavigate) {
                        HStack {
                            Image(systemName: "location.fill")
                            Text("Navigate Here")
                        }
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.blue).cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    
                    if pin.isPending {
                        Button(action: onMarkInspected) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Mark Inspected")
                            }
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.orange).cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Source Finder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch pin.status {
        case "pending": return .orange
        case "inspected": return .green
        case "resolved": return .gray
        default: return .orange
        }
    }
    
    private var priorityColor: Color {
        switch pin.priority {
        case "urgent": return .red
        case "normal": return .orange
        case "low": return .yellow
        default: return .orange
        }
    }
    
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Post-Treatment Inspection Modal

struct SourceFinderInspectionModal: View {
    let pin: SourceFinderPin
    let onSubmit: (String?, Bool) -> Void
    let onCancel: () -> Void
    
    @State private var findings: String = ""
    @State private var recommendPermanent: Bool = false
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.5).edgesIgnoringSafeArea(.all)
                .onTapGesture { /* block tap-through */ }
            
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title2).foregroundColor(.orange)
                    Text("Inspection Complete").font(.headline)
                }
                
                if let address = pin.address, !address.isEmpty {
                    Text(address)
                        .font(.caption).foregroundColor(.secondary)
                }
                
                TextEditor(text: $findings)
                    .frame(height: 80)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .overlay(
                        Group {
                            if findings.isEmpty {
                                Text("Findings (optional)...")
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 12)
                                    .padding(.top, 16)
                                    .allowsHitTesting(false)
                            }
                        }, alignment: .topLeading
                    )
                
                Button(action: { recommendPermanent.toggle() }) {
                    HStack {
                        Image(systemName: recommendPermanent ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(recommendPermanent ? .green : .gray)
                        Text("Recommend as permanent source")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(recommendPermanent ? Color.green.opacity(0.15) : Color(.tertiarySystemBackground))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                
                HStack(spacing: 16) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                    
                    Button(action: {
                        let trimmed = findings.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSubmit(trimmed.isEmpty ? nil : trimmed, recommendPermanent)
                    }) {
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Submit")
                        }
                        .font(.headline).foregroundColor(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Color.green).cornerRadius(10)
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
}

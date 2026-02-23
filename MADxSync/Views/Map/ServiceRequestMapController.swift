//
//  ServiceRequestMapController.swift
//  MADxSync
//
//  Manages Service Request pin rendering on the MapKit map, tap interaction,
//  shout-out banner display, and the post-treatment recommendation modal.
//
//  Sibling of SourceFinderMapController — same lifecycle, different visual identity.
//
//  COLOR RULES:
//  - pending + not inspected  = blue (urgent = red), pulsing
//  - inspected (not treated)  = blue (urgent = red), NO pulse
//  - treated (diamond dropped) = green, no pulse
//
//  ICON: Phone icon (📞) — distinguishes from SF crosshair (🔍)
//

import SwiftUI
import MapKit
import Combine

// MARK: - Service Request Map Controller

@MainActor
final class ServiceRequestMapController: ObservableObject {
    
    // MARK: - Published State (drives SwiftUI overlays in FieldMapView)
    
    /// Currently showing the shout-out banner
    @Published var showBanner: Bool = false
    @Published var bannerRequest: ServiceRequestPin?
    
    /// Post-treatment recommendation modal (triggered from detail sheet only)
    @Published var showInspectionModal: Bool = false
    @Published var inspectionRequest: ServiceRequestPin?
    
    /// Detail sheet when tech taps a Service Request pin
    @Published var showDetailSheet: Bool = false
    @Published var detailRequest: ServiceRequestPin?
    
    // MARK: - Banner Queue
    
    private var bannerQueue: [ServiceRequestPin] = []
    
    /// Banner position tracking — "2 of 6"
    @Published var bannerCurrentIndex: Int = 0
    @Published var bannerTotalCount: Int = 0
    
    // MARK: - Observation
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Watch for new requests that need banner display
        ServiceRequestService.shared.$newRequestsForBanner
            .receive(on: RunLoop.main)
            .sink { [weak self] newRequests in
                guard let self, !newRequests.isEmpty else { return }
                self.enqueueBanners(newRequests)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Pin State Helpers
    
    /// Should this pin pulse? Only if pending (not yet inspected).
    static func shouldPulse(_ request: ServiceRequestPin) -> Bool {
        return request.isPending
    }
    
    /// Get the display color for a Service Request pin.
    /// Blue theme (distinguishes from SF's orange).
    static func pinColor(_ request: ServiceRequestPin) -> UIColor {
        // Treated locally (diamond tool) = green
        if TreatmentStatusService.shared.localOverrides[request.id] != nil {
            return UIColor(hexString: TreatmentColors.fresh)
        }
        // Untreated — blue or red based on priority
        if request.isUrgent {
            return .systemRed
        }
        return .systemBlue
    }
    
    // MARK: - Tap Handling
    
    /// Handle tap on a Service Request pin. Called from Coordinator.
    func handlePinTap(_ request: ServiceRequestPin) {
        detailRequest = request
        showDetailSheet = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    // MARK: - Mark Inspected (from detail sheet only)
    
    /// Tech submits inspection result from the detail sheet's "Mark Inspected" button.
    func submitInspection(findings: String?, recommendPermanent: Bool) {
        guard let request = inspectionRequest else { return }
        
        ServiceRequestService.shared.markInspected(
            requestId: request.id,
            findings: findings,
            recommendPermanent: recommendPermanent
        )
        
        // If recommending permanent, create a pending source via AddSourceService
        if recommendPermanent {
            submitAsPendingSource(request: request)
        }
        
        showInspectionModal = false
        inspectionRequest = nil
        
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
    
    /// Route a permanent recommendation into the existing pending sources approval queue
    private func submitAsPendingSource(request: ServiceRequestPin) {
        guard let districtId = AuthService.shared.districtId, !districtId.isEmpty else {
            print("[ServiceRequests] ⚠️ Cannot create pending source — no district_id")
            return
        }
        
        let createdBy = AuthService.shared.currentUser?.email
            ?? TruckService.shared.selectedTruckName
            ?? "tech"
        
        let description = [
            "Service Request recommendation",
            request.callerName.map { "Caller: \($0)" },
            request.mainMessage,
            request.techFindings
        ].compactMap { $0 }.joined(separator: ". ")
        
        let source = PendingSource(
            districtId: districtId,
            sourceType: .pointsite,
            name: request.address ?? request.sourceTypeLabel,
            sourceSubtype: request.sourceType,
            condition: .unknown,
            description: description,
            geometry: .point(request.coordinate),
            createdBy: createdBy
        )
        
        AddSourceService.shared.createSource(source)
        print("[ServiceRequests] Submitted permanent source recommendation for \(request.id.prefix(8))")
    }
    
    // MARK: - Banner Queue
    
    private func enqueueBanners(_ requests: [ServiceRequestPin]) {
        let existingIds = Set(bannerQueue.map { $0.id })
        let currentId = bannerRequest?.id
        let newOnly = requests.filter { $0.id != currentId && !existingIds.contains($0.id) }
        guard !newOnly.isEmpty else { return }
        
        bannerQueue.append(contentsOf: newOnly)
        bannerTotalCount = bannerQueue.count + (showBanner ? 1 : 0)
        if !showBanner {
            bannerCurrentIndex = 0
            showNextBanner()
        }
    }
    
    private func showNextBanner() {
        guard let request = bannerQueue.first else {
            showBanner = false
            bannerRequest = nil
            bannerCurrentIndex = 0
            bannerTotalCount = 0
            return
        }
        
        bannerQueue.removeFirst()
        bannerRequest = request
        bannerCurrentIndex += 1
        showBanner = true
    }
    
    /// Dismiss the current banner (manual or auto)
    func dismissBanner() {
        showBanner = false
        bannerRequest = nil
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !bannerQueue.isEmpty {
                showNextBanner()
            }
        }
    }
    
    // MARK: - Navigate to Request
    
    func navigateToRequest(_ request: ServiceRequestPin) async {
        await RouteService.shared.navigateTo(
            coordinate: request.coordinate,
            name: request.displayTitle,
            type: "servicerequest",
            id: request.id
        )
    }
}

// MARK: - Service Request Annotation

class ServiceRequestAnnotation: NSObject, MKAnnotation {
    let request: ServiceRequestPin
    
    var coordinate: CLLocationCoordinate2D { request.coordinate }
    var title: String? { request.displayTitle }
    var subtitle: String? { request.sourceTypeLabel }
    
    init(request: ServiceRequestPin) {
        self.request = request
    }
    
    /// Marker image — phone icon distinguishes from SF's crosshair
    var markerImage: UIImage {
        let color = ServiceRequestMapController.pinColor(request)
        return ServiceRequestAnnotation.renderImage(color: color)
    }
    
    /// Render the marker with a phone receiver icon
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
            
            // Phone receiver icon (simple handset shape)
            UIColor.white.setFill()
            UIColor.white.setStroke()
            ctx.setLineWidth(1.8)
            
            // Simplified phone receiver — arc shape
            let phonePath = UIBezierPath()
            // Left earpiece
            phonePath.move(to: CGPoint(x: 9, y: 10))
            phonePath.addLine(to: CGPoint(x: 9, y: 13))
            // Bottom curve
            phonePath.addQuadCurve(to: CGPoint(x: 19, y: 13), controlPoint: CGPoint(x: 14, y: 19))
            // Right earpiece
            phonePath.addLine(to: CGPoint(x: 19, y: 10))
            phonePath.stroke()
        }
    }
}

// MARK: - Service Request Pulse Overlay (pending requests only)

class ServiceRequestPulseOverlay: NSObject, MKOverlay {
    let requests: [ServiceRequestPin]
    
    var coordinate: CLLocationCoordinate2D {
        requests.first?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }
    
    var boundingMapRect: MKMapRect {
        guard !requests.isEmpty else { return .null }
        var rect = MKMapRect.null
        for req in requests {
            let point = MKMapPoint(req.coordinate)
            let pinRect = MKMapRect(x: point.x - 1000, y: point.y - 1000, width: 2000, height: 2000)
            rect = rect.union(pinRect)
        }
        return rect
    }
    
    init(requests: [ServiceRequestPin]) {
        self.requests = requests
    }
}

// MARK: - Service Request Pulse Renderer

class ServiceRequestPulseRenderer: MKOverlayRenderer {
    let pulseOverlay: ServiceRequestPulseOverlay
    
    init(overlay: ServiceRequestPulseOverlay) {
        self.pulseOverlay = overlay
        super.init(overlay: overlay)
    }
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        for req in pulseOverlay.requests {
            let mapPoint = MKMapPoint(req.coordinate)
            let drawPoint = point(for: mapPoint)
            
            let ringRadius: CGFloat = 18.0 / zoomScale
            let color: UIColor = req.isUrgent ? .systemRed : .systemBlue
            
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

// MARK: - Service Request Banner View

struct ServiceRequestBannerView: View {
    let request: ServiceRequestPin?
    let currentIndex: Int
    let totalCount: Int
    let onDismiss: () -> Void
    let onNavigate: () -> Void
    
    var body: some View {
        if let request = request {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(request.isUrgent ? Color.red : Color.blue)
                        .frame(width: 12, height: 12)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("📞 SERVICE REQUEST")
                                .font(.caption2.bold())
                                .foregroundColor(.blue.opacity(0.8))
                            
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
                        
                        Text(request.shoutOut ?? request.displayTitle)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .lineLimit(2)
                        
                        if let caller = request.callerDisplay {
                            Text(caller)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        }
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
                                .stroke(request.isUrgent ? Color.red.opacity(0.6) : Color.blue.opacity(0.4), lineWidth: 1.5)
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            }
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Service Request Detail Sheet

struct ServiceRequestDetailView: View {
    let request: ServiceRequestPin
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
                        Text(request.status.capitalized)
                            .font(.headline)
                        Spacer()
                        Text(request.priorityLabel)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(priorityColor.opacity(0.2))
                            .foregroundColor(priorityColor)
                            .cornerRadius(6)
                    }
                }
                
                // Caller Info (SR-specific)
                if request.callerName != nil || request.callerPhone != nil {
                    Section("Caller") {
                        if let name = request.callerName, !name.isEmpty {
                            infoRow("Name", name)
                        }
                        if let phone = request.callerPhone, !phone.isEmpty {
                            infoRow("Phone", phone)
                        }
                    }
                }
                
                // Source Info
                Section("Request Details") {
                    infoRow("Type", request.sourceTypeLabel)
                    if let full = request.fullAddress {
                        infoRow("Address", full)
                    }
                    infoRow("Coords", String(format: "%.5f, %.5f", request.latitude, request.longitude))
                    if let message = request.mainMessage, !message.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Complaint")
                                .font(.caption).foregroundColor(.secondary)
                            Text(message).font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                    if let shout = request.shoutOut, !shout.isEmpty {
                        infoRow("Shout-Out", shout)
                    }
                }
                
                // Created info
                Section("Created") {
                    infoRow("By", request.createdBy ?? "Unknown")
                    infoRow("Date", formatDate(request.createdAt))
                }
                
                // Inspection results (if inspected)
                if request.isInspected {
                    Section("Inspection") {
                        infoRow("Inspected By", request.inspectedBy ?? "Unknown")
                        if let at = request.inspectedAt { infoRow("Date", formatDate(at)) }
                        if let findings = request.techFindings, !findings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Findings").font(.caption).foregroundColor(.secondary)
                                Text(findings)
                            }
                        }
                        infoRow("Recommended Permanent", request.recommendedPermanent ? "Yes" : "No")
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
                    
                    if request.isPending {
                        Button(action: onMarkInspected) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Mark Inspected")
                            }
                            .font(.headline).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.blue).cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Service Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch request.status {
        case "pending": return .blue
        case "inspected": return .green
        case "resolved": return .gray
        default: return .blue
        }
    }
    
    private var priorityColor: Color {
        switch request.priority {
        case "urgent": return .red
        case "normal": return .blue
        case "low": return .cyan
        default: return .blue
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

struct ServiceRequestInspectionModal: View {
    let request: ServiceRequestPin
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
                    Image(systemName: "phone.circle.fill")
                        .font(.title2).foregroundColor(.blue)
                    Text("Inspection Complete").font(.headline)
                }
                
                if let full = request.fullAddress {
                    Text(full)
                        .font(.caption).foregroundColor(.secondary)
                }
                
                if let caller = request.callerDisplay {
                    Text("Caller: \(caller)")
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

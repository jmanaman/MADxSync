//
//  HeadingArrowView.swift
//  MADxSync
//
//  GPU-composited heading arrow rendered as a UIView on top of MKMapView.
//  Replaces HeadingArrowOverlay + HeadingArrowRenderer to eliminate
//  the overlay add/remove churn that was choking the main thread.
//
//  How it works:
//  - Sits as a subview of MKMapView
//  - Repositioned via mapView.convert(coordinate, toPointTo:)
//  - Rotated via CGAffineTransform
//  - Animated with CoreAnimation for smooth interpolation
//  - Zero MapKit overlay involvement
//

import UIKit
import MapKit
import CoreLocation

class HeadingArrowView: UIView {
    
    // MARK: - State
    
    /// Current GPS coordinate of the truck
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    
    /// Current heading in degrees (0 = north)
    private(set) var currentHeading: CLLocationDirection = 0
    
    /// Current GPS accuracy in meters
    private(set) var currentAccuracy: CLLocationAccuracy = 10
    
    /// Reference to the map view for coordinate conversion
    weak var mapView: MKMapView?
    
    // MARK: - Sublayers
    
    /// The accuracy circle (subtle blue halo)
    private let accuracyCircle = UIView()
    
    /// The chevron arrow shape layer
    private let arrowLayer = CAShapeLayer()
    
    /// White outline for the arrow
    private let outlineLayer = CAShapeLayer()
    
    /// Center dot
    private let centerDot = UIView()
    
    // MARK: - Configuration
    
    /// Arrow dimensions
    private let arrowLength: CGFloat = 28
    private let arrowWidth: CGFloat = 18
    
    /// Arrow colors
    private let arrowColor = UIColor.systemBlue
    private let outlineColor = UIColor.white
    private let accuracyColor = UIColor.systemBlue.withAlphaComponent(0.1)
    
    // MARK: - Init
    
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    
    private func setupLayers() {
        // This view is a container — transparent, centered on the GPS position
        backgroundColor = .clear
        isUserInteractionEnabled = false
        
        // Accuracy circle
        accuracyCircle.backgroundColor = accuracyColor
        accuracyCircle.isUserInteractionEnabled = false
        addSubview(accuracyCircle)
        
        // Build chevron arrow path (pointing UP = north at 0 rotation)
        let arrowPath = buildArrowPath()
        
        // White outline (drawn first, slightly thicker)
        outlineLayer.path = arrowPath.cgPath
        outlineLayer.strokeColor = outlineColor.cgColor
        outlineLayer.fillColor = UIColor.clear.cgColor
        outlineLayer.lineWidth = 3
        outlineLayer.lineJoin = .round
        layer.addSublayer(outlineLayer)
        
        // Blue fill
        arrowLayer.path = arrowPath.cgPath
        arrowLayer.fillColor = arrowColor.cgColor
        arrowLayer.strokeColor = UIColor.clear.cgColor
        layer.addSublayer(arrowLayer)
        
        // Center dot
        centerDot.backgroundColor = outlineColor
        centerDot.isUserInteractionEnabled = false
        let dotSize: CGFloat = 4
        centerDot.frame = CGRect(
            x: bounds.midX - dotSize / 2,
            y: bounds.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        centerDot.layer.cornerRadius = dotSize / 2
        addSubview(centerDot)
        
        // Start hidden until we have a position
        isHidden = true
    }
    
    /// Build the chevron arrow path centered in our bounds
    private func buildArrowPath() -> UIBezierPath {
        let cx = bounds.midX
        let cy = bounds.midY
        
        let path = UIBezierPath()
        
        // Tip (forward/up)
        path.move(to: CGPoint(x: cx, y: cy - arrowLength))
        
        // Right wing
        path.addLine(to: CGPoint(x: cx + arrowWidth / 2, y: cy + arrowLength * 0.3))
        
        // Inner notch (chevron shape)
        path.addLine(to: CGPoint(x: cx, y: cy + arrowLength * 0.05))
        
        // Left wing
        path.addLine(to: CGPoint(x: cx - arrowWidth / 2, y: cy + arrowLength * 0.3))
        
        // Close
        path.close()
        
        return path
    }
    
    // MARK: - Public Update Methods
    
    /// Update position and heading with smooth animation.
    /// Called from Coordinator whenever GPS fires.
    func updatePosition(
        coordinate: CLLocationCoordinate2D,
        heading: CLLocationDirection,
        accuracy: CLLocationAccuracy,
        animated: Bool = true
    ) {
        currentCoordinate = coordinate
        currentHeading = heading
        currentAccuracy = accuracy
        
        guard let mapView = mapView, mapView.window != nil else { return }
        
        // Convert GPS coordinate to screen point
        let screenPoint = mapView.convert(coordinate, toPointTo: mapView)
        
        // Check if point is on screen (with generous padding)
        let mapBounds = mapView.bounds.insetBy(dx: -100, dy: -100)
        guard mapBounds.contains(screenPoint) else {
            isHidden = true
            return
        }
        
        isHidden = false
        
        // Convert heading to radians for rotation
        let headingRadians = heading * .pi / 180
        
        if animated && UIApplication.shared.applicationState == .active {
            // Smooth animation — 0.15s matches ~7 updates/second feel
            // Use weak self to prevent retain cycle during app suspension
            UIView.animate(
                withDuration: 0.15,
                delay: 0,
                options: [.curveLinear, .allowUserInteraction],
                animations: { [weak self] in
                    guard let self, self.mapView?.window != nil else { return }
                    self.center = screenPoint
                    self.transform = CGAffineTransform(rotationAngle: headingRadians)
                }
            )
        } else {
            // Immediate — no animation when backgrounded or on first position
            center = screenPoint
            transform = CGAffineTransform(rotationAngle: headingRadians)
        }
        
        // Update accuracy circle size
        updateAccuracyCircle(accuracy: accuracy, mapView: mapView)
    }
    
    /// Reposition on the map without changing coordinate/heading.
    /// Called when the map pans or zooms (regionDidChange) so the arrow
    /// stays pinned to the correct geographic location.
    func repositionOnMap() {
        guard let mapView = mapView, mapView.window != nil,
              let coordinate = currentCoordinate else { return }
        
        let screenPoint = mapView.convert(coordinate, toPointTo: mapView)
        
        let mapBounds = mapView.bounds.insetBy(dx: -100, dy: -100)
        guard mapBounds.contains(screenPoint) else {
            isHidden = true
            return
        }
        
        isHidden = false
        
        // No animation during pan/zoom — follow instantly
        // Use CATransaction to suppress implicit animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        center = screenPoint
        CATransaction.commit()
        
        // Update accuracy circle for new zoom level
        updateAccuracyCircle(accuracy: currentAccuracy, mapView: mapView)
    }
    
    // MARK: - Accuracy Circle
    
    private func updateAccuracyCircle(accuracy: CLLocationAccuracy, mapView: MKMapView) {
        // Convert accuracy meters to screen points
        let centerCoord = currentCoordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let centerPoint = mapView.convert(centerCoord, toPointTo: mapView)
        
        // Create a point 'accuracy' meters to the right
        let region = mapView.region
        let metersPerDegree = 111_320.0 * cos(centerCoord.latitude * .pi / 180)
        let degreesForAccuracy = accuracy / metersPerDegree
        let edgeCoord = CLLocationCoordinate2D(
            latitude: centerCoord.latitude,
            longitude: centerCoord.longitude + degreesForAccuracy
        )
        let edgePoint = mapView.convert(edgeCoord, toPointTo: mapView)
        let radiusInPoints = abs(edgePoint.x - centerPoint.x)
        
        // Only show accuracy circle if it's bigger than the arrow
        if radiusInPoints > arrowLength {
            let diameter = radiusInPoints * 2
            accuracyCircle.isHidden = false
            accuracyCircle.frame = CGRect(
                x: bounds.midX - radiusInPoints,
                y: bounds.midY - radiusInPoints,
                width: diameter,
                height: diameter
            )
            accuracyCircle.layer.cornerRadius = radiusInPoints
        } else {
            accuracyCircle.isHidden = true
        }
    }
}

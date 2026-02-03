//
//  NavigationService.swift
//  MADxSync
//
//  GPS navigation service with heading arrow and truck-follow mode.
//  Uses tablet CoreLocation — works independently of FLO WiFi.
//
//  North-up map, rotating arrow shows heading direction.
//

import Foundation
import MapKit
import CoreLocation
import UIKit
import Combine

// MARK: - Navigation Service

class NavigationService: NSObject, ObservableObject {
    
    // MARK: - Published State
    
    /// Current device location
    @Published var location: CLLocation?
    
    /// Current heading in degrees (0 = north, 90 = east, etc.)
    @Published var heading: CLLocationDirection = 0
    
    /// Whether we have a valid GPS fix
    @Published var hasLocation: Bool = false
    
    /// Whether we have a valid heading
    @Published var hasHeading: Bool = false
    
    /// Follow mode: map pans to keep truck centered
    @Published var isFollowing: Bool = false
    
    /// Current speed in mph (nil if no fix or stationary)
    @Published var speedMPH: Double? = nil
    
    /// Authorization status
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // MARK: - Location Manager
    
    private let locationManager = CLLocationManager()
    
    // MARK: - Configuration
    
    /// Minimum speed (mph) to trust heading from GPS course
    /// Below this, heading comes from compass (magnetometer)
    private let minimumSpeedForCourseHeading: Double = 3.0
    
    /// Follow mode zoom span (latitude degrees)
    /// ~0.01 = roughly street level, good for field work
    let followZoomSpan: CLLocationDegrees = 0.015
    
    // MARK: - Init
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2  // Update every 2 meters of movement
        locationManager.headingFilter = 2   // Update every 2 degrees of heading change
    }
    
    // MARK: - Public Methods
    
    /// Request location permission and start updates
    func requestPermission() {
        let status = locationManager.authorizationStatus
        print("[NAV] requestPermission - current status: \(status.rawValue)")
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            print("[NAV] Already authorized, calling startUpdating")
            startUpdating()
        } else {
            print("[NAV] Requesting authorization")
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    /// Start receiving location and heading updates
    func startUpdating() {
        print("[NAV] startUpdating called - authStatus: \(locationManager.authorizationStatus.rawValue)")
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }
    
    /// Stop all updates (battery saving)
    func stopUpdating() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }
    
    /// Toggle follow mode
    func toggleFollow() {
        print("[NAV] toggleFollow - isFollowing will be: \(!isFollowing), hasLocation: \(hasLocation), location: \(String(describing: location))")
        isFollowing.toggle()
    }
    
    /// Current coordinate (convenience)
    var coordinate: CLLocationCoordinate2D? {
        location?.coordinate
    }
    
}

// MARK: - CLLocationManagerDelegate

extension NavigationService: CLLocationManagerDelegate {
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("[NAV] didUpdateLocations - got \(locations.count) locations")
        guard let newLocation = locations.last else { return }
        
        // Filter out invalid or very old locations
        let age = -newLocation.timestamp.timeIntervalSinceNow
        guard age < 10, newLocation.horizontalAccuracy >= 0 else {
            print("[NAV] Location filtered out - age: \(age), accuracy: \(newLocation.horizontalAccuracy)")
            return
        }
        
        print("[NAV] Valid location: \(newLocation.coordinate.latitude), \(newLocation.coordinate.longitude)")
        location = newLocation
        hasLocation = true
        
        // Speed in mph
        if newLocation.speed >= 0 {
            speedMPH = newLocation.speed * 2.23694  // m/s to mph
        } else {
            speedMPH = nil
        }
        
        // Use GPS course for heading when moving fast enough
        // GPS course is more accurate than compass when in motion
        if let speed = speedMPH, speed >= minimumSpeedForCourseHeading,
           newLocation.course >= 0 {
            heading = newLocation.course
            hasHeading = true
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Only use compass heading when stationary or moving slowly
        // When driving, GPS course (from didUpdateLocations) is more reliable
        if let speed = speedMPH, speed >= minimumSpeedForCourseHeading {
            return  // Ignore compass, using GPS course instead
        }
        
        // Use true heading if available, magnetic as fallback
        let compassHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        
        if compassHeading >= 0 {
            heading = compassHeading
            hasHeading = true
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        print("[NAV] authorizationDidChange: \(manager.authorizationStatus.rawValue)")
        authorizationStatus = manager.authorizationStatus
        
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[NAV] Location error: \(error.localizedDescription)")
    }
}

// MARK: - Heading Arrow Overlay

/// Custom MKOverlay that represents the truck's position and heading.
/// Drawn as a blue chevron/arrow pointing in the direction of travel.
class HeadingArrowOverlay: NSObject, MKOverlay {
    
    var coordinateValue: CLLocationCoordinate2D
    var headingDegrees: CLLocationDirection
    var accuracy: CLLocationAccuracy
    
    var coordinate: CLLocationCoordinate2D { coordinateValue }
    
    /// Bounding rect needs to be large enough that the arrow doesn't get culled
    var boundingMapRect: MKMapRect {
        let point = MKMapPoint(coordinateValue)
        // 500m radius should be plenty for the arrow size at any zoom
        let size: Double = 1000
        return MKMapRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }
    
    init(coordinate: CLLocationCoordinate2D, heading: CLLocationDirection, accuracy: CLLocationAccuracy = 10) {
        self.coordinateValue = coordinate
        self.headingDegrees = heading
        self.accuracy = accuracy
        super.init()
    }
}

// MARK: - Heading Arrow Renderer

/// Renders a blue chevron arrow on the map that rotates with heading.
/// North-up map — only the arrow rotates, not the map.
class HeadingArrowRenderer: MKOverlayRenderer {
    
    /// Arrow fill color
    private let arrowColor = UIColor.systemBlue
    
    /// Arrow outline
    private let outlineColor = UIColor.white
    
    /// Accuracy circle color
    private let accuracyColor = UIColor.systemBlue.withAlphaComponent(0.1)
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let arrow = overlay as? HeadingArrowOverlay else { return }
        
        let center = point(for: MKMapPoint(arrow.coordinateValue))
        
        // Arrow size in screen points (constant regardless of zoom)
        let arrowLength: CGFloat = 28 / zoomScale
        let arrowWidth: CGFloat = 18 / zoomScale
        
        // Convert heading to radians (clockwise from north)
        // Core Graphics rotates counterclockwise, and 0° = east in CG vs north in compass
        let headingRadians = CGFloat(arrow.headingDegrees) * .pi / 180
        
        context.saveGState()
        
        // Draw accuracy circle (subtle blue halo)
        let accuracyRadius = CGFloat(arrow.accuracy) / CGFloat(zoomScale) * 0.5
        if accuracyRadius > arrowLength {
            context.setFillColor(accuracyColor.cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - accuracyRadius,
                y: center.y - accuracyRadius,
                width: accuracyRadius * 2,
                height: accuracyRadius * 2
            ))
        }
        
        // Move to center point and rotate
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: headingRadians)
        
        // Draw chevron arrow pointing UP (north = 0 rotation)
        // The arrow points in the -Y direction (up on screen before rotation)
        let path = CGMutablePath()
        
        // Tip of arrow (forward)
        path.move(to: CGPoint(x: 0, y: -arrowLength))
        
        // Right wing
        path.addLine(to: CGPoint(x: arrowWidth / 2, y: arrowLength * 0.3))
        
        // Inner notch (makes it a chevron, not a triangle)
        path.addLine(to: CGPoint(x: 0, y: arrowLength * 0.05))
        
        // Left wing
        path.addLine(to: CGPoint(x: -arrowWidth / 2, y: arrowLength * 0.3))
        
        // Close back to tip
        path.closeSubpath()
        
        // White outline first (2px border)
        context.setStrokeColor(outlineColor.cgColor)
        context.setLineWidth(3 / zoomScale)
        context.addPath(path)
        context.strokePath()
        
        // Blue fill
        context.setFillColor(arrowColor.cgColor)
        context.addPath(path)
        context.fillPath()
        
        // Small white dot at center (position indicator)
        let dotSize: CGFloat = 4 / zoomScale
        context.setFillColor(outlineColor.cgColor)
        context.fillEllipse(in: CGRect(x: -dotSize / 2, y: -dotSize / 2, width: dotSize, height: dotSize))
        
        context.restoreGState()
    }
}

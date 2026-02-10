//
//  NavigationService.swift
//  MADxSync
//
//  GPS navigation service with heading arrow and truck-follow mode.
//  Uses tablet CoreLocation — works independently of FLO WiFi.
//
//  North-up map, rotating arrow shows heading direction.
//
//  PERFORMANCE FIX: distanceFilter = kCLDistanceFilterNone for continuous updates.
//  Arrow rendering moved to HeadingArrowView (GPU-composited UIView) so frequent
//  GPS updates no longer choke the main thread with overlay add/remove cycles.
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
    
    // MARK: - Direct callbacks (bypass SwiftUI for performance-critical updates)
    
    /// Called on every GPS update — Coordinator subscribes to this directly.
    /// This avoids the SwiftUI @Published → updateUIView → full coordinator pipeline.
    var onLocationUpdate: ((CLLocation, CLLocationDirection) -> Void)?
    
    // MARK: - Location Manager
    
    private let locationManager = CLLocationManager()
    
    // MARK: - Configuration
    
    /// Minimum speed (mph) to trust heading from GPS course
    /// Below this, heading comes from compass (magnetometer)
    private let minimumSpeedForCourseHeading: Double = 3.0
    
    /// Follow mode zoom span (latitude degrees)
    /// ~0.015 = roughly street level, good for field work
    let followZoomSpan: CLLocationDegrees = 0.015
    
    // MARK: - Init
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        // Continuous updates — arrow view handles rendering efficiently
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = 1   // Update every 1 degree of heading change
    }
    
    // MARK: - Public Methods
    
    /// Request location permission and start updates
    func requestPermission() {
        let status = locationManager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            startUpdating()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    /// Start receiving location and heading updates
    func startUpdating() {
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
        guard let newLocation = locations.last else { return }
        
        // Filter out invalid or very old locations
        let age = -newLocation.timestamp.timeIntervalSinceNow
        guard age < 10, newLocation.horizontalAccuracy >= 0 else { return }
        
        // Update published state (drives SwiftUI bottom bar, route service, etc.)
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
        
        // Fire direct callback to Coordinator — this is the fast path
        // that moves the arrow without going through SwiftUI's update cycle
        onLocationUpdate?(newLocation, heading)
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
            
            // Fire direct callback for heading-only updates too
            if let loc = location {
                onLocationUpdate?(loc, heading)
            }
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
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

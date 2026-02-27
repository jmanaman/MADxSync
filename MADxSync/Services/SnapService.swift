//
//  SnapService.swift
//  MADxSync
//
//  Snap tap coordinates to nearby point sites and storm drains for precise marker placement.
//  Returns the snapped coordinate and source name if within threshold, otherwise returns nil.
//
//  UPDATED: Added pendingSources parameter for Add Sources feature.
//  Default value [] means all existing call sites work without changes.
//  UPDATED: Added pending polyline snap and pending polygon hit-test for treatment integration.
//

import Foundation
import CoreLocation

/// Result of a snap check
struct SnapResult {
    let coordinate: CLLocationCoordinate2D
    let sourceName: String
    let sourceType: String  // "pointsite" or "stormdrain"
    let sourceId: String
}

/// Service for snapping tap locations to nearby point features
class SnapService {
    
    // Snap radius in meters (~50 feet)
    static let snapRadiusMeters: Double = 25.0
    
    /// Check if a tap coordinate is close enough to a point site or storm drain to snap
    /// Returns SnapResult if within threshold, nil otherwise
    static func checkSnap(
        coordinate: CLLocationCoordinate2D,
        pointSites: [PointSite],
        stormDrains: [StormDrain],
        pendingSources: [PendingSource] = [],
        sourceFinderPins: [SourceFinderPin] = [],
        serviceRequestPins: [ServiceRequestPin] = []
    ) -> SnapResult? {
        
        var closestResult: SnapResult? = nil
        var closestDistance: Double = snapRadiusMeters
        
        // Check point sites
        for site in pointSites {
            guard let siteCoord = site.coordinate else { continue }
            let distance = distanceMeters(from: coordinate, to: siteCoord)
            if distance < closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: siteCoord,
                    sourceName: site.displayName,
                    sourceType: "pointsite",
                    sourceId: site.id
                )
            }
        }
        
        // Check storm drains
        for drain in stormDrains {
            guard let drainCoord = drain.coordinate else { continue }
            let distance = distanceMeters(from: coordinate, to: drainCoord)
            if distance < closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: drainCoord,
                    sourceName: drain.name ?? "Storm Drain",
                    sourceType: "stormdrain",
                    sourceId: drain.id
                )
            }
        }
        
        // Check pending point sources
        for source in pendingSources {
            guard !source.sourceType.isMultiPoint else { continue }
            guard let sourceCoord = source.coordinate else { continue }
            let distance = distanceMeters(from: coordinate, to: sourceCoord)
            if distance < closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: sourceCoord,
                    sourceName: source.displayName,
                    sourceType: "pending_\(source.sourceType.rawValue)",
                    sourceId: source.id
                )
            }
        }
        
        // Check pending polylines (nearest point on line segments)
        for source in pendingSources {
            guard source.sourceType == .polyline else { continue }
            let coords = source.allCoordinates
            guard coords.count >= 2 else { continue }
            
            for i in 0..<(coords.count - 1) {
                let (projected, dist) = closestPointOnSegment(
                    point: coordinate, lineStart: coords[i], lineEnd: coords[i + 1]
                )
                if dist < closestDistance {
                    closestDistance = dist
                    closestResult = SnapResult(
                        coordinate: projected,
                        sourceName: source.displayName,
                        sourceType: "pending_polyline",
                        sourceId: source.id
                    )
                }
            }
        }
        
        // Check pending polygons (point-in-polygon)
        for source in pendingSources {
            guard source.sourceType == .polygon else { continue }
            let coords = source.allCoordinates
            guard coords.count >= 3 else { continue }
            
            if pointInPolygon(point: coordinate, polygon: coords) {
                closestResult = SnapResult(
                    coordinate: coordinate,
                    sourceName: source.displayName,
                    sourceType: "pending_polygon",
                    sourceId: source.id
                )
                closestDistance = 0  // Inside = exact match
            }
        }
        
        // Source Finder pins LAST — uses <= so SF pins win ties
        for pin in sourceFinderPins {
            let pinCoord = pin.coordinate
            let distance = distanceMeters(from: coordinate, to: pinCoord)
            if distance <= closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: pinCoord,
                    sourceName: pin.displayTitle,
                    sourceType: "sourcefinder",
                    sourceId: pin.id
                )
            }
        }
        
        // Service Request pins
        for req in serviceRequestPins {
            let reqCoord = req.coordinate
            let distance = distanceMeters(from: coordinate, to: reqCoord)
            if distance <= closestDistance {
                closestDistance = distance
                closestResult = SnapResult(
                    coordinate: reqCoord,
                    sourceName: req.displayTitle,
                    sourceType: "servicerequest",
                    sourceId: req.id
                )
            }
        }
        
        return closestResult
    }
    
    // MARK: - Geometry Helpers
    
    private static func closestPointOnSegment(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> (CLLocationCoordinate2D, Double) {
        let ap = (point.latitude - lineStart.latitude, point.longitude - lineStart.longitude)
        let ab = (lineEnd.latitude - lineStart.latitude, lineEnd.longitude - lineStart.longitude)
        let ab2 = ab.0 * ab.0 + ab.1 * ab.1
        
        guard ab2 > 0 else {
            return (lineStart, distanceMeters(from: point, to: lineStart))
        }
        
        let t = max(0, min(1, (ap.0 * ab.0 + ap.1 * ab.1) / ab2))
        let projected = CLLocationCoordinate2D(
            latitude: lineStart.latitude + t * ab.0,
            longitude: lineStart.longitude + t * ab.1
        )
        return (projected, distanceMeters(from: point, to: projected))
    }
    
    private static func pointInPolygon(
        point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        var inside = false
        let count = polygon.count
        var j = count - 1
        for i in 0..<count {
            let pi = polygon[i]
            let pj = polygon[j]
            if ((pi.latitude > point.latitude) != (pj.latitude > point.latitude)) &&
                (point.longitude < (pj.longitude - pi.longitude) *
                 (point.latitude - pi.latitude) / (pj.latitude - pi.latitude) + pi.longitude) {
                inside = !inside
            }
            j = i
        }
        return inside
    }
    
    private static func distanceMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }
}

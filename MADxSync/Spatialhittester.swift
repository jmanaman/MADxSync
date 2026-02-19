//
//  SpatialHitTester.swift
//  MADxSync
//
//  Tap-to-identify: given a coordinate, finds which spatial feature was tapped.
//  Uses bounding-rect pre-filter then ray-casting point-in-polygon for fields.
//  Uses distance-to-polyline for ditches/canals.
//  Uses proximity for point sites and storm drains.
//
//  UPDATED: 2026-02-14 — Added snapToPolyline() for treatment marker snapping.
//  When a tech drops a treatment diamond near a polyline, the marker snaps to
//  the nearest point on the line. Returns snapped coordinate + feature info.
//

import MapKit
import CoreLocation

struct HitTestResult {
    let feature: SelectedFeature
    let distance: CLLocationDistance  // meters from tap to feature
}

/// Result of snapping a coordinate to the nearest polyline
struct SnapToLineResult {
    let snappedCoordinate: CLLocationCoordinate2D  // Projected point on the line
    let polyline: SpatialPolyline                   // Which polyline was matched
    let distance: CLLocationDistance                 // Meters from original tap to snapped point
}

class SpatialHitTester {
    
    /// Maximum tap distance in meters for each feature type
    private static let polygonTapTolerance: CLLocationDistance = 0      // Must be inside
    private static let polylineTapTolerance: CLLocationDistance = 50    // Within 50m of line
    private static let pointTapTolerance: CLLocationDistance = 100     // Within 100m of point
    
    /// Hit test all visible layers, return closest match
    static func hitTest(
        coordinate: CLLocationCoordinate2D,
        fields: [FieldPolygon],
        polylines: [SpatialPolyline],
        pointSites: [PointSite],
        stormDrains: [StormDrain],
        mapView: MKMapView?
    ) -> SelectedFeature? {
        
        // Calculate tap tolerance in degrees based on current zoom
        // At high zoom, be precise. At low zoom, be more forgiving.
        let tapToleranceDegrees: Double
        if let mapView = mapView {
            let visibleSpan = mapView.region.span
            let screenTapFraction = 0.03  // ~3% of visible width = tap target
            tapToleranceDegrees = visibleSpan.latitudeDelta * screenTapFraction
        } else {
            // Default tolerance when no mapView (e.g., treatment drop hit test)
            tapToleranceDegrees = 0.001  // ~100m
        }
        
        var candidates: [HitTestResult] = []
        
        // 1. Test fields (point-in-polygon)
        for field in fields {
            if hitTestField(coordinate: coordinate, field: field, tolerance: tapToleranceDegrees) {
                candidates.append(HitTestResult(feature: .field(field), distance: 0))
            }
        }
        
        // 2. Test polylines (distance to line)
        for polyline in polylines {
            if let dist = hitTestPolyline(coordinate: coordinate, polyline: polyline, tolerance: tapToleranceDegrees) {
                candidates.append(HitTestResult(feature: .polyline(polyline), distance: dist))
            }
        }
        
        // 3. Test point sites (proximity)
        for site in pointSites {
            if let dist = hitTestPoint(coordinate: coordinate, siteCoordinate: site.coordinate, tolerance: tapToleranceDegrees) {
                candidates.append(HitTestResult(feature: .pointSite(site), distance: dist))
            }
        }
        
        // 4. Test storm drains (proximity)
        for drain in stormDrains {
            if let dist = hitTestPoint(coordinate: coordinate, siteCoordinate: drain.coordinate, tolerance: tapToleranceDegrees) {
                candidates.append(HitTestResult(feature: .stormDrain(drain), distance: dist))
            }
        }
        
        // Return closest match
        // Priority: exact polygon hit > nearest polyline > nearest point
        if let polygonHit = candidates.first(where: {
            if case .field = $0.feature { return true }
            return false
        }) {
            return polygonHit.feature
        }
        
        return candidates.min(by: { $0.distance < $1.distance })?.feature
    }
    
    // MARK: - Snap to Polyline (for treatment marker placement)
    
    /// Find the nearest polyline to a coordinate and return the snapped (projected) point on that line.
    /// Used when dropping treatment markers — the marker snaps to the canal/ditch instead of landing
    /// wherever the tech's finger hit. Also returns the polyline's ID for direct feature matching.
    ///
    /// Tolerance: 0.001 degrees (~111 meters) — matches the default hitTest tolerance.
    /// This means if the tech taps within ~364 feet of a canal, the marker snaps to it.
    ///
    /// Returns nil if no polyline is within tolerance.
    static func snapToPolyline(
        coordinate: CLLocationCoordinate2D,
        polylines: [SpatialPolyline],
        tolerance: Double = 0.001
    ) -> SnapToLineResult? {
        
        var bestResult: SnapToLineResult? = nil
        var bestDistance: CLLocationDistance = .greatestFiniteMagnitude
        
        for polyline in polylines {
            let coords: [CLLocationCoordinate2D]
            switch polyline.geometry {
            case .lineString(let line):
                coords = line.coordinates2D
            case .multiLineString(let multi):
                // Check all segments of a MultiLineString
                coords = multi.lines.flatMap { $0 }
            default:
                continue
            }
            
            guard coords.count >= 2 else { continue }
            
            // Quick bounding box check with tolerance buffer
            let lats = coords.map { $0.latitude }
            let lons = coords.map { $0.longitude }
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { continue }
            
            guard coordinate.latitude >= minLat - tolerance &&
                  coordinate.latitude <= maxLat + tolerance &&
                  coordinate.longitude >= minLon - tolerance &&
                  coordinate.longitude <= maxLon + tolerance else { continue }
            
            // Find nearest segment and projected point
            for i in 0..<(coords.count - 1) {
                let (projectedPoint, distMeters) = closestPointOnSegment(
                    point: coordinate,
                    lineStart: coords[i],
                    lineEnd: coords[i + 1]
                )
                
                // Convert tolerance from degrees to approximate meters
                let toleranceMeters = tolerance * 111_000
                
                if distMeters <= toleranceMeters && distMeters < bestDistance {
                    bestDistance = distMeters
                    bestResult = SnapToLineResult(
                        snappedCoordinate: projectedPoint,
                        polyline: polyline,
                        distance: distMeters
                    )
                }
            }
        }
        
        return bestResult
    }
    
    /// Calculate the closest point on a line segment to a given point, plus distance in meters.
    /// Returns (projectedCoordinate, distanceInMeters)
    private static func closestPointOnSegment(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> (CLLocationCoordinate2D, CLLocationDistance) {
        
        let ap = (point.latitude - lineStart.latitude, point.longitude - lineStart.longitude)
        let ab = (lineEnd.latitude - lineStart.latitude, lineEnd.longitude - lineStart.longitude)
        
        let ab2 = ab.0 * ab.0 + ab.1 * ab.1
        
        // Degenerate segment (start == end)
        guard ab2 > 0 else {
            let p = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let a = CLLocation(latitude: lineStart.latitude, longitude: lineStart.longitude)
            return (lineStart, p.distance(from: a))
        }
        
        // Project point onto line, clamped to [0, 1]
        let t = max(0, min(1, (ap.0 * ab.0 + ap.1 * ab.1) / ab2))
        
        let projected = CLLocationCoordinate2D(
            latitude: lineStart.latitude + t * ab.0,
            longitude: lineStart.longitude + t * ab.1
        )
        
        let pLoc = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let projLoc = CLLocation(latitude: projected.latitude, longitude: projected.longitude)
        
        return (projected, pLoc.distance(from: projLoc))
    }
    
    // MARK: - Field Hit Test (Point-in-Polygon)
    
    private static func hitTestField(coordinate: CLLocationCoordinate2D, field: FieldPolygon, tolerance: Double) -> Bool {
        let coords = extractCoordinates(from: field.geometry)
        guard coords.count >= 3 else { return false }
        
        // Quick bounding box check first
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return false }
        
        // Add tolerance to bounding box for edge taps
        let bufferedMinLat = minLat - tolerance
        let bufferedMaxLat = maxLat + tolerance
        let bufferedMinLon = minLon - tolerance
        let bufferedMaxLon = maxLon + tolerance
        
        guard coordinate.latitude >= bufferedMinLat && coordinate.latitude <= bufferedMaxLat &&
              coordinate.longitude >= bufferedMinLon && coordinate.longitude <= bufferedMaxLon else {
            return false
        }
        
        // Ray casting algorithm for point-in-polygon
        return pointInPolygon(point: coordinate, polygon: coords)
    }
    
    /// Ray casting: count crossings of a horizontal ray from point to the right
    private static func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        var inside = false
        let count = polygon.count
        var j = count - 1
        
        for i in 0..<count {
            let pi = polygon[i]
            let pj = polygon[j]
            
            if ((pi.latitude > point.latitude) != (pj.latitude > point.latitude)) &&
                (point.longitude < (pj.longitude - pi.longitude) * (point.latitude - pi.latitude) / (pj.latitude - pi.latitude) + pi.longitude) {
                inside = !inside
            }
            
            j = i
        }
        
        return inside
    }
    
    // MARK: - Polyline Hit Test (Distance to Line Segments)
    
    private static func hitTestPolyline(coordinate: CLLocationCoordinate2D, polyline: SpatialPolyline, tolerance: Double) -> CLLocationDistance? {
        let coords: [CLLocationCoordinate2D]
        switch polyline.geometry {
        case .lineString(let line):
            coords = line.coordinates2D
        case .multiLineString(let multi):
            coords = multi.lines.first ?? []
        default:
            return nil
        }
        
        guard coords.count >= 2 else { return nil }
        
        var minDist = Double.greatestFiniteMagnitude
        
        for i in 0..<(coords.count - 1) {
            let dist = distanceToLineSegment(
                point: coordinate,
                lineStart: coords[i],
                lineEnd: coords[i + 1]
            )
            minDist = min(minDist, dist)
        }
        
        // Convert tolerance from degrees to approximate meters
        // (rough: 1 degree latitude ≈ 111,000 meters)
        let toleranceMeters = tolerance * 111_000
        
        return minDist <= toleranceMeters ? minDist : nil
    }
    
    /// Distance from a point to a line segment (in meters)
    private static func distanceToLineSegment(
        point: CLLocationCoordinate2D,
        lineStart: CLLocationCoordinate2D,
        lineEnd: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let p = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let a = CLLocation(latitude: lineStart.latitude, longitude: lineStart.longitude)
        let b = CLLocation(latitude: lineEnd.latitude, longitude: lineEnd.longitude)
        
        // Project point onto line segment
        let ap = (point.latitude - lineStart.latitude, point.longitude - lineStart.longitude)
        let ab = (lineEnd.latitude - lineStart.latitude, lineEnd.longitude - lineStart.longitude)
        
        let ab2 = ab.0 * ab.0 + ab.1 * ab.1
        guard ab2 > 0 else { return p.distance(from: a) }
        
        let t = max(0, min(1, (ap.0 * ab.0 + ap.1 * ab.1) / ab2))
        
        let closest = CLLocation(
            latitude: lineStart.latitude + t * ab.0,
            longitude: lineStart.longitude + t * ab.1
        )
        
        return p.distance(from: closest)
    }
    
    // MARK: - Point Hit Test (Proximity)
    
    private static func hitTestPoint(coordinate: CLLocationCoordinate2D, siteCoordinate: CLLocationCoordinate2D?, tolerance: Double) -> CLLocationDistance? {
        guard let siteCoord = siteCoordinate else { return nil }
        
        // Quick degree-based check first
        let dLat = abs(coordinate.latitude - siteCoord.latitude)
        let dLon = abs(coordinate.longitude - siteCoord.longitude)
        guard dLat <= tolerance && dLon <= tolerance else { return nil }
        
        // Precise distance
        let tapLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let siteLocation = CLLocation(latitude: siteCoord.latitude, longitude: siteCoord.longitude)
        let dist = tapLocation.distance(from: siteLocation)
        
        let toleranceMeters = tolerance * 111_000
        return dist <= toleranceMeters ? dist : nil
    }
    
    // MARK: - Helpers
    
    private static func extractCoordinates(from geometry: GeoJSONGeometry) -> [CLLocationCoordinate2D] {
        switch geometry {
        case .polygon(let poly):
            return poly.outerRing
        case .multiPolygon(let multi):
            return multi.polygons.first ?? []
        case .multiLineString(let multi):
            return multi.lines.first ?? []
        case .lineString(let line):
            return line.coordinates2D
        default:
            return []
        }
    }
}

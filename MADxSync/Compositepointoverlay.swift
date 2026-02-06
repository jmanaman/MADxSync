//
//  CompositePointOverlay.swift
//  MADxSync
//
//  Memory-efficient rendering of thousands of point annotations
//  Renders all points into a single overlay instead of individual MKAnnotations
//

import MapKit
import SwiftUI

// MARK: - Point Type
enum CompositePointType {
    case pointSite
    case stormDrain
}

// MARK: - Composite Point Overlay

class CompositePointOverlay: NSObject, MKOverlay {
    
    struct PointData {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let colorHex: String
        let mapPoint: MKMapPoint
        
        init(id: String, coordinate: CLLocationCoordinate2D, color: String) {
            self.id = id
            self.coordinate = coordinate
            self.colorHex = color
            self.mapPoint = MKMapPoint(coordinate)
        }
    }
    
    let points: [PointData]
    let pointType: CompositePointType
    let boundingMapRect: MKMapRect
    
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }
    
    init(pointSites: [PointSite], colorForFeature: (String) -> String) {
        var allPoints: [PointData] = []
        var rect = MKMapRect.null
        
        for site in pointSites {
            guard let coord = site.coordinate else { continue }
            let color = colorForFeature(site.id)
            let data = PointData(id: site.id, coordinate: coord, color: color)
            allPoints.append(data)
            
            let pointRect = MKMapRect(x: data.mapPoint.x, y: data.mapPoint.y, width: 0, height: 0)
            rect = rect.union(pointRect)
        }
        
        self.points = allPoints
        self.pointType = .pointSite
        self.boundingMapRect = rect
        
        super.init()
    }
    
    init(stormDrains: [StormDrain], colorForFeature: (String) -> String) {
        var allPoints: [PointData] = []
        var rect = MKMapRect.null
        
        for drain in stormDrains {
            guard let coord = drain.coordinate else { continue }
            let color = colorForFeature(drain.id)
            let data = PointData(id: drain.id, coordinate: coord, color: color)
            allPoints.append(data)
            
            let pointRect = MKMapRect(x: data.mapPoint.x, y: data.mapPoint.y, width: 0, height: 0)
            rect = rect.union(pointRect)
        }
        
        self.points = allPoints
        self.pointType = .stormDrain
        self.boundingMapRect = rect
        
        super.init()
    }
}

// MARK: - Composite Point Renderer

class CompositePointRenderer: MKOverlayRenderer {
    
    private let baseMarkerSize: CGFloat = 12.0
    private var colorCache: [String: (fill: CGColor, stroke: CGColor)] = [:]
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let composite = overlay as? CompositePointOverlay else { return }
        
        // Expand rect to catch points at edges
        let buffer = mapRect.width * 0.1
        let expandedRect = mapRect.insetBy(dx: -buffer, dy: -buffer)
        
        // Filter to visible points
        let visiblePoints = composite.points.filter { point in
            expandedRect.contains(point.mapPoint)
        }
        
        guard !visiblePoints.isEmpty else { return }
        
        // Marker size - constant on screen
        let markerSize = baseMarkerSize / zoomScale
        let lineWidth = max(1.0, 2.0 / zoomScale)
        
        // Group by color for batched drawing
        var byColor: [String: [CompositePointOverlay.PointData]] = [:]
        for point in visiblePoints {
            byColor[point.colorHex, default: []].append(point)
        }
        
        let isPointSite = composite.pointType == .pointSite
        
        for (colorHex, points) in byColor {
            let colors = getCachedColors(hex: colorHex)
            
            context.setFillColor(colors.fill)
            context.setStrokeColor(colors.stroke)
            context.setLineWidth(lineWidth)
            
            for point in points {
                let cgPoint = self.point(for: point.mapPoint)
                let rect = CGRect(
                    x: cgPoint.x - markerSize / 2,
                    y: cgPoint.y - markerSize / 2,
                    width: markerSize,
                    height: markerSize
                )
                
                if isPointSite {
                    // Circle for point sites
                    context.fillEllipse(in: rect)
                    context.strokeEllipse(in: rect)
                } else {
                    // Square for storm drains
                    context.fill(rect)
                    context.stroke(rect)
                }
            }
        }
    }
    
    private func getCachedColors(hex: String) -> (fill: CGColor, stroke: CGColor) {
        if let cached = colorCache[hex] {
            return cached
        }
        
        let uiColor = UIColor(hexString: hex)
        let fill = uiColor.cgColor
        let stroke = UIColor.white.cgColor
        
        let entry = (fill: fill, stroke: stroke)
        colorCache[hex] = entry
        return entry
    }
}

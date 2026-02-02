//
//  CompositeFieldOverlay.swift
//  MADxSync
//
//  Single overlay that renders ALL field polygons in one draw call.
//  This avoids the memory explosion from 2,009 individual MKPolygonRenderers.
//

import MapKit
import CoreLocation

// MARK: - Composite Field Overlay

/// A single MKOverlay that contains ALL field polygons.
/// MapKit creates ONE renderer for this, not 2,009.
class CompositeFieldOverlay: NSObject, MKOverlay {
    
    /// Pre-computed polygon data for efficient rendering
    struct PolygonData {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let boundingRect: MKMapRect
        
        init(field: FieldPolygon) {
            self.id = field.id
            
            // Extract coordinates based on geometry type
            switch field.geometry {
            case .polygon(let poly):
                self.coordinates = poly.outerRing
            case .multiPolygon(let multi):
                self.coordinates = multi.polygons.first ?? []
            case .multiLineString(let multi):
                // QGIS exported polygons as MultiLineString
                self.coordinates = multi.lines.first ?? []
            case .lineString(let line):
                self.coordinates = line.coordinates2D
            default:
                self.coordinates = []
            }
            
            // Pre-compute bounding rect for viewport culling
            if !coordinates.isEmpty {
                var rect = MKMapRect.null
                for coord in coordinates {
                    let point = MKMapPoint(coord)
                    let pointRect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
                    rect = rect.union(pointRect)
                }
                self.boundingRect = rect
            } else {
                self.boundingRect = MKMapRect.null
            }
        }
        
        var isValid: Bool {
            coordinates.count >= 3
        }
    }
    
    /// All polygon data, pre-processed for fast rendering
    let polygons: [PolygonData]
    
    /// Combined bounding rect of all polygons
    let boundingMapRect: MKMapRect
    
    /// Center coordinate (required by MKOverlay)
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }
    
    /// Initialize with field data from SpatialService
    init(fields: [FieldPolygon]) {
        // Pre-process all fields into render-ready data
        self.polygons = fields.compactMap { field in
            let data = PolygonData(field: field)
            return data.isValid ? data : nil
        }
        
        // Calculate union of all bounding rects
        self.boundingMapRect = polygons.reduce(MKMapRect.null) { result, polygon in
            result.union(polygon.boundingRect)
        }
        
        super.init()
        
        print("[CompositeFieldOverlay] Created with \(polygons.count) valid polygons")
    }
}

// MARK: - Composite Field Renderer

/// Renders all field polygons in a single draw() call using Core Graphics.
/// This is the key to avoiding the GPU memory explosion.
class CompositeFieldRenderer: MKOverlayRenderer {
    
    /// Stroke color for field boundaries
    private let strokeColor = UIColor.systemGreen.withAlphaComponent(0.8).cgColor
    
    /// Optional fill color (nil = no fill, stroke only)
    private let fillColor: CGColor? = nil // UIColor.systemGreen.withAlphaComponent(0.05).cgColor
    
    /// Base line width (will be adjusted for zoom)
    private let baseLineWidth: CGFloat = 1.0
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let composite = overlay as? CompositeFieldOverlay else { return }
        
        // Expand mapRect slightly to avoid popping at edges
        let buffer = mapRect.width * 0.1
        let expandedRect = mapRect.insetBy(dx: -buffer, dy: -buffer)
        
        // Filter to only polygons visible in this tile
        let visiblePolygons = composite.polygons.filter { polygon in
            polygon.boundingRect.intersects(expandedRect)
        }
        
        guard !visiblePolygons.isEmpty else { return }
        
        // Configure context for drawing
        context.setStrokeColor(strokeColor)
        
        // Line width should be constant on screen regardless of zoom
        // MKZoomScale is (points per MapPoint), smaller = zoomed out
        let adjustedLineWidth = baseLineWidth / zoomScale
        context.setLineWidth(adjustedLineWidth)
        
        // Optional fill
        if let fill = fillColor {
            context.setFillColor(fill)
        }
        
        // Draw all visible polygons
        for polygon in visiblePolygons {
            drawPolygon(polygon.coordinates, in: context)
        }
        
        // Stroke (and optionally fill) all paths at once
        if fillColor != nil {
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
        }
    }
    
    /// Draw a single polygon path
    private func drawPolygon(_ coordinates: [CLLocationCoordinate2D], in context: CGContext) {
        guard coordinates.count >= 3 else { return }
        
        // Convert first coordinate to renderer point
        let firstPoint = point(for: MKMapPoint(coordinates[0]))
        context.move(to: firstPoint)
        
        // Add lines to remaining coordinates
        for i in 1..<coordinates.count {
            let mapPoint = MKMapPoint(coordinates[i])
            let cgPoint = point(for: mapPoint)
            context.addLine(to: cgPoint)
        }
        
        // Close the polygon
        context.closePath()
    }
}

// MARK: - Composite Polyline Overlay (for ditches/canals)

/// Same approach for polylines - single overlay, single renderer
class CompositePolylineOverlay: NSObject, MKOverlay {
    
    struct PolylineData {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let boundingRect: MKMapRect
        
        init(polyline: SpatialPolyline) {
            self.id = polyline.id
            
            switch polyline.geometry {
            case .lineString(let line):
                self.coordinates = line.coordinates2D
            case .multiLineString(let multi):
                self.coordinates = multi.lines.first ?? []
            default:
                self.coordinates = []
            }
            
            if !coordinates.isEmpty {
                var rect = MKMapRect.null
                for coord in coordinates {
                    let point = MKMapPoint(coord)
                    let pointRect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
                    rect = rect.union(pointRect)
                }
                self.boundingRect = rect
            } else {
                self.boundingRect = MKMapRect.null
            }
        }
        
        var isValid: Bool {
            coordinates.count >= 2
        }
    }
    
    let polylines: [PolylineData]
    let boundingMapRect: MKMapRect
    
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }
    
    init(polylines: [SpatialPolyline]) {
        self.polylines = polylines.compactMap { line in
            let data = PolylineData(polyline: line)
            return data.isValid ? data : nil
        }
        
        self.boundingMapRect = self.polylines.reduce(MKMapRect.null) { result, line in
            result.union(line.boundingRect)
        }
        
        super.init()
        
        print("[CompositePolylineOverlay] Created with \(self.polylines.count) valid polylines")
    }
}

// MARK: - Composite Polyline Renderer

class CompositePolylineRenderer: MKOverlayRenderer {
    
    private let strokeColor = UIColor.cyan.withAlphaComponent(0.8).cgColor
    private let baseLineWidth: CGFloat = 2.0
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let composite = overlay as? CompositePolylineOverlay else { return }
        
        let buffer = mapRect.width * 0.1
        let expandedRect = mapRect.insetBy(dx: -buffer, dy: -buffer)
        
        let visiblePolylines = composite.polylines.filter { line in
            line.boundingRect.intersects(expandedRect)
        }
        
        guard !visiblePolylines.isEmpty else { return }
        
        context.setStrokeColor(strokeColor)
        context.setLineWidth(baseLineWidth / zoomScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        for line in visiblePolylines {
            drawPolyline(line.coordinates, in: context)
        }
        
        context.strokePath()
    }
    
    private func drawPolyline(_ coordinates: [CLLocationCoordinate2D], in context: CGContext) {
        guard coordinates.count >= 2 else { return }
        
        let firstPoint = point(for: MKMapPoint(coordinates[0]))
        context.move(to: firstPoint)
        
        for i in 1..<coordinates.count {
            let mapPoint = MKMapPoint(coordinates[i])
            let cgPoint = point(for: mapPoint)
            context.addLine(to: cgPoint)
        }
    }
}

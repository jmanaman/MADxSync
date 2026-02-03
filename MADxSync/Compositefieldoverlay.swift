//
//  CompositeFieldOverlay.swift
//  MADxSync
//
//  Single overlay that renders ALL field polygons in one draw call.
//  Supports per-polygon coloring based on treatment status from Hub.
//

import MapKit
import CoreLocation
import UIKit

// MARK: - Composite Field Overlay

/// A single MKOverlay that contains ALL field polygons.
/// MapKit creates ONE renderer for this, not 2,009.
class CompositeFieldOverlay: NSObject, MKOverlay {
    
    /// Pre-computed polygon data for efficient rendering
    struct PolygonData {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let boundingRect: MKMapRect
        var colorHex: String   // Treatment status color from Hub
        
        init(field: FieldPolygon, color: String) {
            self.id = field.id
            self.colorHex = color
            
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
    
    /// Initialize with field data and color lookup from TreatmentStatusService
    /// - Parameters:
    ///   - fields: All field polygons from SpatialService
    ///   - colorForFeature: Closure that returns hex color for a feature ID
    init(fields: [FieldPolygon], colorForFeature: (String) -> String) {
        // Pre-process all fields into render-ready data with colors
        self.polygons = fields.compactMap { field in
            let color = colorForFeature(field.id)
            let data = PolygonData(field: field, color: color)
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
/// Each polygon is drawn in its treatment status color.
class CompositeFieldRenderer: MKOverlayRenderer {
    
    /// Outline color for all fields (matches Hub CONFIG.COLORS.FIELD_OUTLINE = #ffffff)
    private let outlineColor = UIColor.white.withAlphaComponent(0.8).cgColor
    
    /// Fill opacity (matches Hub CONFIG.FILL_OPACITY = 0.5)
    private let fillOpacity: CGFloat = 0.5
    
    /// Base line width
    private let baseLineWidth: CGFloat = 1.0
    
    /// Color cache to avoid repeated UIColor creation
    private var colorCache: [String: (fill: CGColor, stroke: CGColor)] = [:]
    
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
        
        // Line width constant on screen
        let adjustedLineWidth = baseLineWidth / zoomScale
        
        // Group polygons by color for batched drawing (fewer context state changes)
        var byColor: [String: [CompositeFieldOverlay.PolygonData]] = [:]
        for polygon in visiblePolygons {
            byColor[polygon.colorHex, default: []].append(polygon)
        }
        
        // Draw each color group
        for (colorHex, polygons) in byColor {
            let colors = getCachedColors(hex: colorHex)
            
            // Draw fills first
            context.setFillColor(colors.fill)
            for polygon in polygons {
                addPolygonPath(polygon.coordinates, in: context)
            }
            context.fillPath()
            
            // Then strokes (white outlines)
            context.setStrokeColor(outlineColor)
            context.setLineWidth(adjustedLineWidth)
            for polygon in polygons {
                addPolygonPath(polygon.coordinates, in: context)
            }
            context.strokePath()
        }
    }
    
    /// Add a polygon path to the context
    private func addPolygonPath(_ coordinates: [CLLocationCoordinate2D], in context: CGContext) {
        guard coordinates.count >= 3 else { return }
        
        let firstPoint = point(for: MKMapPoint(coordinates[0]))
        context.move(to: firstPoint)
        
        for i in 1..<coordinates.count {
            let mapPoint = MKMapPoint(coordinates[i])
            let cgPoint = point(for: mapPoint)
            context.addLine(to: cgPoint)
        }
        
        context.closePath()
    }
    
    /// Cache parsed colors to avoid re-parsing hex on every draw call
    private func getCachedColors(hex: String) -> (fill: CGColor, stroke: CGColor) {
        if let cached = colorCache[hex] {
            return cached
        }
        
        let uiColor = UIColor(hexString: hex)
        let fill = uiColor.withAlphaComponent(fillOpacity).cgColor
        let stroke = uiColor.withAlphaComponent(0.8).cgColor
        
        let entry = (fill: fill, stroke: stroke)
        colorCache[hex] = entry
        return entry
    }
}

// MARK: - Composite Polyline Overlay (for ditches/canals)

/// Same approach for polylines - single overlay, single renderer, per-feature colors
class CompositePolylineOverlay: NSObject, MKOverlay {
    
    struct PolylineData {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let boundingRect: MKMapRect
        var colorHex: String
        
        init(polyline: SpatialPolyline, color: String) {
            self.id = polyline.id
            self.colorHex = color
            
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
    
    init(polylines: [SpatialPolyline], colorForFeature: (String) -> String) {
        self.polylines = polylines.compactMap { line in
            let color = colorForFeature(line.id)
            let data = PolylineData(polyline: line, color: color)
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
    
    private let baseLineWidth: CGFloat = 4.0
    private var colorCache: [String: CGColor] = [:]
    
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let composite = overlay as? CompositePolylineOverlay else { return }
        
        let buffer = mapRect.width * 0.1
        let expandedRect = mapRect.insetBy(dx: -buffer, dy: -buffer)
        
        let visiblePolylines = composite.polylines.filter { line in
            line.boundingRect.intersects(expandedRect)
        }
        
        guard !visiblePolylines.isEmpty else { return }
        
        let adjustedLineWidth = baseLineWidth / zoomScale
        context.setLineWidth(adjustedLineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        // Group by color for batched drawing
        var byColor: [String: [CompositePolylineOverlay.PolylineData]] = [:]
        for line in visiblePolylines {
            byColor[line.colorHex, default: []].append(line)
        }
        
        for (colorHex, lines) in byColor {
            let color = getCachedColor(hex: colorHex)
            context.setStrokeColor(color)
            
            for line in lines {
                addPolylinePath(line.coordinates, in: context)
            }
            
            context.strokePath()
        }
    }
    
    private func addPolylinePath(_ coordinates: [CLLocationCoordinate2D], in context: CGContext) {
        guard coordinates.count >= 2 else { return }
        
        let firstPoint = point(for: MKMapPoint(coordinates[0]))
        context.move(to: firstPoint)
        
        for i in 1..<coordinates.count {
            let mapPoint = MKMapPoint(coordinates[i])
            let cgPoint = point(for: mapPoint)
            context.addLine(to: cgPoint)
        }
    }
    
    private func getCachedColor(hex: String) -> CGColor {
        if let cached = colorCache[hex] {
            return cached
        }
        let color = UIColor(hexString: hex).withAlphaComponent(0.8).cgColor
        colorCache[hex] = color
        return color
    }
}

// MARK: - UIColor Hex Extension

extension UIColor {
    convenience init(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

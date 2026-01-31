import SwiftUI
import MapKit
import MapCache

struct MapTestView: View {
    var body: some View {
        VStack {
            Text("MapCache Offline Test")
                .font(.headline)
                .padding()
            
            CachedMapView()
                .edgesIgnoringSafeArea(.bottom)
        }
    }
}

// UIKit wrapper for MKMapView with MapCache
struct CachedMapView: UIViewRepresentable {
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Center on Tulare County
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 36.2077, longitude: -119.3473),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        mapView.setRegion(region, animated: false)
        
        // Setup MapCache with OpenStreetMap tiles
        let config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
        let mapCache = MapCache(withConfig: config)
        mapView.useCache(mapCache)
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            return mapView.mapCacheRenderer(forOverlay: overlay)
        }
    }
}

#Preview {
    MapTestView()
}

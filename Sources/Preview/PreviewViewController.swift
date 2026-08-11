import Cocoa
import Quartz
import MapKit

/// Tags the white outline drawn underneath the colored track line.
private final class CasingPolyline: MKPolyline {}

/// Thunderforest Outdoors base map — the same "Outdoor" layer (and public API
/// key) as seriot.ch/gpx_editor. Replaces Apple's base map, whose tiles
/// GeoServices cannot load under the Quick Look sandbox; these are fetched
/// with a plain URLSession instead.
private final class BaseTileOverlay: MKTileOverlay {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "QuickGPX/0.1 (macOS Quick Look extension)"]
        return URLSession(configuration: config)
    }()

    init() {
        // Thunderforest renders true 512px Retina tiles; openstreetmap.org
        // serves only 256px tiles, which are inevitably blurry when upscaled
        // to readable label size on Retina displays.
        super.init(urlTemplate: "https://tile.thunderforest.com/outdoors/{z}/{x}/{y}@2x.png?apikey=6170aad10dfd42a38d4d8c709a536f38")
        canReplaceMapContent = true
        minimumZ = 1
        maximumZ = 20
        // 512 pt tiles cancel MapKit's Retina zoom offset, so the @2x tiles
        // render at native pixels: crisp labels at full size.
        tileSize = CGSize(width: 512, height: 512)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        session.dataTask(with: url(forTilePath: path)) { data, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                NSLog("QuickGPX tile HTTP %d for %d/%d/%d", status, path.z, path.x, path.y)
            }
            if let error {
                NSLog("QuickGPX tile error for %d/%d/%d: %@", path.z, path.x, path.y,
                      String(describing: error))
            }
            result(data, error)
        }.resume()
    }
}

private final class EndpointAnnotation: MKPointAnnotation {
    var isStart = false
}

/// Marks the position hovered in the elevation profile.
private final class HoverDotAnnotation: MKPointAnnotation {}

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let mapView = MKMapView()
    private let statsBar = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let attributionLabel = NSTextField(labelWithString: "© Thunderforest · © OpenStreetMap contributors")
    private let profileBar = NSVisualEffectView()
    private let profileView = ElevationProfileView()
    private var profileHeight: NSLayoutConstraint!
    private let hoverAnnotation = HoverDotAnnotation()
    private var hoverDotShown = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        preferredContentSize = view.frame.size

        mapView.delegate = self
        mapView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapView)

        attributionLabel.font = .systemFont(ofSize: 9)
        attributionLabel.textColor = .secondaryLabelColor
        attributionLabel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7)
        attributionLabel.drawsBackground = true
        attributionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(attributionLabel)

        profileBar.material = .headerView
        profileBar.blendingMode = .withinWindow
        profileBar.isHidden = true
        profileBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(profileBar)

        profileView.translatesAutoresizingMaskIntoConstraints = false
        profileBar.addSubview(profileView)
        profileHeight = profileBar.heightAnchor.constraint(equalToConstant: 0)

        statsBar.material = .headerView
        statsBar.blendingMode = .withinWindow
        statsBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statsBar)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        statsBar.addSubview(titleLabel)

        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsBar.addSubview(statsLabel)

        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statsBar.topAnchor.constraint(equalTo: view.topAnchor),
            statsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: statsBar.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: statsBar.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsBar.trailingAnchor, constant: -12),

            statsLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            statsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsBar.trailingAnchor, constant: -12),
            statsLabel.bottomAnchor.constraint(equalTo: statsBar.bottomAnchor, constant: -8),

            attributionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            attributionLabel.bottomAnchor.constraint(equalTo: profileBar.topAnchor, constant: -4),

            profileBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            profileBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            profileBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            profileHeight,

            profileView.topAnchor.constraint(equalTo: profileBar.topAnchor),
            profileView.bottomAnchor.constraint(equalTo: profileBar.bottomAnchor),
            profileView.leadingAnchor.constraint(equalTo: profileBar.leadingAnchor),
            profileView.trailingAnchor.constraint(equalTo: profileBar.trailingAnchor),
        ])
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let gpx = try GPXDocument(contentsOf: url)
                DispatchQueue.main.async {
                    self.pendingGPX = gpx
                    self.pendingFileName = url.deletingPathExtension().lastPathComponent
                    self.renderIfReady()
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async { handler(error) }
            }
        }
    }

    // MKMapView drops overlays (tiles and polylines) that are added while the
    // view is not yet attached to a window — a race that intermittently blanks
    // the map when the preview is set up before ViewBridge attaches the remote
    // view. Defer all map population until we are in a window.
    private var pendingGPX: GPXDocument?
    private var pendingFileName = ""

    private func renderIfReady() {
        guard view.window != nil, let gpx = pendingGPX else { return }
        pendingGPX = nil
        render(gpx, fileName: pendingFileName)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        renderIfReady()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        renderIfReady()
    }

    // MARK: - Rendering

    private func render(_ gpx: GPXDocument, fileName: String) {
        mapView.addOverlay(BaseTileOverlay(), level: .aboveLabels)
        var fitRect = MKMapRect.null

        var dateText: String?
        if let date = gpx.activityDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            dateText = formatter.string(from: date)
        }
        titleLabel.stringValue = dateText ?? gpx.name ?? fileName
        if let coordinate = gpx.startCoordinate {
            reverseGeocode(coordinate) { [weak self] place in
                guard let self, let place else { return }
                self.titleLabel.stringValue = [place, dateText].compactMap { $0 }.joined(separator: " · ")
            }
        }

        for segment in gpx.segments where segment.count > 1 {
            let coordinates = segment.map { $0.coordinate }
            let casing = CasingPolyline(coordinates: coordinates, count: coordinates.count)
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(casing, level: .aboveLabels)
            mapView.addOverlay(line, level: .aboveLabels)
            fitRect = fitRect.union(line.boundingMapRect)
        }

        if let first = gpx.segments.first?.first, let last = gpx.segments.last?.last {
            let start = EndpointAnnotation()
            start.isStart = true
            start.coordinate = first.coordinate
            start.title = "Start"
            let end = EndpointAnnotation()
            end.coordinate = last.coordinate
            end.title = "End"
            mapView.addAnnotations(gpx.pointCount > 1 ? [start, end] : [start])
        }

        for waypoint in gpx.waypoints {
            let annotation = MKPointAnnotation()
            annotation.coordinate = waypoint.coordinate
            annotation.title = waypoint.name
            mapView.addAnnotation(annotation)
            fitRect = fitRect.union(MKMapRect(origin: MKMapPoint(waypoint.coordinate), size: MKMapSize()))
        }

        let profile = gpx.elevationProfile
        let showProfile = profile.count > 1
        if showProfile {
            profileView.profile = profile
            profileHeight.constant = 118
            profileBar.isHidden = false
            profileView.onHover = { [weak self] point in
                guard let self else { return }
                if let point {
                    self.hoverAnnotation.coordinate = point.coordinate
                    if !self.hoverDotShown {
                        self.mapView.addAnnotation(self.hoverAnnotation)
                        self.hoverDotShown = true
                    }
                } else if self.hoverDotShown {
                    self.mapView.removeAnnotation(self.hoverAnnotation)
                    self.hoverDotShown = false
                }
            }
        }

        if !fitRect.isNull {
            // Guarantee a sane minimum span for single points / tiny tracks (~600 m).
            let minSpan = MKMapPointsPerMeterAtLatitude(fitRect.origin.coordinate.latitude) * 600
            if fitRect.width < minSpan || fitRect.height < minSpan {
                fitRect = fitRect.insetBy(dx: -max(0, (minSpan - fitRect.width) / 2),
                                          dy: -max(0, (minSpan - fitRect.height) / 2))
            }
            view.layoutSubtreeIfNeeded()
            mapView.setVisibleMapRect(
                fitRect,
                edgePadding: NSEdgeInsets(top: 76, left: 44,
                                          bottom: showProfile ? 118 + 32 : 44, right: 44),
                animated: false)
        }

        statsLabel.stringValue = statsText(for: gpx)
    }

    /// Locality name for the track's start point, via OSM Nominatim (Apple's
    /// CLGeocoder needs geod, which the Quick Look sandbox blocks).
    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D,
                                completion: @escaping (String?) -> Void) {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "zoom", value: "16"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("QuickGPX/0.1 (macOS Quick Look extension)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var place: String?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let address = json["address"] as? [String: Any] {
                for key in ["village", "hamlet", "town", "city", "municipality", "county"] {
                    if let value = address[key] as? String { place = value; break }
                }
            }
            DispatchQueue.main.async { completion(place) }
        }.resume()
    }

    private func statsText(for gpx: GPXDocument) -> String {
        var parts: [String] = []

        let distance = gpx.totalDistance
        if distance > 0 {
            parts.append(distance >= 1000
                ? String(format: "%.1f km", distance / 1000)
                : String(format: "%.0f m", distance))
        }
        if let gain = gpx.elevationGain, gain >= 1 {
            parts.append(String(format: "D+ %.0f m", gain))
        }
        if let range = gpx.elevationRange, range.max - range.min >= 1 {
            parts.append(String(format: "%.0f–%.0f m alt.", range.min, range.max))
        }
        if let duration = gpx.duration {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .abbreviated
            if let text = formatter.string(from: duration) { parts.append(text) }
        }
        if gpx.pointCount > 0 {
            parts.append("\(gpx.pointCount.formatted()) points")
        }
        if !gpx.waypoints.isEmpty {
            parts.append("\(gpx.waypoints.count) waypoints")
        }
        return parts.joined(separator: "  ·  ")
    }
}

extension PreviewViewController: MKMapViewDelegate {

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.lineJoin = .round
        renderer.lineCap = .round
        if polyline is CasingPolyline {
            renderer.strokeColor = NSColor.white.withAlphaComponent(0.9)
            renderer.lineWidth = 6.5
        } else {
            renderer.strokeColor = .trackOrange
            renderer.lineWidth = 3.5
        }
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is MKPointAnnotation else { return nil }
        if annotation is HoverDotAnnotation {
            let identifier = "hoverdot"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.frame = NSRect(x: 0, y: 0, width: 14, height: 14)
            view.wantsLayer = true
            view.layer?.cornerRadius = 7
            view.layer?.backgroundColor = NSColor.trackOrange.cgColor
            view.layer?.borderColor = NSColor.white.cgColor
            view.layer?.borderWidth = 2.5
            view.isEnabled = false
            return view
        }
        let identifier = "marker"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.canShowCallout = true
        if let endpoint = annotation as? EndpointAnnotation {
            view.markerTintColor = endpoint.isStart ? .systemGreen : .systemRed
            view.glyphImage = NSImage(systemSymbolName: endpoint.isStart ? "figure.walk" : "flag.checkered",
                                      accessibilityDescription: nil)
        } else {
            view.markerTintColor = .systemIndigo
            view.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
        }
        return view
    }
}

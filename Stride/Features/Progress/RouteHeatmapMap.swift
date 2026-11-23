import SwiftUI
import MapKit

// MARK: - The map

/// The heatmap on a live map: every cell any run went through, as a square coloured by
/// how many runs did.
///
/// The cells are one custom overlay (``HeatCellOverlay``) whose renderer draws only the
/// cells inside each tile MapKit asks for, on MapKit's own background threads. The first
/// version drew joined-up lines instead; with real GPS wander those became tens of
/// thousands of tiny polylines, built on the main thread and stroked in full for every
/// tile, which is what made Progress slow.
struct RouteHeatmapMap: UIViewRepresentable {
    let heatmap: RouteHeatmap.Heatmap
    var style: Style = .map
    /// Changing it moves the map back onto the streets run most.
    var recenter = 0
    /// Where the runner last tapped, marked on the map.
    var selection: RouteHeatmap.Point?
    /// A tap on the map: where, and how many metres a fingertip covers at this zoom.
    var onTap: ((RouteHeatmap.Point, Double) -> Void)?
    /// Streets first run in the period, drawn bright over a dimmed heatmap. `nil` hides it.
    var newGround: RouteHeatmap.NewGround?

    /// The base map under the heat.
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case map
        case dark
        case satellite

        var id: String { rawValue }

        var title: String {
            switch self {
            case .map: return String(localized: "Map")
            case .dark: return String(localized: "Dark")
            case .satellite: return String(localized: "Satellite")
            }
        }
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        map.delegate = context.coordinator
        map.isAccessibilityElement = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        if coordinator.selection != selection {
            coordinator.selection = selection
            if let marker = coordinator.marker { map.removeAnnotation(marker) }
            coordinator.marker = nil
            if let selection {
                let marker = MKPointAnnotation()
                marker.coordinate = CLLocationCoordinate2D(latitude: selection.latitude, longitude: selection.longitude)
                map.addAnnotation(marker)
                coordinator.marker = marker
            }
        }
        map.accessibilityLabel = String(
            localized: "Heatmap of \(heatmap.runCount) runs. Brighter squares are streets you run more often."
        )
        if coordinator.style != style {
            coordinator.style = style
            switch style {
            case .map:
                map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
                map.overrideUserInterfaceStyle = .unspecified
            case .dark:
                map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
                map.overrideUserInterfaceStyle = .dark
            case .satellite:
                map.preferredConfiguration = MKImageryMapConfiguration()
                map.overrideUserInterfaceStyle = .dark
            }
        }
        // Compares build ids, not cells.
        if coordinator.shown != heatmap {
            let isFirst = coordinator.shown == nil
            coordinator.shown = heatmap
            if let old = coordinator.overlay { map.removeOverlay(old) }
            let overlay = HeatCellOverlay(dots: HeatDots(heatmap, colors: HeatDots.heatColors()))
            map.addOverlay(overlay, level: .aboveRoads)
            coordinator.overlay = overlay
            if isFirst {
                coordinator.recentered = recenter
                Self.moveToFocus(map, overlay, animated: false)
            }
        }
        if coordinator.newGround != newGround {
            coordinator.newGround = newGround
            if let old = coordinator.newOverlay { map.removeOverlay(old) }
            coordinator.newOverlay = nil
            if let newGround, !newGround.cells.isEmpty {
                let overlay = HeatCellOverlay(dots: HeatDots(newGround, color: HeatDots.rgba(Self.newGroundColor)))
                map.addOverlay(overlay, level: .aboveRoads)
                coordinator.newOverlay = overlay
            }
            // Dim the heat under new ground so the new streets stand out.
            if let heat = coordinator.overlay {
                map.renderer(for: heat)?.alpha = coordinator.heatAlpha
            }
        }
        if coordinator.recentered != recenter {
            coordinator.recentered = recenter
            if let overlay = coordinator.overlay { Self.moveToFocus(map, overlay, animated: true) }
        }
    }

    private static func moveToFocus(_ map: MKMapView, _ overlay: HeatCellOverlay, animated: Bool) {
        guard let focus = overlay.dots.focus else { return }
        map.setVisibleMapRect(focus, edgePadding: UIEdgeInsets(top: 32, left: 24, bottom: 32, right: 24), animated: animated)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Brand orange from faint (run once) to full, then the glow for the most run.
    static func color(level: Int) -> Color {
        switch level {
        case ...1: return Color.brand.opacity(0.35)
        case 2: return Color.brand.opacity(0.55)
        case 3: return Color.brand.opacity(0.75)
        case 4: return Color.brand
        default: return Color.brandGlow
        }
    }

    /// New ground's colour: away from the orange heat, so the two never mix up.
    static let newGroundColor = Color.success

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var shown: RouteHeatmap.Heatmap?
        var overlay: HeatCellOverlay?
        var newGround: RouteHeatmap.NewGround?
        var newOverlay: HeatCellOverlay?

        var heatAlpha: CGFloat { newGround == nil ? 1 : 0.3 }
        var style: Style?
        var recentered = 0
        var onTap: ((RouteHeatmap.Point, Double) -> Void)?
        var selection: RouteHeatmap.Point?
        var marker: MKPointAnnotation?

        /// Hands the tap on as a map point, with the metres 22 points cover at this zoom
        /// (about a fingertip), so a zoomed-out tap still finds the street under it.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let onTap, let map = gesture.view as? MKMapView, gesture.state == .ended else { return }
            let spot = gesture.location(in: map)
            let here = map.convert(spot, toCoordinateFrom: map)
            let reach = map.convert(CGPoint(x: spot.x + 22, y: spot.y), toCoordinateFrom: map)
            let point = RouteHeatmap.Point(latitude: here.latitude, longitude: here.longitude)
            let radius = RouteHeatmap.distance(point, RouteHeatmap.Point(latitude: reach.latitude, longitude: reach.longitude))
            onTap(point, min(max(radius, 20), 400))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let overlay = overlay as? HeatCellOverlay {
                let renderer = HeatCellRenderer(heat: overlay)
                if overlay !== newOverlay { renderer.alpha = heatAlpha }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Cells, ready to draw

/// The heatmap's cells in map points, bucketed by area so a tile finds its cells without
/// looking at the rest, with the heat colours worked out once. Immutable, so the
/// renderer's background threads can read it freely.
final class HeatDots: Sendable {
    struct Dot: Sendable {
        let x: Double
        let y: Double
        let level: Int
    }

    /// RGBA per level, index 0 unused.
    struct RGBA: Sendable {
        let red: Double, green: Double, blue: Double, alpha: Double
    }

    /// The side of a bucket: 1/16384 of the world, about 2.4 km at the equator.
    static let bucketSide = MKMapSize.world.width / 16_384

    let buckets: [Int64: [Dot]]
    let count: Int
    /// Half the side of a cell's square, in map points, at the cells' latitude.
    let halfSide: Double
    let colors: [RGBA]
    /// Where the map opens, as map-point x, y, width, height: the cells run more than
    /// once, so one race abroad doesn't zoom the map out to take it in.
    private let focusBox: [Double]?

    var focus: MKMapRect? {
        focusBox.map { MKMapRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }

    /// The heat colours as the map draws them, worked out on the main actor (SwiftUI
    /// colours resolve there), for building ``HeatDots`` anywhere.
    @MainActor
    static func heatColors() -> [RGBA] {
        (0...RouteHeatmap.levels).map { rgba(RouteHeatmapMap.color(level: max($0, 1))) }
    }

    /// A SwiftUI colour as plain numbers, resolved for the dark map.
    @MainActor
    static func rgba(_ color: Color) -> RGBA {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    convenience init(_ heatmap: RouteHeatmap.Heatmap, colors: [RGBA]) {
        self.init(cells: heatmap.cells.map { ($0.center, $0.level) }, colors: colors)
    }

    /// New ground: every cell at level 1, in `color`.
    convenience init(_ newGround: RouteHeatmap.NewGround, color: RGBA) {
        self.init(
            cells: newGround.cells.map { ($0, 1) },
            colors: [RGBA](repeating: color, count: RouteHeatmap.levels + 1)
        )
    }

    /// - Parameter cells: centres and levels, coolest first, so each bucket draws its
    ///   hottest last.
    init(cells: [(center: RouteHeatmap.Point, level: Int)], colors: [RGBA]) {
        var buckets: [Int64: [Dot]] = [:]
        var focusRect: MKMapRect?
        var anyRect: MKMapRect?
        var latitudeSum = 0.0
        for cell in cells {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: cell.center.latitude, longitude: cell.center.longitude))
            buckets[Self.key(x: point.x, y: point.y), default: []].append(Dot(x: point.x, y: point.y, level: cell.level))
            let spot = MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0))
            anyRect = anyRect.map { $0.union(spot) } ?? spot
            if cell.level >= 2 { focusRect = focusRect.map { $0.union(spot) } ?? spot }
            latitudeSum += cell.center.latitude
        }
        self.buckets = buckets
        count = cells.count
        let latitude = cells.isEmpty ? 0 : latitudeSum / Double(cells.count)
        let half = RouteHeatmap.cellMeters * MKMapPointsPerMeterAtLatitude(latitude) * 0.6
        halfSide = half
        focusBox = (focusRect ?? anyRect).map {
            let box = $0.insetBy(dx: -half * 20, dy: -half * 20)
            return [box.minX, box.minY, box.width, box.height]
        }
        self.colors = colors
    }

    static func key(x: Double, y: Double) -> Int64 {
        (Int64(x / bucketSide) << 32) | Int64(y / bucketSide)
    }

    /// The cells inside `rect`, by level.
    func dots(in rect: MKMapRect) -> [[Dot]] {
        var byLevel = [[Dot]](repeating: [], count: RouteHeatmap.levels + 1)
        let minX = Int64(max(rect.minX, 0) / Self.bucketSide)
        let maxX = Int64(max(rect.maxX, 0) / Self.bucketSide)
        let minY = Int64(max(rect.minY, 0) / Self.bucketSide)
        let maxY = Int64(max(rect.maxY, 0) / Self.bucketSide)
        func take(_ dots: [Dot]) {
            for dot in dots where rect.contains(MKMapPoint(x: dot.x, y: dot.y)) {
                byLevel[min(max(dot.level, 1), RouteHeatmap.levels)].append(dot)
            }
        }
        // Zoomed far out, a tile covers more buckets than exist: walk the buckets instead.
        if (maxX - minX + 1) * (maxY - minY + 1) > Int64(buckets.count) {
            for (_, dots) in buckets { take(dots) }
        } else {
            for x in minX...maxX {
                for y in minY...maxY {
                    if let dots = buckets[(x << 32) | y] { take(dots) }
                }
            }
        }
        return byLevel
    }

    /// Fills each cell's square, coolest level first. `minimumSide` keeps a cell visible
    /// when zoomed out, in the drawing's units.
    func fill(
        in context: CGContext,
        rect: MKMapRect,
        minimumSide: Double,
        alphaScale: Double = 1,
        place: (Dot) -> CGPoint,
        scale: Double
    ) {
        let half = max(halfSide * scale, minimumSide / 2)
        let byLevel = dots(in: rect.insetBy(dx: -half / scale, dy: -half / scale))
        for level in 1...RouteHeatmap.levels where !byLevel[level].isEmpty {
            let color = colors[level]
            context.setFillColor(CGColor(
                red: color.red, green: color.green, blue: color.blue, alpha: color.alpha * alphaScale
            ))
            context.fill(byLevel[level].map {
                let center = place($0)
                return CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2)
            })
        }
    }
}

/// The overlay MapKit holds: the cells and the box they cover.
final class HeatCellOverlay: NSObject, MKOverlay {
    let dots: HeatDots
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(dots: HeatDots) {
        self.dots = dots
        boundingMapRect = .world
        coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }
}

/// Draws the cells inside each tile MapKit asks for. MapKit calls `draw` on background
/// threads, several at once; it reads only the immutable ``HeatDots``.
final class HeatCellRenderer: MKOverlayRenderer {
    private let heat: HeatDots

    init(heat overlay: HeatCellOverlay) {
        heat = overlay.dots
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // A cell is never drawn smaller than 2.5 screen points across.
        let minimumSide = 2.5 / zoomScale
        // The context is in map points relative to the renderer; `point(for:)` places them.
        heat.fill(in: context, rect: mapRect, minimumSide: minimumSide, place: { dot in
            self.point(for: MKMapPoint(x: dot.x, y: dot.y))
        }, scale: 1)
    }
}

// MARK: - Still preview

extension HeatDots {
    /// The heatmap drawn on its own, no map, framed on ``focus``. For the Progress card,
    /// which shows this picture instead of a live map: a live map on a scrolling page
    /// redraws as the page moves. Safe off the main thread.
    func preview(size: CGSize, background: RGBA) -> UIImage? {
        guard let focus, size.width > 0, size.height > 0 else { return nil }
        // Square up the focus to the picture's shape, with a margin.
        var frame = focus
        let aspect = size.width / size.height
        if frame.width / frame.height < aspect {
            let width = frame.height * aspect
            frame = MKMapRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
        } else {
            let height = frame.width / aspect
            frame = MKMapRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
        }
        frame = frame.insetBy(dx: -frame.width * 0.05, dy: -frame.height * 0.05)
        let scale = size.width / frame.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { rendering in
            let context = rendering.cgContext
            context.setFillColor(CGColor(
                red: background.red, green: background.green, blue: background.blue, alpha: background.alpha
            ))
            context.fill(CGRect(origin: .zero, size: size))
            fill(in: context, rect: frame, minimumSide: 1.6, place: { dot in
                CGPoint(x: (dot.x - frame.minX) * scale, y: (dot.y - frame.minY) * scale)
            }, scale: scale)
        }
    }
}

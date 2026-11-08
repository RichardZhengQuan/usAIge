import AppKit
import SceneKit
import simd

@available(macOS 14.0, *)
struct PaperweightSceneHit {
    let paperweight: PaperweightID
    let layerID: String
    let x: Double
}

/// One visibility-owned clock runs physics at 60 Hz and settled ship parts at
/// 15 Hz. Decorative ticks leave the fluid geometry and SwiftUI state alone.
@available(macOS 14.0, *)
@MainActor
final class PaperweightSceneRenderer: NSObject {
    private weak var view: SCNView?
    private let scene = SCNScene()
    private let camera = SCNNode()
    private var bottles: [PaperweightID: PaperweightBottle] = [:]
    private var front = PaperweightID.storage
    private var selectedLayerID: String?
    private var reduceMotion = false
    private var isDark = false
    private var isVisible = false
    private var initialMotionPending = true
    private var timer: Timer?
    private(set) var frameInterval: TimeInterval = 0
    var hasDrawingClock: Bool { timer != nil }
    private lazy var tickTarget = PaperweightTickTarget(owner: self)
    private var lastTime: TimeInterval = 0
    private var lastCommand: Int?
    private var swap: Swap?
    private var cameraReset: CameraReset?
    private var yaw = atan2(-0.6, 8.6)
    private var pitch = atan2(2.5, hypot(0.6, 8.6))
    private var zoomScale = 1.0
    private var zoomTarget = 1.0
    private var yawVelocity = 0.0
    private var pitchVelocity = 0.0
    private var dragging = false
    private var size = CGSize.zero
    private var moving = false
    private var onSelect: (PaperweightID, String) -> Void = { _, _ in }
    private var onSwap: (PaperweightID) -> Void = { _ in }
    private var onMovingChanged: (Bool) -> Void = { _ in }
    private var lastInputs: Inputs?

    private struct Swap { let from: PaperweightID; let to: PaperweightID; var progress = 0.0 }
    private struct CameraReset { let yaw: Double; let pitch: Double; let zoom: Double; var progress = 0.0 }
    private struct Inputs: Equatable {
        let configurations: [PaperweightConfiguration]
        let front: PaperweightID
        let selection: String?
        let ships: [PaperweightID: PaperweightShipKind]
        let command: PaperweightSceneCommand?
        let reduceMotion: Bool
        let dark: Bool
    }

    init(view: SCNView) {
        self.view = view
        super.init()
        view.scene = scene
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isPlaying = false
        scene.isPaused = true
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = PaperweightSceneAssets.environmentTexture()
        scene.lightingEnvironment.intensity = 1.3
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 100
        camera.camera?.wantsHDR = false
        camera.camera?.automaticallyAdjustsZRange = false
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        addLighting()
    }

    func update(configurations: [PaperweightConfiguration], front requestedFront: PaperweightID, selectedLayerID: String?,
                ships: [PaperweightID: PaperweightShipKind], command: PaperweightSceneCommand?, reduceMotion: Bool,
                isDark: Bool, onSelect: @escaping (PaperweightID, String) -> Void, onSwap: @escaping (PaperweightID) -> Void,
                onMovingChanged: @escaping (Bool) -> Void) {
        self.onSelect = onSelect
        self.onSwap = onSwap
        self.onMovingChanged = onMovingChanged
        let inputs = Inputs(configurations: configurations, front: requestedFront, selection: selectedLayerID,
                            ships: ships, command: command, reduceMotion: reduceMotion, dark: isDark)
        guard inputs != lastInputs else { return }
        lastInputs = inputs
        let firstUpdate = bottles.isEmpty
        let labelsChanged = self.selectedLayerID != selectedLayerID || self.isDark != isDark || self.front != requestedFront
        self.reduceMotion = reduceMotion
        self.isDark = isDark
        self.selectedLayerID = selectedLayerID
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        for configuration in configurations {
            let kind = ships[configuration.id] ?? (configuration.id == .memory ? .sailboat : .galleon)
            let selection = configuration.id == requestedFront ? selectedLayerID : nil
            if let bottle = bottles[configuration.id] {
                if bottle.simulation.configuration != configuration {
                    bottle.update(configuration: configuration, selected: selection, dark: isDark, reduceMotion: reduceMotion)
                } else if labelsChanged { bottle.refreshLabels(selected: selection, dark: isDark) }
                bottle.setShip(kind)
                bottle.updateVisuals(dt: 0, moving: false, geometryChanged: false)
            } else {
                let bottle = PaperweightBottle(configuration: configuration, shipKind: kind)
                bottle.refreshLabels(selected: selection, dark: isDark)
                bottles[configuration.id] = bottle
                scene.rootNode.addChildNode(bottle.group)
            }
        }
        for id in Array(bottles.keys) where !configurations.contains(where: { $0.id == id }) {
            bottles.removeValue(forKey: id)?.group.removeFromParentNode()
        }
        let swapping = requestedFront != self.front && !firstUpdate
        if swapping, !reduceMotion {
            swap = Swap(from: self.front, to: requestedFront)
        }
        self.front = requestedFront
        // A swap brings the camera back to the default view, so the newly
        // fronted paperweight is always seen whole, however it was zoomed.
        if swapping { resetCamera() }
        if reduceMotion { settleAll() }
        placeBottles()
        updateCamera()
        SCNTransaction.commit()
        if let command, command.id != lastCommand {
            lastCommand = command.id
            perform(command.kind)
        }
        if isVisible, initialMotionPending { startInitialMotion() }
        kick()
        requestRender()
    }

    func resize(_ newSize: CGSize) {
        guard newSize != size else { return }
        size = newSize
        placeBottles()
        updateCamera()
        requestRender()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if initialMotionPending { startInitialMotion() }
            kick()
            requestRender()
        } else {
            settleAll()
            stopTimer()
        }
    }

    private func startInitialMotion() {
        guard !bottles.isEmpty else { return }
        initialMotionPending = false
        guard !reduceMotion else { return }
        bottles[.storage]?.simulation.shake(amplitude: 150)
        bottles[.memory]?.simulation.shake(amplitude: 100)
    }

    private func perform(_ kind: PaperweightSceneCommand.Kind) {
        switch kind {
        case .reset: resetCamera()
        case .shake: if !reduceMotion { bottles[front]?.simulation.shake(amplitude: 240) }
        case .preview: if !reduceMotion { bottles[.storage]?.simulation.shake(amplitude: 90) }
        case .shipDrop:
            if !reduceMotion { bottles[front]?.simulation.dropShip() }
            else { bottles[front]?.simulation.settle() }
        }
        kick()
    }

    func hit(at point: CGPoint) -> PaperweightSceneHit? {
        guard let view, swap == nil else { return nil }
        let order: [PaperweightID] = [front, front == .storage ? .memory : .storage]
        for id in order {
            guard let bottle = bottles[id], let result = view.hitTest(point, options: [
                .rootNode: bottle.glass, .backFaceCulling: false, .firstFoundOnly: true,
                .ignoreHiddenNodes: true, .categoryBitMask: 1
            ]).first else { continue }
            let local = result.localCoordinates
            let x = min(PaperweightConstants.textureWidth, max(0, (Double(local.x) - PaperweightConstants.X0) / PaperweightConstants.unitsPerPixel))
            let y = (Double(local.y) - PaperweightConstants.Y0) / PaperweightConstants.unitsPerPixel
            let sample = min(PaperweightConstants.sampleCount - 1, max(0, Int((x / PaperweightConstants.dx).rounded())))
            let configuration = bottle.simulation.configuration
            let layer = configuration.layers.indices.first { y <= bottle.simulation.curve(layer: $0, sample: sample) }
            return PaperweightSceneHit(paperweight: id, layerID: layer.map { configuration.layers[$0].id } ?? configuration.freeLayer.id, x: x)
        }
        return nil
    }

    func click(at point: CGPoint) {
        guard let result = hit(at: point) else { return }
        if result.paperweight != front { onSwap(result.paperweight); return }
        if !reduceMotion { bottles[front]?.simulation.splash(x: result.x) }
        onSelect(front, result.layerID)
        kick()
    }

    func dragCamera(dx: CGFloat, dy: CGFloat) {
        cameraReset = nil
        dragging = true
        let x = Double(dx) * 0.006, y = Double(dy) * 0.005
        yaw = clamped(yaw + x, -35 * .pi / 180, 35 * .pi / 180)
        pitch = clamped(pitch + y, 8 * .pi / 180, 42 * .pi / 180)
        yawVelocity = reduceMotion ? 0 : x * 30
        pitchVelocity = reduceMotion ? 0 : y * 30
        if !reduceMotion {
            bottles[front]?.simulation.tiltTarget = clamped(x * 2, -0.09, 0.09)
            bottles[front]?.simulation.acceleration = clamped(x * 1.5, -0.3, 0.3)
        }
        updateCamera()
        kick()
        requestRender()
    }

    func endDragging() {
        dragging = false
        for bottle in bottles.values { bottle.simulation.tiltTarget = 0; bottle.simulation.acceleration = 0 }
        kick()
    }

    func zoom(by amount: Double) {
        guard amount.isFinite else { return }
        cameraReset = nil
        let frame = cameraFrame()
        let frontFrame = cameraFrame(for: [bottles[front]].compactMap { $0 })
        let closest = frontFrame.distance / frame.distance
        let furthest = max(closest, 1.2)
        zoomTarget = clamped(zoomTarget * exp(clamped(amount, -0.4, 0.4)), closest, furthest)
        if reduceMotion || !isVisible { zoomScale = zoomTarget }
        kick()
        updateCamera()
        requestRender()
    }

    func resetCamera() {
        yawVelocity = 0; pitchVelocity = 0; dragging = false
        zoomTarget = 1
        if reduceMotion || !isVisible {
            cameraReset = nil
            setDefaultCamera()
        } else { cameraReset = CameraReset(yaw: yaw, pitch: pitch, zoom: zoomScale) }
        for bottle in bottles.values { bottle.simulation.tiltTarget = 0; bottle.simulation.acceleration = 0 }
        kick()
        updateCamera()
        requestRender()
    }

    private var needsMotion: Bool {
        swap != nil || cameraReset != nil || abs(zoomTarget - zoomScale) > 0.002 || abs(yawVelocity) + abs(pitchVelocity) > 0.001 || bottles.values.contains { !$0.simulation.isSettled }
    }

    private var needsShipAnimation: Bool { bottles.values.contains(where: \.hasShipAnimation) }

    private func kick() {
        guard isVisible, !reduceMotion else { settleAll(); stopTimer(); return }
        guard needsMotion || needsShipAnimation else { stopTimer(); return }
        let interval = needsMotion ? 1.0 / 60 : 1.0 / 15
        setMoving(needsMotion)
        guard timer == nil || abs(frameInterval - interval) > 0.0001 else { return }
        timer?.invalidate()
        frameInterval = interval
        lastTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: interval, target: tickTarget, selector: #selector(PaperweightTickTarget.tick(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scene.isPaused = true
    }

    fileprivate func tick() {
        guard isVisible, !reduceMotion else { settleAll(); stopTimer(); return }
        let time = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.15, max(1.0 / 240, time - lastTime))
        let dt = min(0.05, elapsed)
        lastTime = time
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        advanceSwap(dt)
        advanceCamera(dt)
        for bottle in bottles.values {
            let moved = !bottle.simulation.isSettled || swap != nil
            if moved {
                bottle.simulation.step(dt: dt)
                bottle.updateVisuals(dt: dt, moving: true, geometryChanged: true)
            }
            bottle.animateShip(dt: elapsed, reduceMotion: false)
        }
        placeBottles()
        updateCamera()
        SCNTransaction.commit()
        requestRender()
        kick()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        frameInterval = 0
        scene.isPaused = true
        view?.isPlaying = false
        view?.rendersContinuously = false
        setMoving(false)
    }

    private func setMoving(_ value: Bool) {
        guard value != moving else { return }
        moving = value
        // A representable update can start motion, so report its edge after
        // SwiftUI has finished applying the current set of inputs.
        Task { @MainActor [weak self] in self?.onMovingChanged(value) }
    }

    private func settleAll() {
        if cameraReset != nil { setDefaultCamera() }
        else { zoomScale = zoomTarget }
        swap = nil; cameraReset = nil; dragging = false
        yawVelocity = 0; pitchVelocity = 0
        for bottle in bottles.values {
            let changed = !bottle.simulation.isSettled || bottle.simulation.waveHeights.contains { abs($0) > 0.00001 }
                || bottle.simulation.currentLevels != bottle.simulation.targetLevels
            bottle.simulation.settle()
            bottle.updateVisuals(dt: 0, moving: false, geometryChanged: changed)
            bottle.animateShip(dt: 0, reduceMotion: true)
        }
        placeBottles()
        updateCamera()
    }

    private func advanceSwap(_ dt: Double) {
        guard var transition = swap else { return }
        transition.progress = min(1, transition.progress + dt / 0.9)
        let acceleration = sin(2 * .pi * transition.progress)
        bottles[transition.to]?.simulation.acceleration = 0.32 * acceleration
        bottles[transition.from]?.simulation.acceleration = -0.22 * acceleration
        if transition.progress >= 1 {
            bottles[transition.to]?.simulation.acceleration = 0
            bottles[transition.from]?.simulation.acceleration = 0
            swap = nil
        } else { swap = transition }
    }

    private func advanceCamera(_ dt: Double) {
        if var reset = cameraReset {
            reset.progress = min(1, reset.progress + dt / 0.35)
            let amount = eased(reset.progress)
            yaw = lerp(reset.yaw, atan2(-0.6, 8.6), amount)
            pitch = lerp(reset.pitch, atan2(2.5, hypot(0.6, 8.6)), amount)
            zoomScale = lerp(reset.zoom, 1, amount)
            cameraReset = reset.progress < 1 ? reset : nil
        } else {
            if !dragging {
                yaw = clamped(yaw + yawVelocity * dt, -35 * .pi / 180, 35 * .pi / 180)
                pitch = clamped(pitch + pitchVelocity * dt, 8 * .pi / 180, 42 * .pi / 180)
            }
            let damping = pow(0.9, dt * 60)
            yawVelocity *= damping; pitchVelocity *= damping
            if abs(yawVelocity) + abs(pitchVelocity) < 0.001 { yawVelocity = 0; pitchVelocity = 0 }
        }
        // A held mouse is not continuing camera motion. Each new drag event
        // refreshes this impulse; a stopped hand lets both water and clock rest.
        if dragging, swap == nil, let simulation = bottles[front]?.simulation {
            let damping = pow(0.85, dt * 60)
            simulation.tiltTarget *= damping
            simulation.acceleration *= damping
            if abs(simulation.tiltTarget) < 0.0001 { simulation.tiltTarget = 0 }
            if abs(simulation.acceleration) < 0.0001 { simulation.acceleration = 0 }
        }
        if cameraReset == nil {
            zoomScale += (zoomTarget - zoomScale) * min(1, dt * 12)
            if abs(zoomTarget - zoomScale) <= 0.002 { zoomScale = zoomTarget }
        }
    }

    private func placeBottles() {
        let layout = PaperweightSceneFraming.placement(aspect: Double(size.width / max(1, size.height)))
        for (id, bottle) in bottles {
            var amount = id == front ? 1.0 : 0.0
            var lift = 0.0, side = 0.0, deep = 0.0
            if let swap {
                let easedProgress = eased(swap.progress), arc = sin(.pi * easedProgress)
                amount = id == swap.to ? easedProgress : 1 - easedProgress
                if id == swap.to { lift = arc * 0.7; side = -arc * 1.9 }
                else { side = arc * 1.5; deep = -arc * 0.9 }
            }
            bottle.group.position = PaperweightSceneAssets.vector(
                lerp(layout.rear.x, layout.front.x, amount) + side, 1.01 + lift,
                lerp(layout.rear.z, layout.front.z, amount) + deep
            )
            bottle.group.eulerAngles.y = CGFloat(lerp(-0.34, 0.07, amount))
            bottle.caption.opacity = CGFloat(1 - amount)
            bottle.shadow.opacity = CGFloat(max(0, 1 - lift))
            bottle.setOrder(amount > 0.5 ? 20 : 0)
        }
    }

    private func updateCamera() {
        guard size.width > 0, size.height > 0 else { return }
        let frame = cameraFrame()
        let frontFrame = cameraFrame(for: [bottles[front]].compactMap { $0 })
        // Zoom toward the selected object; the default view keeps both visible.
        let focus = clamped((1 - zoomScale) / 0.35, 0, 1)
        let target = frame.target + (frontFrame.target - frame.target) * focus
        let direction = SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let distance = max(zoomScale * frame.distance, minimumCameraDistance(target: target, margin: 1.04))
        let position = target + direction * distance
        camera.position = PaperweightSceneAssets.vector(position.x, position.y, position.z)
        camera.look(at: PaperweightSceneAssets.vector(target.x, target.y, target.z))
    }

    private func framingPoints(for nodes: [PaperweightBottle]) -> [SIMD3<Double>] {
        nodes.flatMap { bottle in
            PaperweightSceneFraming.glassCorners.map { corner in
                let point = bottle.group.convertPosition(PaperweightSceneAssets.vector(corner.x, corner.y, corner.z), to: nil)
                return SIMD3(Double(point.x), Double(point.y), Double(point.z))
            }
        }
    }

    private func cameraFrame(for nodes: [PaperweightBottle]? = nil) -> PaperweightSceneFraming.Frame {
        PaperweightSceneFraming.fit(points: framingPoints(for: nodes ?? Array(bottles.values)),
                                    aspect: Double(size.width / max(1, size.height)), yaw: yaw, pitch: pitch)
    }

    private func minimumCameraDistance(target: SIMD3<Double>, margin: Double) -> Double {
        PaperweightSceneFraming.distance(points: framingPoints(for: [bottles[front]].compactMap { $0 }),
                                        target: target, aspect: Double(size.width / max(1, size.height)),
                                        yaw: yaw, pitch: pitch, margin: margin)
    }

    private func addLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_150
        sun.light?.castsShadow = true
        sun.light?.shadowMode = .deferred
        sun.light?.shadowColor = NSColor.black.withAlphaComponent(0.28)
        sun.light?.shadowRadius = 5
        sun.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
        sun.light?.orthographicScale = 14
        sun.light?.zNear = 1
        sun.light?.zFar = 25
        sun.position = PaperweightSceneAssets.vector(-3.5, 8, 5.5)
        sun.look(at: PaperweightSceneAssets.vector(0, 0, 0))
        scene.rootNode.addChildNode(sun)
    }

    private func setDefaultCamera() {
        yaw = atan2(-0.6, 8.6); pitch = atan2(2.5, hypot(0.6, 8.6))
        zoomScale = 1
        zoomTarget = zoomScale
    }
    private func requestRender() { view?.needsDisplay = true }
    private func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(upper, max(lower, value)) }
    private func lerp(_ a: Double, _ b: Double, _ amount: Double) -> Double { a + (b - a) * amount }
    private func eased(_ value: Double) -> Double { value < 0.5 ? 4 * value * value * value : 1 - pow(-2 * value + 2, 3) / 2 }
}

@available(macOS 14.0, *)
@MainActor
private final class PaperweightTickTarget: NSObject {
    weak var owner: PaperweightSceneRenderer?
    init(owner: PaperweightSceneRenderer) { self.owner = owner }
    @objc func tick(_ timer: Timer) {
        guard let owner else { timer.invalidate(); return }
        owner.tick()
    }
}

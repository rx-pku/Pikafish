import AppKit
import Foundation

private let enginePath: String = {
    if let bundledEngine = Bundle.main.path(forResource: "pikafish-fastwin", ofType: nil) {
        return bundledEngine
    }
    if let override = ProcessInfo.processInfo.environment["PIKAFISH_ENGINE"], !override.isEmpty {
        return override
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("src/pikafish")
        .path
}()
private let engineDirectory = URL(fileURLWithPath: enginePath).deletingLastPathComponent().path
private let networkPath = Bundle.main.path(forResource: "pikafish", ofType: "nnue")
    ?? URL(fileURLWithPath: engineDirectory).appendingPathComponent("pikafish.nnue").path

struct EngineAnalysisLine {
    let rank: Int
    let depth: Int
    let nodes: Int
    let score: String
    let redScore: Double?
    let redMate: Int?
    let redWin: Double?
    let draw: Double?
    let blackWin: Double?
    let pv: [String]
}

final class PikafishEngine {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let threadCount: Int
    private let hashSize: Int
    private let multiPV: Int
    private var buffer = ""
    private var isReady = false
    private var analysisSideIsRed = true
    private var currentBestMoveMates = false

    var onReady: (() -> Void)?
    var onBestMove: ((String, Bool) -> Void)?
    var onNoLegalMove: (() -> Void)?
    var onInfo: ((String) -> Void)?
    var onAnalysisLine: ((EngineAnalysisLine) -> Void)?
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    init(threads: Int = 4, hash: Int = 256, multiPV: Int = 1) {
        threadCount = threads
        hashSize = hash
        self.multiPV = multiPV
    }

    func start() {
        guard FileManager.default.isExecutableFile(atPath: enginePath) else {
            onError?("找不到 Pikafish 引擎")
            return
        }

        process.executableURL = URL(fileURLWithPath: enginePath)
        process.currentDirectoryURL = URL(fileURLWithPath: engineDirectory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onError?("Pikafish 引擎已停止") }
        }

        do {
            try process.run()
            send("uci")
        } catch {
            onError?("无法启动 Pikafish：\(error.localizedDescription)")
        }
    }

    private func consume(_ text: String) {
        buffer += text
        let lines = buffer.components(separatedBy: .newlines)
        buffer = lines.last ?? ""
        for raw in lines.dropLast() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            onLog?("‹ " + line)
            if line == "uciok" {
                send("setoption name Threads value \(threadCount)")
                send("setoption name Hash value \(hashSize)")
                if multiPV > 1 { send("setoption name MultiPV value \(multiPV)") }
                send("setoption name EvalFile value \(networkPath)")
                send("setoption name UCI_ShowWDL value true")
                send("isready")
            } else if line == "readyok" {
                isReady = true
                onReady?()
            } else if line.hasPrefix("bestmove ") {
                let move = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if !move.isEmpty && move != "(none)" {
                    onBestMove?(move, currentBestMoveMates)
                } else {
                    onNoLegalMove?()
                }
            } else if line.hasPrefix("info depth ") && line.contains(" score ") && line.contains(" nodes ") {
                onInfo?(summarize(line))
                if let analysis = parseAnalysisLine(line) { onAnalysisLine?(analysis) }
            } else if line.contains("ERROR") {
                onError?(line)
            }
        }
    }

    private func summarize(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        func value(after key: String) -> String? {
            guard let index = parts.firstIndex(of: key), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }
        let depth = value(after: "depth") ?? "?"
        let nodes = value(after: "nodes") ?? "?"
        var score = ""
        if let scoreIndex = parts.firstIndex(of: "score"), scoreIndex + 2 < parts.count {
            let kind = parts[scoreIndex + 1]
            let raw = parts[scoreIndex + 2]
            currentBestMoveMates = kind == "mate" && Int(raw) == 1
            let perspective = analysisSideIsRed ? "红方" : "黑方"
            score = kind == "cp" ? "，\(perspective)评分 \(raw)" : "，\(perspective)杀棋 \(raw)"
        }
        var probability = ""
        if let wdlIndex = parts.firstIndex(of: "wdl"), wdlIndex + 3 < parts.count,
           let win = Double(parts[wdlIndex + 1]),
           let draw = Double(parts[wdlIndex + 2]),
           let loss = Double(parts[wdlIndex + 3]) {
            let redWin = analysisSideIsRed ? win : loss
            let blackWin = analysisSideIsRed ? loss : win
            probability = String(format: "\n红胜 %.1f%% · 和棋 %.1f%% · 黑胜 %.1f%%", redWin / 10, draw / 10, blackWin / 10)
        }
        return "深度 \(depth)\(score)\n节点 \(nodes)\(probability)"
    }

    private func parseAnalysisLine(_ line: String) -> EngineAnalysisLine? {
        let parts = line.split(separator: " ").map(String.init)
        func value(after key: String) -> String? {
            guard let index = parts.firstIndex(of: key), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }
        guard let pvIndex = parts.firstIndex(of: "pv"), pvIndex + 1 < parts.count else { return nil }
        let rank = Int(value(after: "multipv") ?? "1") ?? 1
        let depth = Int(value(after: "depth") ?? "0") ?? 0
        let nodes = Int(value(after: "nodes") ?? "0") ?? 0
        var score = ""
        var redScore: Double?
        var redMate: Int?
        if let index = parts.firstIndex(of: "score"), index + 2 < parts.count {
            let kind = parts[index + 1]
            let raw = Int(parts[index + 2]) ?? 0
            let side = analysisSideIsRed ? "红方" : "黑方"
            score = kind == "cp"
                ? String(format: "%@ %+.2f", side, Double(raw) / 100.0)
                : "\(side)杀棋 \(raw)"
            if kind == "cp" {
                let sideScore = Double(raw) / 100.0
                redScore = analysisSideIsRed ? sideScore : -sideScore
            } else if kind == "mate" {
                redMate = analysisSideIsRed ? raw : -raw
            }
        }
        var redWin: Double?, draw: Double?, blackWin: Double?
        if let index = parts.firstIndex(of: "wdl"), index + 3 < parts.count,
           let win = Double(parts[index + 1]),
           let drawValue = Double(parts[index + 2]),
           let loss = Double(parts[index + 3]) {
            redWin = (analysisSideIsRed ? win : loss) / 10.0
            draw = drawValue / 10.0
            blackWin = (analysisSideIsRed ? loss : win) / 10.0
        }
        return EngineAnalysisLine(
            rank: rank,
            depth: depth,
            nodes: nodes,
            score: score,
            redScore: redScore,
            redMate: redMate,
            redWin: redWin,
            draw: draw,
            blackWin: blackWin,
            pv: Array(parts[(pvIndex + 1)...])
        )
    }

    func newGame() {
        guard isReady else { return }
        send("stop")
        send("ucinewgame")
        send("isready")
    }

    func configureFastWin(red: Bool, black: Bool) {
        guard isReady else { return }
        send("setoption name Red Fast Win value \(red ? "true" : "false")")
        send("setoption name Black Fast Win value \(black ? "true" : "false")")
    }

    func search(baseFEN: String? = nil, moves: [String], milliseconds: Int, sideToMoveIsRed: Bool) {
        guard isReady else {
            onError?("引擎还在初始化")
            return
        }
        let suffix = moves.isEmpty ? "" : " moves " + moves.joined(separator: " ")
        let position = baseFEN.map { "fen \($0)" } ?? "startpos"
        analysisSideIsRed = sideToMoveIsRed
        currentBestMoveMates = false
        send("position \(position)\(suffix)")
        send("go movetime \(milliseconds)")
    }

    func analyzeInfinite(baseFEN: String? = nil, moves: [String], sideToMoveIsRed: Bool) {
        guard isReady else {
            onError?("引擎还在初始化")
            return
        }
        let suffix = moves.isEmpty ? "" : " moves " + moves.joined(separator: " ")
        let position = baseFEN.map { "fen \($0)" } ?? "startpos"
        analysisSideIsRed = sideToMoveIsRed
        currentBestMoveMates = false
        send("position \(position)\(suffix)")
        send("go infinite")
    }

    func stopSearch() {
        guard isReady else { return }
        send("stop")
    }

    func stop() {
        guard process.isRunning else { return }
        send("stop")
        send("quit")
        output.fileHandleForReading.readabilityHandler = nil
    }

    private func send(_ command: String) {
        onLog?("› " + command)
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }
}

private enum LayoutTool {
    case move
    case erase
    case place(Character)
}

final class BoardView: NSView {
    static let standardPlacement = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR"
    private(set) var board = Array(repeating: Array(repeating: Character(" "), count: 9), count: 10)
    private var selected: (x: Int, y: Int)?
    private var lastMove: String?
    private var predictionMove: String?
    var acceptingMoves = false
    private var movableSideIsRed = true
    private var flippedForBlack = false
    private var layoutMode = false
    private var layoutTool: LayoutTool = .move
    private var liftProgress: CGFloat = 0
    private var liftAnimationTimer: Timer?
    private var isReturningPiece = false
    private lazy var cherryWoodTexture: NSImage? = Bundle.main.url(forResource: "CherryWoodTexture-v2", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    private lazy var whiteJadeTexture: NSImage? = Bundle.main.url(forResource: "WhiteJadePhoto", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }
    private lazy var greenJadeTexture: NSImage? = Bundle.main.url(forResource: "GreenJadePhoto", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    private lazy var whiteJadeInternalTexture: NSImage? = Bundle.main.url(forResource: "WhiteJadeInternal-v2", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    private lazy var greenJadeInternalTexture: NSImage? = Bundle.main.url(forResource: "GreenJadeInternal-v2", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var onMove: ((String) -> Void)?
    var onPiecePickedUp: (() -> Void)?
    var onPieceReturned: (() -> Void)?
    var onLayoutPiecePlaced: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        reset()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        loadPlacement(Self.standardPlacement)
    }

    private func loadPlacement(_ placement: String) {
        liftAnimationTimer?.invalidate()
        liftAnimationTimer = nil
        liftProgress = 0
        isReturningPiece = false
        board = Array(repeating: Array(repeating: Character(" "), count: 9), count: 10)
        for (y, rank) in placement.split(separator: "/").enumerated() where y < 10 {
            var x = 0
            for char in rank {
                if let empty = char.wholeNumberValue {
                    x += empty
                } else {
                    if x < 9 { board[y][x] = char }
                    x += 1
                }
            }
        }
        selected = nil
        lastMove = nil
        needsDisplay = true
    }

    func positionSnapshot() -> [[Character]] { board }

    func setPosition(_ position: [[Character]]) {
        guard position.count == 10, position.allSatisfy({ $0.count == 9 }) else { return }
        liftAnimationTimer?.invalidate()
        liftAnimationTimer = nil
        liftProgress = 0
        isReturningPiece = false
        board = position
        selected = nil
        lastMove = nil
        needsDisplay = true
    }

    func beginLayout() {
        layoutMode = true
        layoutTool = .move
        acceptingMoves = false
        selected = nil
        lastMove = nil
        needsDisplay = true
    }

    func endLayout() {
        layoutMode = false
        selected = nil
        needsDisplay = true
    }

    fileprivate func setLayoutTool(_ tool: LayoutTool) {
        layoutTool = tool
        liftAnimationTimer?.invalidate()
        liftProgress = 0
        isReturningPiece = false
        selected = nil
        needsDisplay = true
    }

    func clearPosition() {
        setPosition(Array(repeating: Array(repeating: Character(" "), count: 9), count: 10))
    }

    func useStandardPosition() { reset() }

    func configure(viewedFromRed: Bool) {
        flippedForBlack = !viewedFromRed
        selected = nil
        needsDisplay = true
    }

    func setMovableSide(isRed: Bool) {
        movableSideIsRed = isRed
        selected = nil
        needsDisplay = true
    }

    func toggleRotation() {
        flippedForBlack.toggle()
        selected = nil
        needsDisplay = true
    }

    func setPredictionMove(_ move: String?) {
        predictionMove = move
        needsDisplay = true
    }

    func apply(_ move: String) {
        guard move.count >= 4 else { return }
        let chars = Array(move)
        guard let x1 = chars[0].asciiValue.map({ Int($0 - Character("a").asciiValue!) }),
              let r1 = chars[1].wholeNumberValue,
              let x2 = chars[2].asciiValue.map({ Int($0 - Character("a").asciiValue!) }),
              let r2 = chars[3].wholeNumberValue else { return }
        let y1 = 9 - r1, y2 = 9 - r2
        guard (0..<9).contains(x1), (0..<9).contains(x2), (0..<10).contains(y1), (0..<10).contains(y2) else { return }
        board[y2][x2] = board[y1][x1]
        board[y1][x1] = " "
        lastMove = move
        selected = nil
        needsDisplay = true
    }

    func rebuild(from initialPosition: [[Character]], moves: [String]) {
        setPosition(initialPosition)
        for move in moves { apply(move) }
        selected = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let ctx = NSGraphicsContext.current!.cgContext
        let geometry = boardGeometry()
        let x0 = geometry.origin.x, y0 = geometry.origin.y, cell = geometry.cell

        drawBoardWoodSurface(ctx: ctx)

        ctx.setStrokeColor(NSColor(calibratedRed: 0.075, green: 0.042, blue: 0.026, alpha: 0.94).cgColor)
        ctx.setLineWidth(1.45)
        for rank in 0..<10 {
            let y = y0 + CGFloat(rank) * cell
            ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x0 + 8 * cell, y: y))
        }
        for file in 0..<9 {
            let x = x0 + CGFloat(file) * cell
            if file == 0 || file == 8 {
                ctx.move(to: CGPoint(x: x, y: y0)); ctx.addLine(to: CGPoint(x: x, y: y0 + 9 * cell))
            } else {
                ctx.move(to: CGPoint(x: x, y: y0)); ctx.addLine(to: CGPoint(x: x, y: y0 + 4 * cell))
                ctx.move(to: CGPoint(x: x, y: y0 + 5 * cell)); ctx.addLine(to: CGPoint(x: x, y: y0 + 9 * cell))
            }
        }
        drawPalace(ctx: ctx, x0: x0, y0: y0, cell: cell, bottomRank: 0)
        drawPalace(ctx: ctx, x0: x0, y0: y0, cell: cell, bottomRank: 7)
        ctx.strokePath()

        drawPiecePositionMarkers(ctx: ctx, x0: x0, y0: y0, cell: cell)

        drawCoordinates(x0: x0, y0: y0, cell: cell)

        let riverStyle = NSMutableParagraphStyle(); riverStyle.alignment = .center
        let riverFont = NSFont(name: "STKaiti", size: cell * 0.44) ?? NSFont.systemFont(ofSize: cell * 0.44, weight: .semibold)
        let riverShadow = NSShadow()
        riverShadow.shadowOffset = CGSize(width: 0.9, height: -1.1)
        riverShadow.shadowBlurRadius = 1.8
        riverShadow.shadowColor = NSColor.black.withAlphaComponent(0.62)
        let riverAttrs: [NSAttributedString.Key: Any] = [
            .font: riverFont,
            .foregroundColor: NSColor(calibratedRed: 0.94, green: 0.70, blue: 0.31, alpha: 0.98),
            .strokeColor: NSColor(calibratedRed: 0.30, green: 0.145, blue: 0.055, alpha: 0.92),
            .strokeWidth: -1.20,
            .shadow: riverShadow,
            .paragraphStyle: riverStyle
        ]
        let riverHighlightAttrs: [NSAttributedString.Key: Any] = [
            .font: riverFont,
            .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.56, alpha: 0.54),
            .paragraphStyle: riverStyle
        ]
        let leftRiverRect = NSRect(x: x0 + cell * 0.5, y: y0 + cell * 4.22, width: cell * 2.4, height: cell * 0.62)
        let rightRiverRect = NSRect(x: x0 + cell * 5.1, y: y0 + cell * 4.22, width: cell * 2.4, height: cell * 0.62)
        for (text, rect) in [("楚 河", leftRiverRect), ("漢 界", rightRiverRect)] {
            (text as NSString).draw(in: rect.offsetBy(dx: -0.35, dy: 0.48), withAttributes: riverHighlightAttrs)
            (text as NSString).draw(in: rect, withAttributes: riverAttrs)
        }

        drawLastMoveHighlight(ctx: ctx, x0: x0, y0: y0, cell: cell, foreground: false)

        for y in 0..<10 {
            for x in 0..<9 where board[y][x] != " " {
                drawPiece(board[y][x], x: x, y: y, x0: x0, y0: y0, cell: cell)
            }
        }
        drawPredictionArrow(ctx: ctx, x0: x0, y0: y0, cell: cell)
        drawLastMoveHighlight(ctx: ctx, x0: x0, y0: y0, cell: cell, foreground: true)
    }

    private func drawBoardWoodSurface(ctx: CGContext) {
        let outerRect = bounds.insetBy(dx: 12, dy: 12)
        let innerRect = outerRect.insetBy(dx: 20, dy: 20)
        let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 17, cornerHeight: 17, transform: nil)
        let innerPath = CGPath(roundedRect: innerRect, cornerWidth: 8, cornerHeight: 8, transform: nil)

        // Low-gloss ebony surround: near-black brown, with very fine longitudinal grain.
        ctx.saveGState()
        ctx.addPath(outerPath)
        ctx.clip()
        let ebonyColors = [
            NSColor(calibratedRed: 0.055, green: 0.038, blue: 0.031, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.145, green: 0.086, blue: 0.061, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.074, green: 0.047, blue: 0.038, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.105, green: 0.060, blue: 0.044, alpha: 1).cgColor
        ] as CFArray
        if let ebony = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: ebonyColors, locations: [0, 0.34, 0.71, 1]) {
            ctx.drawLinearGradient(ebony, start: CGPoint(x: outerRect.minX, y: outerRect.maxY), end: CGPoint(x: outerRect.maxX, y: outerRect.minY), options: [])
        }
        ctx.setLineCap(.round)
        for line in 0..<34 {
            let ratio = (CGFloat(line) + 0.5) / 34
            let baseY = outerRect.minY + ratio * outerRect.height
            let grain = CGMutablePath()
            for step in 0...72 {
                let t = CGFloat(step) / 72
                let x = outerRect.minX + t * outerRect.width
                let y = baseY + CGFloat(sin(Double(t * 25 + CGFloat(line) * 1.19))) * 0.65
                if step == 0 { grain.move(to: CGPoint(x: x, y: y)) }
                else { grain.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.setStrokeColor(NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.13, alpha: line % 5 == 0 ? 0.12 : 0.055).cgColor)
            ctx.setLineWidth(line % 5 == 0 ? 0.9 : 0.48)
            ctx.addPath(grain)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Recessed cherrywood playing field, matching the warm red-brown center of the reference set.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.setFillColor(NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.11, alpha: 1).cgColor)
        ctx.addPath(innerPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(innerPath)
        ctx.clip()
        if let wood = cherryWoodTexture {
            // Aspect-fill a central portrait crop so horizontal fibers keep their natural proportions.
            let imageSize = wood.size
            let targetAspect = innerRect.width / innerRect.height
            let sourceWidth = min(imageSize.width, imageSize.height * targetAspect)
            let sourceRect = NSRect(
                x: (imageSize.width - sourceWidth) * 0.5,
                y: 0,
                width: sourceWidth,
                height: imageSize.height
            )
            wood.draw(
                in: innerRect,
                from: sourceRect,
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )

            // A restrained warm glaze unifies the photographic grain with the ebony surround.
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(NSColor(calibratedRed: 0.43, green: 0.20, blue: 0.105, alpha: 0.10).cgColor)
            ctx.fill(innerRect)
            ctx.setBlendMode(.normal)
        } else {
            let cherryColors = [
                NSColor(calibratedRed: 0.69, green: 0.34, blue: 0.18, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.79, green: 0.43, blue: 0.23, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.64, green: 0.29, blue: 0.15, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.74, green: 0.37, blue: 0.19, alpha: 1).cgColor
            ] as CFArray
            if let cherry = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cherryColors, locations: [0, 0.32, 0.68, 1]) {
                ctx.drawLinearGradient(cherry, start: CGPoint(x: innerRect.minX, y: innerRect.maxY), end: CGPoint(x: innerRect.maxX, y: innerRect.minY), options: [])
            }
        }

        let sheenColors = [NSColor.white.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheenColors, locations: [0, 0.48, 1]) {
            ctx.drawLinearGradient(sheen, start: CGPoint(x: innerRect.midX, y: innerRect.maxY), end: CGPoint(x: innerRect.midX, y: innerRect.minY), options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(outerPath)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.027, green: 0.020, blue: 0.018, alpha: 0.96).cgColor)
        ctx.setLineWidth(3.2)
        ctx.strokePath()
        ctx.addPath(innerPath)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.035, green: 0.024, blue: 0.021, alpha: 0.88).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: innerRect.insetBy(dx: 2.5, dy: 2.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawLastMoveHighlight(ctx: CGContext, x0: CGFloat, y0: CGFloat, cell: CGFloat, foreground: Bool) {
        guard let move = lastMove, let squares = moveSquares(move) else { return }
        let from = displayPoint(x: squares.from.x, y: squares.from.y, x0: x0, y0: y0, cell: cell)
        let to = displayPoint(x: squares.to.x, y: squares.to.y, x0: x0, y0: y0, cell: cell)

        if !foreground {
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setShadow(offset: .zero, blur: cell * 0.13, color: NSColor.white.withAlphaComponent(0.82).cgColor)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(cell * 0.14)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()

            ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            ctx.fillEllipse(in: CGRect(x: from.x - cell * 0.38, y: from.y - cell * 0.38, width: cell * 0.76, height: cell * 0.76))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
            ctx.fillEllipse(in: CGRect(x: to.x - cell * 0.47, y: to.y - cell * 0.47, width: cell * 0.94, height: cell * 0.94))
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: cell * 0.10, color: NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.66).cgColor)
            ctx.setLineWidth(2.4)
            ctx.strokeEllipse(in: CGRect(x: from.x - cell * 0.17, y: from.y - cell * 0.17, width: cell * 0.34, height: cell * 0.34))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.78).cgColor)
            ctx.setLineWidth(2.8)
            ctx.strokeEllipse(in: CGRect(x: to.x - cell * 0.45, y: to.y - cell * 0.45, width: cell * 0.90, height: cell * 0.90))

            // A restrained four-point glint marks the destination without covering the piece face.
            let glint = CGPoint(x: to.x + cell * 0.33, y: to.y + cell * 0.33)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: glint.x - cell * 0.09, y: glint.y))
            ctx.addLine(to: CGPoint(x: glint.x + cell * 0.09, y: glint.y))
            ctx.move(to: CGPoint(x: glint.x, y: glint.y - cell * 0.09))
            ctx.addLine(to: CGPoint(x: glint.x, y: glint.y + cell * 0.09))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawPredictionArrow(ctx: CGContext, x0: CGFloat, y0: CGFloat, cell: CGFloat) {
        guard let move = predictionMove, let squares = moveSquares(move) else { return }
        let rawFrom = displayPoint(x: squares.from.x, y: squares.from.y, x0: x0, y0: y0, cell: cell)
        let rawTo = displayPoint(x: squares.to.x, y: squares.to.y, x0: x0, y0: y0, cell: cell)
        let dx = rawTo.x - rawFrom.x, dy = rawTo.y - rawFrom.y
        let distance = max(1, hypot(dx, dy))
        let ux = dx / distance, uy = dy / distance
        let from = CGPoint(x: rawFrom.x + ux * cell * 0.27, y: rawFrom.y + uy * cell * 0.27)
        let to = CGPoint(x: rawTo.x - ux * cell * 0.31, y: rawTo.y - uy * cell * 0.31)
        let normal = CGPoint(x: -uy, y: ux)
        let headLength = cell * 0.28
        let headWidth = cell * 0.20
        let headBase = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        let head = CGMutablePath()
        head.move(to: to)
        head.addLine(to: CGPoint(x: headBase.x + normal.x * headWidth, y: headBase.y + normal.y * headWidth))
        head.addLine(to: CGPoint(x: headBase.x - normal.x * headWidth, y: headBase.y - normal.y * headWidth))
        head.closeSubpath()

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: cell * 0.10, color: NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        ctx.setLineWidth(cell * 0.145)
        ctx.move(to: from); ctx.addLine(to: headBase); ctx.strokePath()
        ctx.addPath(head); ctx.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor); ctx.fillPath()

        let mint = NSColor(calibratedRed: 0.17, green: 1.0, blue: 0.57, alpha: 0.92)
        ctx.setShadow(offset: .zero, blur: cell * 0.075, color: mint.withAlphaComponent(0.78).cgColor)
        ctx.setStrokeColor(mint.cgColor)
        ctx.setLineWidth(cell * 0.085)
        ctx.move(to: from); ctx.addLine(to: headBase); ctx.strokePath()
        ctx.addPath(head); ctx.setFillColor(mint.cgColor); ctx.fillPath()

        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(max(1.0, cell * 0.018))
        ctx.move(to: from); ctx.addLine(to: headBase); ctx.strokePath()
        ctx.setStrokeColor(mint.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(max(2.0, cell * 0.045))
        ctx.strokeEllipse(in: CGRect(x: rawFrom.x - cell * 0.38, y: rawFrom.y - cell * 0.38, width: cell * 0.76, height: cell * 0.76))
        ctx.strokeEllipse(in: CGRect(x: rawTo.x - cell * 0.44, y: rawTo.y - cell * 0.44, width: cell * 0.88, height: cell * 0.88))
        ctx.restoreGState()
    }

    private func moveSquares(_ move: String) -> (from: (x: Int, y: Int), to: (x: Int, y: Int))? {
        guard move.count >= 4 else { return nil }
        let chars = Array(move)
        guard let a = Character("a").asciiValue,
              let f1 = chars[0].asciiValue, let r1 = chars[1].wholeNumberValue,
              let f2 = chars[2].asciiValue, let r2 = chars[3].wholeNumberValue else { return nil }
        return ((Int(f1 - a), 9 - r1), (Int(f2 - a), 9 - r2))
    }

    private func displayPoint(x: Int, y: Int, x0: CGFloat, y0: CGFloat, cell: CGFloat) -> CGPoint {
        let displayX = flippedForBlack ? 8 - x : x
        let displayRank = flippedForBlack ? y : 9 - y
        return CGPoint(x: x0 + CGFloat(displayX) * cell, y: y0 + CGFloat(displayRank) * cell)
    }

    private func drawPalace(ctx: CGContext, x0: CGFloat, y0: CGFloat, cell: CGFloat, bottomRank: Int) {
        let yA = y0 + CGFloat(bottomRank) * cell
        let yB = yA + 2 * cell
        ctx.move(to: CGPoint(x: x0 + 3 * cell, y: yA)); ctx.addLine(to: CGPoint(x: x0 + 5 * cell, y: yB))
        ctx.move(to: CGPoint(x: x0 + 5 * cell, y: yA)); ctx.addLine(to: CGPoint(x: x0 + 3 * cell, y: yB))
    }

    private func drawPiecePositionMarkers(ctx: CGContext, x0: CGFloat, y0: CGFloat, cell: CGFloat) {
        let cannonPositions = [(1, 2), (7, 2), (1, 7), (7, 7)]
        let soldierPositions = [0, 2, 4, 6, 8].flatMap { file in [(file, 3), (file, 6)] }
        let positions = cannonPositions + soldierPositions
        let inner = cell * 0.10
        let outer = cell * 0.30
        let markerPath = CGMutablePath()

        for (file, rank) in positions {
            let center = CGPoint(x: x0 + CGFloat(file) * cell, y: y0 + CGFloat(rank) * cell)
            let horizontalSides: [CGFloat]
            if file == 0 { horizontalSides = [1] }
            else if file == 8 { horizontalSides = [-1] }
            else { horizontalSides = [-1, 1] }

            for horizontal in horizontalSides {
                for vertical: CGFloat in [-1, 1] {
                    let corner = CGMutablePath()
                    corner.move(to: CGPoint(x: center.x + horizontal * outer, y: center.y + vertical * inner))
                    corner.addLine(to: CGPoint(x: center.x + horizontal * inner, y: center.y + vertical * inner))
                    corner.addLine(to: CGPoint(x: center.x + horizontal * inner, y: center.y + vertical * outer))
                    markerPath.addPath(corner)
                }
            }
        }

        ctx.saveGState()
        ctx.setLineCap(.square)
        ctx.setLineJoin(.miter)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.30, green: 0.145, blue: 0.055, alpha: 0.88).cgColor)
        ctx.setLineWidth(max(2.5, cell * 0.052))
        ctx.addPath(markerPath)
        ctx.strokePath()

        ctx.setShadow(offset: CGSize(width: 0.7, height: -0.9), blur: 1.5, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.94, green: 0.70, blue: 0.31, alpha: 0.98).cgColor)
        ctx.setLineWidth(max(1.55, cell * 0.032))
        ctx.addPath(markerPath)
        ctx.strokePath()

        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.translateBy(x: -0.15, y: 0.35)
        ctx.setStrokeColor(NSColor(calibratedRed: 1.0, green: 0.89, blue: 0.58, alpha: 0.58).cgColor)
        ctx.setLineWidth(max(0.55, cell * 0.010))
        ctx.addPath(markerPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawCoordinates(x0: CGFloat, y0: CGFloat, cell: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let coordinateFontSize = max(15, cell * 0.25)
        let foilShadow = NSShadow()
        foilShadow.shadowOffset = CGSize(width: 0.7, height: -1.0)
        foilShadow.shadowBlurRadius = 1.6
        foilShadow.shadowColor = NSColor.black.withAlphaComponent(0.58)
        let foilGold = NSColor(calibratedRed: 0.94, green: 0.70, blue: 0.31, alpha: 0.98)
        let foilEdge = NSColor(calibratedRed: 0.30, green: 0.145, blue: 0.055, alpha: 0.90)
        let westernAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: coordinateFontSize, weight: .bold),
            .foregroundColor: foilGold,
            .strokeColor: foilEdge,
            .strokeWidth: -1.15,
            .shadow: foilShadow,
            .paragraphStyle: style
        ]
        let chineseAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "PingFang SC Semibold", size: coordinateFontSize) ?? NSFont.systemFont(ofSize: coordinateFontSize, weight: .semibold),
            .foregroundColor: foilGold,
            .strokeColor: foilEdge,
            .strokeWidth: -1.15,
            .shadow: foilShadow,
            .paragraphStyle: style
        ]
        let chineseFiles = ["九", "八", "七", "六", "五", "四", "三", "二", "一"]
        let chineseRanks = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

        for displayFile in 0..<9 {
            let logicalFile = flippedForBlack ? 8 - displayFile : displayFile
            let westernLabel = String(Character(UnicodeScalar(65 + logicalFile)!))
            let chineseLabel = chineseFiles[displayFile]
            let centerX = x0 + CGFloat(displayFile) * cell
            (chineseLabel as NSString).draw(in: NSRect(x: centerX - 16, y: y0 - 54, width: 32, height: 24), withAttributes: chineseAttrs)
            (westernLabel as NSString).draw(in: NSRect(x: centerX - 16, y: y0 + 9 * cell + 30, width: 32, height: 24), withAttributes: westernAttrs)
        }

        for displayRank in 0..<10 {
            let logicalRank = flippedForBlack ? 9 - displayRank : displayRank
            let westernLabel = String(logicalRank)
            let chineseLabel = chineseRanks[logicalRank]
            let centerY = y0 + CGFloat(displayRank) * cell
            (westernLabel as NSString).draw(in: NSRect(x: x0 - 55, y: centerY - 11, width: 26, height: 24), withAttributes: westernAttrs)
            (chineseLabel as NSString).draw(in: NSRect(x: x0 + 8 * cell + 30, y: centerY - 11, width: 26, height: 24), withAttributes: chineseAttrs)
        }
    }

    private func drawPiece(_ piece: Character, x: Int, y: Int, x0: CGFloat, y0: CGFloat, cell: CGFloat) {
        let displayX = flippedForBlack ? 8 - x : x
        let displayRank = flippedForBlack ? y : 9 - y
        let baseCenter = CGPoint(x: x0 + CGFloat(displayX) * cell, y: y0 + CGFloat(displayRank) * cell)
        let isSelectedPiece = selected?.x == x && selected?.y == y
        let lift = isSelectedPiece ? liftProgress : 0
        let center = CGPoint(x: baseCenter.x, y: baseCenter.y + cell * 0.085 * lift)
        let radius = cell * (0.40 + 0.025 * lift)
        let red = piece.isUppercase
        let pieceRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let ctx = NSGraphicsContext.current!.cgContext

        // A real cast shadow is offset from the piece instead of being painted as an outer ring.
        // It lengthens slightly while a piece is lifted and remains visible under every resting piece.
        let castShadow = pieceRect
            .insetBy(dx: cell * 0.055, dy: cell * 0.080)
            .offsetBy(dx: cell * 0.070 + lift * cell * 0.020,
                      dy: -cell * 0.090 - lift * cell * 0.045)
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: cell * (0.085 + 0.025 * lift),
            color: NSColor.black.withAlphaComponent(0.46 + 0.08 * lift).cgColor
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.20 + 0.04 * lift).cgColor)
        ctx.fillEllipse(in: castShadow)
        ctx.restoreGState()

        if lift > 0.01 {
            let contactShadow = CGRect(
                x: baseCenter.x - cell * 0.31,
                y: baseCenter.y - cell * 0.15,
                width: cell * 0.62,
                height: cell * 0.30
            )
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.13 * lift).cgColor)
            ctx.fillEllipse(in: contactShadow)
        }

        // Polished white nephrite and green jadeite use translucent radial color transitions.
        ctx.saveGState()
        ctx.addEllipse(in: pieceRect)
        ctx.clip()
        let jadeColors: CFArray = red
            ? [
                NSColor(calibratedRed: 1.00, green: 0.985, blue: 0.925, alpha: 0.44).cgColor,
                NSColor(calibratedRed: 0.89, green: 0.90, blue: 0.82, alpha: 0.39).cgColor,
                NSColor(calibratedRed: 0.58, green: 0.64, blue: 0.55, alpha: 0.34).cgColor
              ] as CFArray
            : [
                NSColor(calibratedRed: 0.44, green: 0.73, blue: 0.25, alpha: 0.56).cgColor,
                NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.14, alpha: 0.50).cgColor,
                NSColor(calibratedRed: 0.020, green: 0.090, blue: 0.032, alpha: 0.44).cgColor
              ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: jadeColors, locations: [0, 0.57, 1]) {
            let highlight = CGPoint(x: center.x - radius * 0.30, y: center.y + radius * 0.34)
            ctx.drawRadialGradient(gradient, startCenter: highlight, startRadius: 1, endCenter: center, endRadius: radius * 1.22, options: [.drawsAfterEndLocation])
        }

        // Each piece samples a different magnified patch of mineral structure. The irregular
        // clouds, fibrous veins, colour roots and floating inclusions stay beneath the engraving.
        if let texture = red ? (whiteJadeInternalTexture ?? whiteJadeTexture) : (greenJadeInternalTexture ?? greenJadeTexture) {
            let imageSize = texture.size
            let sampleScale: CGFloat = red ? 0.34 : 0.31
            let sampleSize = min(imageSize.width, imageSize.height) * sampleScale
            let minX = imageSize.width * 0.035
            let maxX = max(minX, imageSize.width * 0.965 - sampleSize)
            let minY = imageSize.height * 0.035
            let maxY = max(minY, imageSize.height * 0.965 - sampleSize)
            let seedX = CGFloat((x * 47 + y * 29 + (red ? 11 : 53)) % 101) / 100
            let seedY = CGFloat((x * 31 + y * 43 + (red ? 37 : 17)) % 101) / 100
            let sourceRect = NSRect(
                x: minX + (maxX - minX) * seedX,
                y: minY + (maxY - minY) * seedY,
                width: sampleSize,
                height: sampleSize
            )
            texture.draw(
                in: pieceRect,
                from: sourceRect,
                operation: .sourceOver,
                fraction: red ? 0.76 : 0.80,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )

            // A restrained colour grade unifies the patches without flattening their inclusions.
            ctx.setBlendMode(red ? .screen : .multiply)
            ctx.setFillColor((red
                ? NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.86, alpha: 0.12)
                : NSColor(calibratedRed: 0.035, green: 0.16, blue: 0.052, alpha: 0.06)).cgColor)
            ctx.fill(pieceRect)
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()

        // The face now ends directly at the jade edge; no independent wrapping ring is drawn.
        let sideColor = red
            ? NSColor(calibratedRed: 0.64, green: 0.035, blue: 0.025, alpha: 1)
            : NSColor(calibratedRed: 0.81, green: 0.61, blue: 0.30, alpha: 1)

        // Small waxy highlights replace the broad plastic-like glare used previously.
        ctx.saveGState()
        ctx.addEllipse(in: pieceRect.insetBy(dx: 2.5, dy: 2.5))
        ctx.clip()
        let reflectionColors = [
            NSColor.white.withAlphaComponent(red ? 0.22 : 0.16).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ] as CFArray
        if let reflection = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: reflectionColors, locations: [0, 1]) {
            let reflectionCenter = CGPoint(x: center.x - radius * 0.40, y: center.y + radius * 0.43)
            ctx.drawRadialGradient(reflection, startCenter: reflectionCenter, startRadius: 0, endCenter: reflectionCenter, endRadius: radius * 0.58, options: [.drawsAfterEndLocation])
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(red ? 0.28 : 0.20).cgColor)
        ctx.setLineWidth(max(0.9, cell * 0.017))
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius * 0.72, startAngle: .pi * 0.57, endAngle: .pi * 0.93, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor(calibratedRed: 0.73, green: 0.86, blue: 0.76, alpha: red ? 0.13 : 0.09).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addArc(center: center, radius: radius * 0.75, startAngle: -.pi * 0.44, endAngle: -.pi * 0.10, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        if isSelectedPiece {
            ctx.saveGState()
            let glowAlpha = 0.34 + 0.46 * lift
            ctx.setShadow(offset: .zero, blur: cell * (0.07 + 0.07 * lift), color: NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(glowAlpha).cgColor)
            ctx.setLineWidth(2.5 + 0.8 * lift)
            ctx.strokeEllipse(in: pieceRect.insetBy(dx: -2.5 - lift, dy: -2.5 - lift))

            let glint = CGPoint(x: center.x + radius * 0.72, y: center.y + radius * 0.72)
            let glintSize = cell * (0.055 + 0.035 * lift)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.40 + 0.42 * lift).cgColor)
            ctx.setLineWidth(1.35)
            ctx.move(to: CGPoint(x: glint.x - glintSize, y: glint.y))
            ctx.addLine(to: CGPoint(x: glint.x + glintSize, y: glint.y))
            ctx.move(to: CGPoint(x: glint.x, y: glint.y - glintSize))
            ctx.addLine(to: CGPoint(x: glint.x, y: glint.y + glintSize))
            ctx.strokePath()
            ctx.restoreGState()
        }

        let labels: [Character: String] = [
            "R":"俥", "N":"傌", "B":"相", "A":"仕", "K":"帥", "C":"炮", "P":"兵",
            "r":"車", "n":"馬", "b":"象", "a":"士", "k":"將", "c":"砲", "p":"卒"
        ]
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let labelFont = NSFont(name: "Baoli SC", size: cell * 0.52)
            ?? NSFont(name: "Kaiti SC Bold", size: cell * 0.49)
            ?? NSFont.boldSystemFont(ofSize: cell * 0.44)
        let grooveDark = red
            ? NSColor(calibratedRed: 0.19, green: 0.010, blue: 0.006, alpha: 0.86)
            : NSColor(calibratedRed: 0.025, green: 0.10, blue: 0.030, alpha: 0.82)
        let grooveLight = red
            ? NSColor(calibratedRed: 1.0, green: 0.43, blue: 0.31, alpha: 0.52)
            : NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.57, alpha: 0.52)

        // A colourless engraved circle around the glyph. Only shallow light and shadow define
        // the groove, so the mineral clouds and inclusions remain the visual focus.
        let inlayRadius = radius * 0.79
        let inlayRect = CGRect(
            x: center.x - inlayRadius,
            y: center.y - inlayRadius,
            width: inlayRadius * 2,
            height: inlayRadius * 2
        )
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setBlendMode(.multiply)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(red ? 0.18 : 0.24).cgColor)
        ctx.setLineWidth(max(1.8, cell * 0.034))
        ctx.strokeEllipse(in: inlayRect.offsetBy(dx: -0.42, dy: 0.48))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(red ? 0.08 : 0.11).cgColor)
        ctx.setLineWidth(max(0.9, cell * 0.016))
        ctx.strokeEllipse(in: inlayRect)
        ctx.setBlendMode(.screen)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(red ? 0.25 : 0.18).cgColor)
        ctx.setLineWidth(max(0.55, cell * 0.009))
        ctx.strokeEllipse(in: inlayRect.offsetBy(dx: 0.34, dy: -0.37))
        ctx.setBlendMode(.normal)
        ctx.restoreGState()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: sideColor,
            .strokeColor: grooveDark.withAlphaComponent(0.62),
            .strokeWidth: -0.65,
            .paragraphStyle: style
        ]
        let darkCutAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: grooveDark,
            .paragraphStyle: style
        ]
        let litCutAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: grooveLight,
            .paragraphStyle: style
        ]
        let text = labels[piece] ?? String(piece)
        let textRect = NSRect(x: center.x - radius, y: center.y - cell * 0.32, width: radius * 2, height: cell * 0.7)
        (text as NSString).draw(in: textRect.offsetBy(dx: -0.85, dy: 0.90), withAttributes: darkCutAttrs)
        (text as NSString).draw(in: textRect.offsetBy(dx: 0.65, dy: -0.72), withAttributes: litCutAttrs)
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isReturningPiece else { return }
        guard let square = boardSquare(for: event) else { return }
        let boardX = square.x, y = square.y

        if layoutMode {
            handleLayoutClick(x: boardX, y: y)
            return
        }

        guard acceptingMoves else { return }
        let piece = board[y][boardX]
        let isHumanPiece = piece != " " && piece.isUppercase == movableSideIsRed
        if selected == nil {
            guard isHumanPiece else { return }
            selected = (boardX, y)
            liftProgress = 0
            animateLift(to: 1, duration: 0.14)
            onPiecePickedUp?()
            return
        }
        if isHumanPiece {
            if selected?.x == boardX && selected?.y == y {
                returnSelectedPiece()
                return
            }
            selected = (boardX, y)
            liftProgress = 0
            animateLift(to: 1, duration: 0.14)
            onPiecePickedUp?()
            return
        }
        guard let from = selected else { return }
        let move = "\(Character(UnicodeScalar(97 + from.x)!))\(9 - from.y)\(Character(UnicodeScalar(97 + boardX)!))\(9 - y)"
        onMove?(move)
    }

    func returnSelectedPiece() {
        guard selected != nil else { return }
        isReturningPiece = true
        animateLift(to: 0, duration: 0.12) { [weak self] in
            guard let self else { return }
            self.selected = nil
            self.isReturningPiece = false
            self.needsDisplay = true
            self.onPieceReturned?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard layoutMode, let square = boardSquare(for: event) else { return }
        board[square.y][square.x] = " "
        selected = nil
        needsDisplay = true
    }

    private func boardSquare(for event: NSEvent) -> (x: Int, y: Int)? {
        let p = convert(event.locationInWindow, from: nil)
        let g = boardGeometry()
        let x = Int(round((p.x - g.origin.x) / g.cell))
        let visualRank = Int(round((p.y - g.origin.y) / g.cell))
        let boardX = flippedForBlack ? 8 - x : x
        let y = flippedForBlack ? visualRank : 9 - visualRank
        guard (0..<9).contains(boardX), (0..<10).contains(y) else { return nil }
        return (boardX, y)
    }

    private func handleLayoutClick(x: Int, y: Int) {
        switch layoutTool {
        case .erase:
            board[y][x] = " "
            selected = nil
        case .place(let piece):
            board[y][x] = piece
            selected = nil
            onLayoutPiecePlaced?()
        case .move:
            if let from = selected {
                if from.x == x && from.y == y {
                    returnSelectedPiece()
                    return
                } else {
                    board[y][x] = board[from.y][from.x]
                    board[from.y][from.x] = " "
                    liftAnimationTimer?.invalidate()
                    liftProgress = 0
                    selected = nil
                    onLayoutPiecePlaced?()
                }
            } else if board[y][x] != " " {
                selected = (x, y)
                liftProgress = 0
                animateLift(to: 1, duration: 0.14)
                onPiecePickedUp?()
            }
        }
        needsDisplay = true
    }

    private func boardGeometry() -> (origin: CGPoint, cell: CGFloat) {
        let cell = min((bounds.width - 176) / 8, (bounds.height - 176) / 9)
        let width = cell * 8, height = cell * 9
        return (CGPoint(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2), cell)
    }

    private func animateLift(to target: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        liftAnimationTimer?.invalidate()
        let startValue = liftProgress
        let startTime = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date.timeIntervalSinceReferenceDate - startTime
            let raw = min(1, max(0, elapsed / duration))
            let eased: Double
            if target >= startValue {
                eased = 1 - pow(1 - raw, 3)
            } else {
                eased = raw * raw
            }
            self.liftProgress = startValue + (target - startValue) * CGFloat(eased)
            self.needsDisplay = true
            if raw >= 1 {
                timer.invalidate()
                self.liftAnimationTimer = nil
                completion?()
            }
        }
        liftAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

final class ScoreboardView: NSView {
    private var redTime = "00:00.0"
    private var blackTime = "00:00.0"
    private var activeRed: Bool?
    private var redScore = "--"
    private var blackScore = "--"
    private var redWin: Double?
    private var drawChance: Double?
    private var blackWin: Double?
    private var analysisDetail = "正在计算局面评分"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "局面评分正在计算。正数表示该方有利；评分反映最佳应对下的趋势，不代表已经获胜。"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("记分板")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateTimes(red: String, black: String, activeRed: Bool?) {
        redTime = red
        blackTime = black
        self.activeRed = activeRed
        updateAccessibilityValue()
        needsDisplay = true
    }

    func setCalculating() {
        redScore = "计算中"
        blackScore = "计算中"
        redWin = nil
        drawChance = nil
        blackWin = nil
        analysisDetail = "正在计算局面评分"
        toolTip = "局面评分正在计算。正数表示该方有利；评分反映最佳应对下的趋势，不代表已经获胜。"
        updateAccessibilityValue()
        needsDisplay = true
    }

    func updateEvaluation(redScore: String, blackScore: String, redScoreValue: Double?, redMate: Int?, redWin: Double?, draw: Double?, blackWin: Double?, depth: Int, nodes: Int) {
        self.redScore = redScore
        self.blackScore = blackScore
        self.redWin = redWin
        drawChance = draw
        self.blackWin = blackWin
        let nodeText = nodes >= 10_000 ? String(format: "%.1f万", Double(nodes) / 10_000.0) : String(nodes)
        analysisDetail = "深度 \(depth) · 节点 \(nodeText)"
        let advantage = advantageDescription(redScore: redScoreValue, redMate: redMate)
        let help = "局面判断：\(advantage)。红方 \(redScore)，黑方 \(blackScore)。\(analysisDetail)。正数表示该方有利；这是最佳应对下的引擎趋势，不代表已经获胜。"
        toolTip = help
        setAccessibilityHelp(help)
        updateAccessibilityValue()
        needsDisplay = true
    }

    private func advantageDescription(redScore: Double?, redMate: Int?) -> String {
        if let mate = redMate {
            if mate > 0 { return "红方存在强制杀棋" }
            if mate < 0 { return "黑方存在强制杀棋" }
        }
        guard let score = redScore else { return "暂时无法判断" }
        let magnitude = abs(score)
        if magnitude < 0.30 { return "局面基本均势" }
        let side = score > 0 ? "红方" : "黑方"
        if magnitude < 1.0 { return "\(side)轻微优势" }
        if magnitude < 3.0 { return "\(side)明显优势" }
        return "\(side)较大优势"
    }

    private func updateAccessibilityValue() {
        let probability: String
        if let redWin, let drawChance, let blackWin {
            probability = String(format: "红胜 %.1f%%，和棋 %.1f%%，黑胜 %.1f%%", redWin, drawChance, blackWin)
        } else {
            probability = "胜率计算中"
        }
        let turn = activeRed.map { $0 ? "红方行棋" : "黑方行棋" } ?? "计时暂停"
        setAccessibilityValue("\(turn)。红方 \(redTime)，黑方 \(blackTime)。红方局面 \(redScore)，黑方局面 \(blackScore)。\(probability)")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: outer, cornerWidth: 15, cornerHeight: 15, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let background = [
            NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.078, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.135, green: 0.125, blue: 0.105, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.055, green: 0.060, blue: 0.058, alpha: 1).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: background, locations: [0, 0.48, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: outer.minX, y: outer.maxY), end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.025).cgColor)
        for x in stride(from: outer.minX - outer.height, through: outer.maxX, by: 18) {
            ctx.move(to: CGPoint(x: x, y: outer.minY))
            ctx.addLine(to: CGPoint(x: x + outer.height, y: outer.maxY))
        }
        ctx.setLineWidth(0.55)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.72, green: 0.53, blue: 0.25, alpha: 0.72).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        let inner = outer.insetBy(dx: 3, dy: 3)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(0.7)
        ctx.strokePath()

        let titleStyle = NSMutableParagraphStyle(); titleStyle.alignment = .center
        ("记 分 板" as NSString).draw(in: NSRect(x: 0, y: bounds.height - 29, width: bounds.width, height: 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.34, alpha: 1),
            .paragraphStyle: titleStyle
        ])

        let half = bounds.width / 2
        drawSide(ctx: ctx, title: "红方", time: redTime, score: redScore, rect: NSRect(x: 9, y: 59, width: half - 13, height: 72), accent: NSColor(calibratedRed: 0.89, green: 0.14, blue: 0.085, alpha: 1), active: activeRed == true)
        drawSide(ctx: ctx, title: "黑方", time: blackTime, score: blackScore, rect: NSRect(x: half + 4, y: 59, width: half - 13, height: 72), accent: NSColor(calibratedRed: 0.20, green: 0.82, blue: 0.43, alpha: 1), active: activeRed == false)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: half, y: 62)); ctx.addLine(to: CGPoint(x: half, y: 128)); ctx.strokePath()

        let probabilityText: String
        if let redWin, let drawChance, let blackWin {
            probabilityText = String(format: "红 %.1f%%     和 %.1f%%     黑 %.1f%%", redWin, drawChance, blackWin)
            drawProbabilityBar(ctx: ctx, red: redWin, draw: drawChance, black: blackWin)
        } else {
            probabilityText = "胜率正在计算…"
        }
        (probabilityText as NSString).draw(in: NSRect(x: 13, y: 8, width: bounds.width - 26, height: 18), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
            .paragraphStyle: titleStyle
        ])
    }

    private func drawSide(ctx: CGContext, title: String, time: String, score: String, rect: NSRect, accent: NSColor, active: Bool) {
        let centered = NSMutableParagraphStyle(); centered.alignment = .center
        let titleText = active ? "▶ \(title)" : title
        (titleText as NSString).draw(in: NSRect(x: rect.minX, y: rect.maxY - 17, width: rect.width, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: active ? accent : NSColor.white.withAlphaComponent(0.68),
            .paragraphStyle: centered
        ])

        let flap = NSRect(x: rect.minX + 3, y: rect.minY + 22, width: rect.width - 6, height: 34)
        let flapPath = CGPath(roundedRect: flap, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        if active {
            ctx.setShadow(offset: .zero, blur: 7, color: accent.withAlphaComponent(0.46).cgColor)
        }
        ctx.addPath(flapPath)
        ctx.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 0.96).cgColor)
        ctx.fillPath()
        ctx.addPath(flapPath)
        ctx.setStrokeColor((active ? accent.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.13)).cgColor)
        ctx.setLineWidth(active ? 1.5 : 0.8)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: flap.minX + 3, y: flap.midY)); ctx.addLine(to: CGPoint(x: flap.maxX - 3, y: flap.midY)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: flap.minX + 3, y: flap.midY - 1)); ctx.addLine(to: CGPoint(x: flap.maxX - 3, y: flap.midY - 1)); ctx.strokePath()

        (time as NSString).draw(in: flap.insetBy(dx: 2, dy: 2), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
            .paragraphStyle: centered
        ])
        ("局面 \(score)" as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: 17), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: accent.withAlphaComponent(0.92),
            .paragraphStyle: centered
        ])
    }

    private func drawProbabilityBar(ctx: CGContext, red: Double, draw: Double, black: Double) {
        let bar = NSRect(x: 15, y: 31, width: bounds.width - 30, height: 7)
        let total = max(0.001, red + draw + black)
        let redWidth = bar.width * CGFloat(red / total)
        let drawWidth = bar.width * CGFloat(draw / total)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor(calibratedRed: 0.86, green: 0.12, blue: 0.075, alpha: 0.92).cgColor)
        ctx.fill(NSRect(x: bar.minX, y: bar.minY, width: redWidth, height: bar.height))
        ctx.setFillColor(NSColor(calibratedRed: 0.74, green: 0.59, blue: 0.31, alpha: 0.78).cgColor)
        ctx.fill(NSRect(x: bar.minX + redWidth, y: bar.minY, width: drawWidth, height: bar.height))
        ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.66, blue: 0.33, alpha: 0.88).cgColor)
        ctx.fill(NSRect(x: bar.minX + redWidth + drawWidth, y: bar.minY, width: max(0, bar.width - redWidth - drawWidth), height: bar.height))
        ctx.restoreGState()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let boardView = BoardView(frame: .zero)
    private let engine = PikafishEngine()
    private let predictionEngine = PikafishEngine(threads: 2, hash: 128, multiPV: 3)
    private lazy var moveSound: NSSound? = bundledSound(named: "move", fallback: "/System/Library/Sounds/Tink.aiff")
    private lazy var captureSound: NSSound? = bundledSound(named: "capture", fallback: "/System/Library/Sounds/Basso.aiff")
    private lazy var pickupSound: NSSound? = bundledSound(named: "pickup", fallback: "/System/Library/Sounds/Pop.aiff")
    private let subtitleLabel = NSTextField(labelWithString: "红方玩家 · 黑方电脑")
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在启动 Pikafish…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let redClockLabel = NSTextField(labelWithString: "红方 00:00")
    private let blackClockLabel = NSTextField(labelWithString: "黑方 00:00")
    private let positionScoreLabel = NSTextField(labelWithString: "评分  红方计算中 · 黑方计算中")
    private let positionProbabilityLabel = NSTextField(labelWithString: "胜率  红 -- · 和 -- · 黑 --")
    private let scoreboardView = ScoreboardView(frame: .zero)
    private let historyView = NSTextView(frame: .zero)
    private let engineLogView = NSTextView(frame: .zero)
    private let predictionView = NSTextView(frame: .zero)
    private let recordSelector = NSSegmentedControl(labels: ["着法记录", "引擎日志", "指导建议"], trackingMode: .selectOne, target: nil, action: nil)
    private let recordScroll = NSScrollView()
    private let timeCombo = NSComboBox(frame: .zero)
    private let predictionToggle = NSSwitch(frame: .zero)
    private let redControllerSwitch = NSSwitch(frame: .zero)
    private let blackControllerSwitch = NSSwitch(frame: .zero)
    private let redFastWinSwitch = NSSwitch(frame: .zero)
    private let blackFastWinSwitch = NSSwitch(frame: .zero)
    private let layoutButton = NSButton(title: "进入布局模式", target: nil, action: nil)
    private let layoutPanel = NSStackView()
    private let layoutToolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let layoutTurnSwitch = NSSwitch(frame: .zero)
    private var moves: [String] = []
    private var waitingForEngine = false
    private var ignoreNextBestMove = false
    private var isLayoutMode = false
    private var engineSearchingInfinite = false
    private var restartSearchAfterDiscard = false
    private var switchingThinkMode = false
    private var initialPosition = Array(repeating: Array(repeating: Character(" "), count: 9), count: 10)
    private var initialSideIsRed = true
    private var customBaseFEN: String?
    private var layoutBackupPosition: [[Character]]?
    private var redTimeElapsed: TimeInterval = 0
    private var blackTimeElapsed: TimeInterval = 0
    private var activeClockIsRed: Bool?
    private var clockLastTick = Date()
    private var clockTimer: Timer?
    private var gameEnded = false
    private var predictionReady = false
    private var predictionSearching = false
    private var predictionRestartPending = false
    private var predictionDiscardNextBestMove = false
    private var predictionFinished = false
    private var predictionFinalMove: String?
    private var predictionCandidateMove: String?
    private var predictionCandidateStreak = 0
    private var predictionLines: [Int: EngineAnalysisLine] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        wireEngine()
        engine.start()
        predictionEngine.start()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pikafish 中国象棋"
        window.center()
        window.minSize = NSSize(width: 820, height: 650)
        window.isReleasedWhenClosed = false

        let root = NSView(); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        boardView.translatesAutoresizingMaskIntoConstraints = false

        let side = NSStackView(); side.orientation = .vertical; side.spacing = 12; side.alignment = .leading
        side.translatesAutoresizingMaskIntoConstraints = false; side.edgeInsets = NSEdgeInsets(top: 22, left: 8, bottom: 22, right: 18)

        let title = NSTextField(labelWithString: "Pikafish 对战")
        title.font = NSFont.systemFont(ofSize: 25, weight: .bold)
        subtitleLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        statusLabel.maximumNumberOfLines = 3
        detailLabel.textColor = .secondaryLabelColor; detailLabel.maximumNumberOfLines = 4
        detailLabel.toolTip = "深度：向后搜索的层数。红方/黑方评分：从标明的一方视角评价，正数对该方有利。节点：已计算的局面数。红胜/和棋/黑胜：由引擎 WDL 模型估算，并非保证结果。"

        scoreboardView.translatesAutoresizingMaskIntoConstraints = false

        let newButton = NSButton(title: "新对局", target: self, action: #selector(newGame))
        newButton.bezelStyle = .rounded; newButton.controlSize = .regular
        let undoButton = NSButton(title: "悔棋", target: self, action: #selector(undoMove))
        undoButton.bezelStyle = .rounded; undoButton.controlSize = .regular
        let undoAllButton = NSButton(title: "悔至起点", target: self, action: #selector(undoAllMoves))
        undoAllButton.bezelStyle = .rounded; undoAllButton.controlSize = .regular
        undoAllButton.toolTip = "撤回本局全部着法；标准对局回到开局，中残局回到该布局的起点。"
        let rotateButton = NSButton(title: "旋转棋盘", target: self, action: #selector(rotateBoard))
        rotateButton.bezelStyle = .rounded; rotateButton.controlSize = .regular
        let firstButtonRow = NSStackView(views: [newButton, undoButton])
        firstButtonRow.orientation = .horizontal; firstButtonRow.spacing = 10; firstButtonRow.distribution = .fillEqually
        let secondButtonRow = NSStackView(views: [undoAllButton, rotateButton])
        secondButtonRow.orientation = .horizontal; secondButtonRow.spacing = 10; secondButtonRow.distribution = .fillEqually
        let gameButtons = NSStackView(views: [firstButtonRow, secondButtonRow])
        gameButtons.orientation = .vertical; gameButtons.spacing = 6; gameButtons.alignment = .leading
        firstButtonRow.widthAnchor.constraint(equalTo: gameButtons.widthAnchor).isActive = true
        secondButtonRow.widthAnchor.constraint(equalTo: gameButtons.widthAnchor).isActive = true
        layoutButton.title = "进入中残局布局"
        layoutButton.target = self; layoutButton.action = #selector(beginLayoutMode)
        layoutButton.bezelStyle = .rounded; layoutButton.controlSize = .regular

        buildLayoutPanel()
        let colorTitle = NSTextField(labelWithString: "双方控制")
        colorTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        colorTitle.textColor = NSColor(calibratedRed: 0.88, green: 0.73, blue: 0.35, alpha: 1)
        redControllerSwitch.state = .off
        blackControllerSwitch.state = .on
        redControllerSwitch.controlSize = .small
        blackControllerSwitch.controlSize = .small
        redControllerSwitch.target = self; redControllerSwitch.action = #selector(sideControllerChanged)
        blackControllerSwitch.target = self; blackControllerSwitch.action = #selector(sideControllerChanged)
        redControllerSwitch.toolTip = "关闭为玩家控制，开启为电脑控制；切换不会重置当前棋盘、着法或计时。"
        blackControllerSwitch.toolTip = "关闭为玩家控制，开启为电脑控制；切换不会重置当前棋盘、着法或计时。"
        redFastWinSwitch.state = .off
        blackFastWinSwitch.state = .off
        redFastWinSwitch.controlSize = .mini
        blackFastWinSwitch.controlSize = .mini
        redFastWinSwitch.target = self; redFastWinSwitch.action = #selector(fastWinModeChanged)
        blackFastWinSwitch.target = self; blackFastWinSwitch.action = #selector(fastWinModeChanged)
        redFastWinSwitch.toolTip = "仅红方为电脑时生效：不降低搜索深度；只有引擎证明存在杀棋时才采用最短杀法，其余保持标准最佳着法。"
        blackFastWinSwitch.toolTip = "仅黑方为电脑时生效：不降低搜索深度；只有引擎证明存在杀棋时才采用最短杀法，其余保持标准最佳着法。"
        let redControllerLabel = NSTextField(labelWithString: "红方")
        redControllerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        redControllerLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.31, blue: 0.21, alpha: 1)
        redControllerLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let blackControllerLabel = NSTextField(labelWithString: "黑方")
        blackControllerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        blackControllerLabel.textColor = NSColor(calibratedRed: 0.43, green: 0.82, blue: 0.61, alpha: 1)
        blackControllerLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let redPlayerLabel = makePanelLabel("玩家")
        let redComputerLabel = makePanelLabel("电脑")
        let blackPlayerLabel = makePanelLabel("玩家")
        let blackComputerLabel = makePanelLabel("电脑")
        let redFastWinLabel = makePanelLabel("快胜")
        let blackFastWinLabel = makePanelLabel("快胜")
        redFastWinLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.34, alpha: 1)
        blackFastWinLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.34, alpha: 1)
        redFastWinLabel.toolTip = redFastWinSwitch.toolTip
        blackFastWinLabel.toolTip = blackFastWinSwitch.toolTip
        let redControllerRow = NSStackView(views: [redControllerLabel, redPlayerLabel, redControllerSwitch, redComputerLabel, redFastWinLabel, redFastWinSwitch])
        redControllerRow.orientation = .horizontal; redControllerRow.spacing = 5; redControllerRow.alignment = .centerY
        let blackControllerRow = NSStackView(views: [blackControllerLabel, blackPlayerLabel, blackControllerSwitch, blackComputerLabel, blackFastWinLabel, blackFastWinSwitch])
        blackControllerRow.orientation = .horizontal; blackControllerRow.spacing = 5; blackControllerRow.alignment = .centerY
        updateFastWinAvailability()
        let timeTitle = NSTextField(labelWithString: "思考")
        timeTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        timeTitle.textColor = NSColor(calibratedRed: 0.88, green: 0.73, blue: 0.35, alpha: 1)
        timeCombo.addItems(withObjectValues: ["0.5", "1", "3", "5", "无限分析"])
        timeCombo.stringValue = "1"
        timeCombo.numberOfVisibleItems = 5
        timeCombo.isEditable = true
        timeCombo.target = self; timeCombo.action = #selector(thinkTimeChanged)
        timeCombo.toolTip = "可输入 0.1 到 600 秒，同时控制电脑落子和指导模式；数字时间结束后锁定指导箭头。“无限分析”会持续计算。"
        timeCombo.widthAnchor.constraint(equalToConstant: 88).isActive = true

        predictionToggle.state = .off
        predictionToggle.controlSize = .small
        predictionToggle.target = self; predictionToggle.action = #selector(predictionModeChanged)
        predictionToggle.toolTip = "独立的 Pikafish 分析器会持续指导当前走棋方，只显示推荐着法，不会自动落子。"
        let predictionTitle = makePanelLabel("指导")
        predictionTitle.toolTip = predictionToggle.toolTip

        let engineRow = NSStackView(views: [timeTitle, timeCombo, predictionTitle, predictionToggle])
        engineRow.orientation = .horizontal
        engineRow.spacing = 8
        engineRow.alignment = .centerY

        let controlTitle = NSTextField(labelWithString: "控 制 板")
        controlTitle.alignment = .center
        controlTitle.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        controlTitle.textColor = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.34, alpha: 1)
        controlTitle.toolTip = "集中管理对局操作、双方控制方式、引擎思考时间和指导模式。"

        let controlPanel = NSStackView()
        controlPanel.orientation = .vertical
        controlPanel.alignment = .leading
        controlPanel.spacing = 7
        controlPanel.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 12, right: 12)
        controlPanel.appearance = NSAppearance(named: .darkAqua)
        controlPanel.wantsLayer = true
        controlPanel.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.078, alpha: 0.98).cgColor
        controlPanel.layer?.cornerRadius = 13
        controlPanel.layer?.borderWidth = 1.1
        controlPanel.layer?.borderColor = NSColor(calibratedRed: 0.82, green: 0.66, blue: 0.30, alpha: 0.58).cgColor
        controlPanel.layer?.shadowColor = NSColor.black.cgColor
        controlPanel.layer?.shadowOpacity = 0.22
        controlPanel.layer?.shadowRadius = 6
        controlPanel.layer?.shadowOffset = NSSize(width: 0, height: -2)
        [controlTitle, gameButtons, layoutButton, layoutPanel, colorTitle, redControllerRow, blackControllerRow, engineRow].forEach {
            controlPanel.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: controlPanel.widthAnchor, constant: -24).isActive = true
        }
        controlPanel.setCustomSpacing(10, after: controlTitle)
        controlPanel.setCustomSpacing(10, after: layoutPanel)
        controlPanel.setCustomSpacing(5, after: colorTitle)

        historyView.isEditable = false; historyView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        historyView.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.060, alpha: 1)
        historyView.textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        engineLogView.isEditable = false; engineLogView.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        engineLogView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        engineLogView.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        predictionView.isEditable = false; predictionView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        predictionView.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.085, blue: 0.065, alpha: 1)
        predictionView.textColor = NSColor(calibratedRed: 0.76, green: 1.0, blue: 0.84, alpha: 1)
        predictionView.string = "开启指导模式后显示三条候选线路。"

        let logTitle = NSTextField(labelWithString: "日 志 板")
        logTitle.alignment = .center
        logTitle.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        logTitle.textColor = NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.34, alpha: 1)
        logTitle.toolTip = "集中查看可读着法、Pikafish 原始引擎日志和指导建议。"
        recordSelector.selectedSegment = 0
        recordSelector.target = self; recordSelector.action = #selector(recordViewChanged)
        recordSelector.toolTip = "在可读着法记录和 Pikafish 原始 UCI 收发日志之间切换"
        recordScroll.documentView = historyView; recordScroll.hasVerticalScroller = true; recordScroll.borderType = .noBorder
        recordScroll.translatesAutoresizingMaskIntoConstraints = false
        recordScroll.wantsLayer = true
        recordScroll.layer?.cornerRadius = 7
        recordScroll.layer?.borderWidth = 1
        recordScroll.layer?.borderColor = NSColor(calibratedRed: 0.74, green: 0.61, blue: 0.31, alpha: 0.25).cgColor

        let logPanel = NSStackView()
        logPanel.orientation = .vertical
        logPanel.alignment = .leading
        logPanel.spacing = 7
        logPanel.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        logPanel.appearance = NSAppearance(named: .darkAqua)
        logPanel.wantsLayer = true
        logPanel.layer?.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.078, alpha: 0.98).cgColor
        logPanel.layer?.cornerRadius = 13
        logPanel.layer?.borderWidth = 1.1
        logPanel.layer?.borderColor = NSColor(calibratedRed: 0.82, green: 0.66, blue: 0.30, alpha: 0.58).cgColor
        [logTitle, recordSelector, recordScroll].forEach {
            logPanel.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: logPanel.widthAnchor, constant: -24).isActive = true
        }
        logPanel.setCustomSpacing(8, after: logTitle)

        [title, subtitleLabel, scoreboardView, controlPanel, logPanel].forEach { side.addArrangedSubview($0) }
        side.setCustomSpacing(4, after: title)
        side.setCustomSpacing(10, after: scoreboardView)
        side.setCustomSpacing(10, after: controlPanel)

        root.addSubview(boardView); root.addSubview(side)
        NSLayoutConstraint.activate([
            boardView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            boardView.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            boardView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            boardView.widthAnchor.constraint(equalTo: boardView.heightAnchor, multiplier: 0.92),
            side.leadingAnchor.constraint(equalTo: boardView.trailingAnchor, constant: 14),
            side.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            scoreboardView.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -28),
            scoreboardView.heightAnchor.constraint(equalToConstant: 166),
            controlPanel.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -28),
            logPanel.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -28),
            recordScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])

        boardView.onMove = { [weak self] move in self?.humanMove(move) }
        boardView.onPiecePickedUp = { [weak self] in self?.playPickupSound() }
        boardView.onPieceReturned = { [weak self] in self?.playMoveSound(capture: false) }
        boardView.onLayoutPiecePlaced = { [weak self] in self?.playMoveSound(capture: false) }
        pickupSound?.volume = 0.58
        moveSound?.volume = 0.72
        captureSound?.volume = 0.88
        initialPosition = boardView.positionSnapshot()
    }

    private func makePanelLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        return label
    }

    @objc private func recordViewChanged() {
        switch recordSelector.selectedSegment {
        case 0: recordScroll.documentView = historyView
        case 1: recordScroll.documentView = engineLogView
        default: recordScroll.documentView = predictionView
        }
        if recordSelector.selectedSegment == 0 {
            historyView.scrollToEndOfDocument(nil)
        } else if recordSelector.selectedSegment == 1 {
            engineLogView.scrollToEndOfDocument(nil)
        } else {
            predictionView.scrollToEndOfDocument(nil)
        }
    }

    private func appendEngineLog(_ line: String) {
        guard let storage = engineLogView.textStorage else { return }
        let outgoing = line.hasPrefix("›")
        storage.append(NSAttributedString(string: line + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: outgoing ? NSColor.systemOrange : NSColor(calibratedWhite: 0.86, alpha: 1)
        ]))
        if storage.length > 200_000 {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 150_000))
        }
        if recordSelector.selectedSegment == 1 { engineLogView.scrollToEndOfDocument(nil) }
    }

    private func buildLayoutPanel() {
        layoutPanel.orientation = .vertical
        layoutPanel.alignment = .leading
        layoutPanel.spacing = 6
        layoutPanel.isHidden = true

        let title = NSTextField(labelWithString: "布局工具")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(calibratedRed: 0.88, green: 0.73, blue: 0.35, alpha: 1)
        layoutToolPopup.addItems(withTitles: [
            "移动棋子", "删除棋子",
            "红方：车", "红方：马", "红方：相", "红方：仕", "红方：帅", "红方：炮", "红方：兵",
            "黑方：车", "黑方：马", "黑方：象", "黑方：士", "黑方：将", "黑方：炮", "黑方：卒"
        ])
        layoutToolPopup.target = self; layoutToolPopup.action = #selector(layoutToolChanged)

        let turnLabel = NSTextField(labelWithString: "布局完成后")
        turnLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        turnLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        let redTurnLabel = makePanelLabel("红方走")
        let blackTurnLabel = makePanelLabel("黑方走")
        redTurnLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.31, blue: 0.21, alpha: 1)
        blackTurnLabel.textColor = NSColor(calibratedRed: 0.43, green: 0.82, blue: 0.61, alpha: 1)
        layoutTurnSwitch.state = .off
        layoutTurnSwitch.controlSize = .small
        layoutTurnSwitch.toolTip = "关闭为红方先走，开启为黑方先走。"
        let turnRow = NSStackView(views: [turnLabel, redTurnLabel, layoutTurnSwitch, blackTurnLabel])
        turnRow.orientation = .horizontal
        turnRow.spacing = 7
        turnRow.alignment = .centerY

        let standardButton = NSButton(title: "标准布局", target: self, action: #selector(useStandardLayout))
        let clearButton = NSButton(title: "清空棋盘", target: self, action: #selector(clearLayout))
        let positionButtons = NSStackView(views: [standardButton, clearButton])
        positionButtons.orientation = .horizontal; positionButtons.spacing = 8; positionButtons.distribution = .fillEqually

        let finishButton = NSButton(title: "完成布局", target: self, action: #selector(finishLayoutMode))
        finishButton.bezelStyle = .rounded; finishButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelLayoutMode))
        let finishButtons = NSStackView(views: [finishButton, cancelButton])
        finishButtons.orientation = .horizontal; finishButtons.spacing = 8; finishButtons.distribution = .fillEqually

        [title, layoutToolPopup, turnRow, positionButtons, finishButtons].forEach {
            layoutPanel.addArrangedSubview($0)
        }
        layoutToolPopup.widthAnchor.constraint(equalTo: layoutPanel.widthAnchor).isActive = true
        turnRow.widthAnchor.constraint(equalTo: layoutPanel.widthAnchor).isActive = true
        positionButtons.widthAnchor.constraint(equalTo: layoutPanel.widthAnchor).isActive = true
        finishButtons.widthAnchor.constraint(equalTo: layoutPanel.widthAnchor).isActive = true
    }

    private func wireEngine() {
        engine.onReady = { [weak self] in
            guard let self else { return }
            if self.isLayoutMode { return }
            if self.waitingForEngine { return }
            self.detailLabel.stringValue = "Pikafish 已就绪"
            self.resumeCurrentTurn()
        }
        engine.onInfo = { _ in }
        engine.onLog = { [weak self] line in self?.appendEngineLog(line) }
        engine.onError = { [weak self] error in
            self?.statusLabel.stringValue = "引擎错误"
            self?.detailLabel.stringValue = error
            self?.boardView.acceptingMoves = false
            self?.pauseClock()
            self?.engineSearchingInfinite = false
        }
        engine.onBestMove = { [weak self] move, mates in self?.engineMove(move, endsGame: mates) }
        engine.onNoLegalMove = { [weak self] in self?.handleNoLegalMove() }

        predictionEngine.onReady = { [weak self] in
            guard let self else { return }
            self.predictionReady = true
            self.startPredictionSearch()
        }
        predictionEngine.onAnalysisLine = { [weak self] line in
            self?.receivePrediction(line)
        }
        predictionEngine.onBestMove = { [weak self] move, _ in
            self?.predictionSearchStopped(bestMove: move)
        }
        predictionEngine.onNoLegalMove = { [weak self] in
            self?.predictionSearchStopped(noLegalMove: true)
        }
        predictionEngine.onError = { [weak self] error in
            guard let self, self.predictionEnabled else { return }
            self.predictionView.string = "指导引擎错误：\(error)"
        }
    }

    private var predictionEnabled: Bool { predictionToggle.state == .on }

    @objc private func predictionModeChanged() {
        if predictionEnabled {
            recordSelector.selectedSegment = 2
            recordViewChanged()
            if predictionLines.isEmpty {
                predictionView.string = predictionReady ? "Pikafish 正在读取当前局面…" : "指导引擎正在初始化…"
            } else {
                renderPredictionLines()
            }
            if let predictionFinalMove { boardView.setPredictionMove(predictionFinalMove) }
            if predictionReady && !predictionSearching && predictionLines.isEmpty { startPredictionSearch() }
        } else {
            boardView.setPredictionMove(nil)
            predictionView.string = "指导模式已关闭。"
        }
    }

    private func startPredictionSearch() {
        guard predictionReady, !isLayoutMode, !gameEnded else { return }
        if predictionSearching {
            predictionRestartPending = true
            predictionDiscardNextBestMove = true
            predictionEngine.stopSearch()
            return
        }
        predictionRestartPending = false
        predictionDiscardNextBestMove = false
        predictionFinished = false
        predictionFinalMove = nil
        predictionCandidateMove = nil
        predictionCandidateStreak = 0
        predictionSearching = true
        predictionLines.removeAll()
        boardView.setPredictionMove(nil)
        if usesInfiniteThinkTime {
            if predictionEnabled { predictionView.string = "Pikafish 正在无限分析；推荐稳定后才更新箭头…" }
            predictionEngine.analyzeInfinite(
                baseFEN: customBaseFEN,
                moves: moves,
                sideToMoveIsRed: currentSideIsRed()
            )
        } else {
            let milliseconds = thinkTimeMilliseconds()
            if predictionEnabled {
                predictionView.string = String(format: "Pikafish 正在计算 %.1f 秒，完成后锁定箭头…", Double(milliseconds) / 1000.0)
            }
            predictionEngine.search(
                baseFEN: customBaseFEN,
                moves: moves,
                milliseconds: milliseconds,
                sideToMoveIsRed: currentSideIsRed()
            )
        }
    }

    private func predictionPositionChanged() {
        predictionLines.removeAll()
        predictionFinished = false
        predictionFinalMove = nil
        predictionCandidateMove = nil
        predictionCandidateStreak = 0
        boardView.setPredictionMove(nil)
        positionScoreLabel.stringValue = "评分  红方局面计算中 · 黑方局面计算中"
        positionProbabilityLabel.stringValue = "胜率  红 -- · 和 -- · 黑 --"
        scoreboardView.setCalculating()
        if predictionEnabled { predictionView.string = "局面已变化，正在更新指导建议…" }
        if predictionSearching {
            predictionRestartPending = true
            predictionDiscardNextBestMove = true
            predictionEngine.stopSearch()
        } else {
            startPredictionSearch()
        }
    }

    private func pausePredictionForLayoutOrGameEnd() {
        predictionRestartPending = false
        predictionLines.removeAll()
        boardView.setPredictionMove(nil)
        if predictionSearching {
            predictionDiscardNextBestMove = true
            predictionEngine.stopSearch()
        }
    }

    private func predictionSearchStopped(bestMove: String? = nil, noLegalMove: Bool = false) {
        predictionSearching = false
        let discarded = predictionDiscardNextBestMove
        if predictionDiscardNextBestMove { predictionDiscardNextBestMove = false }
        if predictionRestartPending && !isLayoutMode && !gameEnded {
            predictionRestartPending = false
            DispatchQueue.main.async { [weak self] in self?.startPredictionSearch() }
        } else if noLegalMove && !gameEnded {
            if predictionEnabled { predictionView.string = "当前走棋方没有合法着法。" }
            boardView.setPredictionMove(nil)
        } else if !discarded, let bestMove {
            predictionFinished = true
            predictionFinalMove = bestMove
            if predictionEnabled {
                boardView.setPredictionMove(bestMove)
                renderPredictionLines()
            }
        }
    }

    private func receivePrediction(_ line: EngineAnalysisLine) {
        guard predictionSearching, !predictionRestartPending,
              (1...3).contains(line.rank), let bestMove = line.pv.first else { return }
        predictionLines[line.rank] = line
        if line.rank == 1 {
            updatePositionEvaluation(line)
            if predictionCandidateMove == bestMove {
                predictionCandidateStreak += 1
            } else {
                predictionCandidateMove = bestMove
                predictionCandidateStreak = 1
            }
            if predictionEnabled && usesInfiniteThinkTime && predictionCandidateStreak >= 3 {
                boardView.setPredictionMove(bestMove)
            }
        }
        if predictionEnabled { renderPredictionLines() }
    }

    private func updatePositionEvaluation(_ line: EngineAnalysisLine) {
        let redText: String
        let blackText: String
        if let redScore = line.redScore {
            redText = String(format: "%+.2f", redScore)
            blackText = String(format: "%+.2f", -redScore)
        } else if let redMate = line.redMate {
            if redMate > 0 {
                redText = "杀\(redMate)"
                blackText = "被杀\(redMate)"
            } else {
                redText = "被杀\(abs(redMate))"
                blackText = "杀\(abs(redMate))"
            }
        } else {
            redText = "--"
            blackText = "--"
        }

        let scoreLine = NSMutableAttributedString(string: "评分  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        scoreLine.append(NSAttributedString(string: "红方局面 \(redText)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor(calibratedRed: 0.74, green: 0.08, blue: 0.055, alpha: 1)
        ]))
        scoreLine.append(NSAttributedString(string: "  ·  ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
        scoreLine.append(NSAttributedString(string: "黑方局面 \(blackText)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]))
        positionScoreLabel.attributedStringValue = scoreLine

        if let red = line.redWin, let draw = line.draw, let black = line.blackWin {
            positionProbabilityLabel.stringValue = String(format: "胜率  红 %.1f%% · 和 %.1f%% · 黑 %.1f%%", red, draw, black)
        }
        scoreboardView.updateEvaluation(
            redScore: redText,
            blackScore: blackText,
            redScoreValue: line.redScore,
            redMate: line.redMate,
            redWin: line.redWin,
            draw: line.draw,
            blackWin: line.blackWin,
            depth: line.depth,
            nodes: line.nodes
        )
        let nodes = line.nodes >= 10_000
            ? String(format: "%.1f 万", Double(line.nodes) / 10_000.0)
            : String(line.nodes)
        positionScoreLabel.toolTip = "当前分析深度 \(line.depth)，已计算节点 \(nodes)。正数表示该方有利。"
    }

    private func renderPredictionLines() {
        let state = boardView.positionSnapshot()
        let side = currentSideIsRed() ? "红方" : "黑方"
        let phase = predictionFinished ? "指导完成 · 箭头已锁定" : (usesInfiniteThinkTime ? "无限指导" : "指导计算中")
        var output = "● 当前 \(side)走 · \(phase)\n"
        let badges = [1: "①", 2: "②", 3: "③"]
        for rank in 1...3 {
            guard let line = predictionLines[rank], let move = line.pv.first else { continue }
            let readable: String
            if let decoded = decodeMove(move),
               (0..<10).contains(decoded.y1), (0..<9).contains(decoded.x1) {
                let piece = state[decoded.y1][decoded.x1]
                readable = chineseNotation(move: move, piece: piece, state: state, decoded: decoded)
            } else {
                readable = move
            }
            let probability: String
            if let red = line.redWin, let draw = line.draw, let black = line.blackWin {
                probability = String(format: "红 %.1f%%  和 %.1f%%  黑 %.1f%%", red, draw, black)
            } else {
                probability = "胜率计算中"
            }
            let nodes = line.nodes >= 10_000
                ? String(format: "%.1f万", Double(line.nodes) / 10_000.0)
                : String(line.nodes)
            let route = line.pv.prefix(6).joined(separator: " ")
            output += "\n\(badges[rank] ?? String(rank)) \(readable)  [\(move)]\n"
            output += "深度 \(line.depth) · \(line.score) · 节点 \(nodes)\n"
            output += "\(probability)\n路线 \(route)\n"
        }
        predictionView.string = output
        if recordSelector.selectedSegment == 2 { predictionView.scrollToBeginningOfDocument(nil) }
    }

    private func humanMove(_ move: String) {
        guard !waitingForEngine, !isLayoutMode, !gameEnded else { return }
        pauseClock()
        guard engineAcceptsMove(move) else {
            statusLabel.stringValue = "非法着法"
            detailLabel.stringValue = illegalMoveExplanation(move)
            appendEngineLog("× GUI 拒绝非法着法：\(move)")
            boardView.returnSelectedPiece()
            boardView.acceptingMoves = true
            startClock(forRed: currentSideIsRed())
            return
        }
        appendEngineLog("✓ GUI 合法着法校验通过：\(move)")
        let captured = moveCapturesPiece(move)
        moves.append(move); boardView.rebuild(from: initialPosition, moves: moves); updateHistory()
        playMoveSound(capture: captured)
        if !bothKingsPresent() {
            finishGame("帅或将已被移除，对局结束")
            return
        }
        predictionPositionChanged()
        detailLabel.stringValue = ""
        resumeCurrentTurn()
    }

    private func engineMove(_ move: String, endsGame: Bool) {
        if consumeDiscardedBestMove() { return }
        engineSearchingInfinite = false
        switchingThinkMode = false
        pauseClock()
        let captured = moveCapturesPiece(move)
        moves.append(move); boardView.rebuild(from: initialPosition, moves: moves); updateHistory()
        playMoveSound(capture: captured)
        if endsGame || !bothKingsPresent() {
            let winner = sideIsRed(forPly: moves.count - 1) ? "红方" : "黑方"
            finishGame("\(winner)完成将死，对局结束")
            return
        }
        predictionPositionChanged()
        waitingForEngine = false
        detailLabel.stringValue += "\nPikafish：\(move)"
        resumeCurrentTurn(delay: 0.18)
    }

    private func handleNoLegalMove() {
        if consumeDiscardedBestMove() { return }
        engineSearchingInfinite = false
        switchingThinkMode = false
        let loserIsRed = currentSideIsRed()
        finishGame("\(loserIsRed ? "红方" : "黑方")无合法着法，\(loserIsRed ? "黑方" : "红方")获胜")
    }

    private func consumeDiscardedBestMove() -> Bool {
        guard ignoreNextBestMove else { return false }
        ignoreNextBestMove = false
        switchingThinkMode = false
        if restartSearchAfterDiscard {
            restartSearchAfterDiscard = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.waitingForEngine, !self.isLayoutMode, !self.gameEnded else { return }
                self.beginComputerSearch()
            }
        }
        return true
    }

    private func bothKingsPresent() -> Bool {
        let pieces = boardView.positionSnapshot().flatMap { $0 }
        return pieces.contains("K") && pieces.contains("k")
    }

    private func finishGame(_ message: String) {
        gameEnded = true
        waitingForEngine = false
        engineSearchingInfinite = false
        switchingThinkMode = false
        boardView.acceptingMoves = false
        pausePredictionForLayoutOrGameEnd()
        pauseClock()
        statusLabel.stringValue = "对局结束"
        detailLabel.stringValue = message
    }

    private func updateHistory() {
        let result = NSMutableAttributedString()
        var state = initialPosition
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 4

        for (index, move) in moves.enumerated() {
            guard let decoded = decodeMove(move),
                  (0..<10).contains(decoded.y1), (0..<10).contains(decoded.y2),
                  (0..<9).contains(decoded.x1), (0..<9).contains(decoded.x2) else { continue }
            let piece = state[decoded.y1][decoded.x1]
            let isRed = piece.isUppercase
            let turnPrefix = String(format: "%2d. %@  ", index + 1, isRed ? "红" : "黑")
            let readable = chineseNotation(move: move, piece: piece, state: state, decoded: decoded)
            let line = "\(turnPrefix)\(readable)   \(move.prefix(2))→\(move.dropFirst(2).prefix(2))\(index + 1 < moves.count ? "\n" : "")"
            let color = isRed
                ? NSColor(calibratedRed: 0.98, green: 0.36, blue: 0.25, alpha: 1)
                : NSColor(calibratedRed: 0.47, green: 0.86, blue: 0.64, alpha: 1)
            result.append(NSAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))

            state[decoded.y2][decoded.x2] = piece
            state[decoded.y1][decoded.x1] = " "
        }
        historyView.textStorage?.setAttributedString(result)
        historyView.scrollToEndOfDocument(nil)
    }

    private func decodeMove(_ move: String) -> (x1: Int, y1: Int, x2: Int, y2: Int)? {
        guard move.count >= 4 else { return nil }
        let chars = Array(move)
        guard let a = Character("a").asciiValue,
              let f1 = chars[0].asciiValue, let rank1 = chars[1].wholeNumberValue,
              let f2 = chars[2].asciiValue, let rank2 = chars[3].wholeNumberValue else { return nil }
        return (Int(f1 - a), 9 - rank1, Int(f2 - a), 9 - rank2)
    }

    private func moveCapturesPiece(_ move: String) -> Bool {
        guard let decoded = decodeMove(move),
              (0..<10).contains(decoded.y2), (0..<9).contains(decoded.x2) else { return false }
        return boardView.positionSnapshot()[decoded.y2][decoded.x2] != " "
    }

    private func bundledSound(named name: String, fallback: String) -> NSSound? {
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: true)
        }
        return NSSound(contentsOfFile: fallback, byReference: true)
    }

    private func playMoveSound(capture: Bool) {
        let sound = capture ? captureSound : moveSound
        sound?.stop()
        sound?.play()
    }

    private func playPickupSound() {
        pickupSound?.stop()
        pickupSound?.play()
    }

    private func chineseNotation(move: String, piece: Character, state: [[Character]], decoded: (x1: Int, y1: Int, x2: Int, y2: Int)) -> String {
        let isRed = piece.isUppercase
        let names: [Character: String] = [
            "R":"车", "N":"马", "B":"相", "A":"仕", "K":"帅", "C":"炮", "P":"兵",
            "r":"车", "n":"马", "b":"象", "a":"士", "k":"将", "c":"炮", "p":"卒"
        ]
        let name = names[piece] ?? String(piece)
        let sameFileRows = (0..<10).filter { state[$0][decoded.x1] == piece }
        let subject: String
        if sameFileRows.count >= 2 {
            let ordered = isRed ? sameFileRows.sorted() : sameFileRows.sorted(by: >)
            let position = ordered.firstIndex(of: decoded.y1) ?? 0
            if ordered.count == 2 {
                subject = (position == 0 ? "前" : "后") + name
            } else if ordered.count == 3 {
                subject = ["前", "中", "后"][min(position, 2)] + name
            } else {
                subject = "第\(position + 1)" + name
            }
        } else {
            subject = name + notationNumber(fileNumber(decoded.x1, red: isRed), red: isRed)
        }

        let rank1 = 9 - decoded.y1
        let rank2 = 9 - decoded.y2
        let forward = isRed ? rank2 > rank1 : rank2 < rank1
        let action = rank1 == rank2 ? "平" : (forward ? "进" : "退")
        let lowerPiece = String(piece).lowercased()
        let diagonalMover = lowerPiece == "n" || lowerPiece == "b" || lowerPiece == "a"
        let targetValue = action == "平" || diagonalMover
            ? fileNumber(decoded.x2, red: isRed)
            : abs(rank2 - rank1)
        return subject + action + notationNumber(targetValue, red: isRed)
    }

    private func fileNumber(_ x: Int, red: Bool) -> Int { red ? 9 - x : x + 1 }

    private func notationNumber(_ value: Int, red: Bool) -> String {
        if !red { return String(value) }
        let numerals = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        return (0..<numerals.count).contains(value) ? numerals[value] : String(value)
    }

    @objc private func beginLayoutMode() {
        guard !isLayoutMode else { return }
        layoutBackupPosition = boardView.positionSnapshot()
        if waitingForEngine {
            ignoreNextBestMove = true
            engine.stopSearch()
            engineSearchingInfinite = false
            restartSearchAfterDiscard = false
            switchingThinkMode = false
        }
        waitingForEngine = false
        isLayoutMode = true
        pausePredictionForLayoutOrGameEnd()
        pauseClock()
        boardView.beginLayout()
        layoutToolPopup.selectItem(at: 0)
        boardView.setLayoutTool(.move)
        layoutTurnSwitch.state = currentSideIsRed() ? .off : .on
        layoutPanel.isHidden = false
        layoutButton.isHidden = true
        statusLabel.stringValue = "正在布局"
        detailLabel.stringValue = "选择工具后点击棋盘；移动模式下先点棋子再点目标位置，右键可删除"
        subtitleLabel.stringValue = "中残局练习布局 · 可自由摆放棋子"
    }

    @objc private func layoutToolChanged() {
        let pieces: [Character] = [
            "R", "N", "B", "A", "K", "C", "P",
            "r", "n", "b", "a", "k", "c", "p"
        ]
        switch layoutToolPopup.indexOfSelectedItem {
        case 0:
            boardView.setLayoutTool(.move)
        case 1:
            boardView.setLayoutTool(.erase)
        default:
            let index = layoutToolPopup.indexOfSelectedItem - 2
            guard pieces.indices.contains(index) else { return }
            boardView.setLayoutTool(.place(pieces[index]))
        }
    }

    @objc private func useStandardLayout() {
        boardView.useStandardPosition()
        detailLabel.stringValue = "已恢复标准开局布局"
    }

    @objc private func clearLayout() {
        boardView.clearPosition()
        detailLabel.stringValue = "棋盘已清空，请从棋子菜单添加棋子"
    }

    @objc private func cancelLayoutMode() {
        guard isLayoutMode else { return }
        if let backup = layoutBackupPosition { boardView.setPosition(backup) }
        leaveLayoutInterface()
        detailLabel.stringValue = "已取消布局，恢复原局面"
        predictionPositionChanged()
        resumeCurrentTurn()
    }

    @objc private func finishLayoutMode() {
        guard isLayoutMode else { return }
        let position = boardView.positionSnapshot()
        if let error = validateLayout(position) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "布局不能开始对局"
            alert.informativeText = error
            alert.addButton(withTitle: "继续修改")
            alert.runModal()
            return
        }

        let redToMove = layoutTurnSwitch.state == .off
        let fen = makeFEN(position: position, redToMove: redToMove)
        guard engineAcceptsFEN(fen) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "该局面无法由引擎使用"
            alert.informativeText = "请检查是否存在被直接吃掉的将帅、被将军一方选择错误，或其他不符合象棋规则的位置。"
            alert.addButton(withTitle: "继续修改")
            alert.runModal()
            return
        }

        initialPosition = position
        initialSideIsRed = redToMove
        customBaseFEN = fen
        moves.removeAll()
        gameEnded = false
        historyView.string = ""
        resetClocks()
        boardView.setPosition(position)
        leaveLayoutInterface()
        engine.newGame()
        subtitleLabel.stringValue = "中残局练习 · \(initialSideIsRed ? "红方" : "黑方")走 · \(controllerSummary)"
        detailLabel.stringValue = "布局已锁定，新的着法记录从此局面开始"
        predictionPositionChanged()
        resumeCurrentTurn(delay: 0.15)
    }

    private func leaveLayoutInterface() {
        isLayoutMode = false
        layoutBackupPosition = nil
        boardView.endLayout()
        layoutPanel.isHidden = true
        layoutButton.isHidden = false
    }

    private func currentSideIsRed() -> Bool {
        moves.count.isMultiple(of: 2) ? initialSideIsRed : !initialSideIsRed
    }

    private func resumeCurrentTurn(delay: TimeInterval = 0) {
        let redToMove = currentSideIsRed()
        if !sideIsComputer(red: redToMove) {
            waitingForEngine = false
            boardView.setMovableSide(isRed: redToMove)
            boardView.acceptingMoves = true
            statusLabel.stringValue = "轮到\(redToMove ? "红方" : "黑方")玩家走棋"
            startClock(forRed: redToMove)
            return
        }

        waitingForEngine = true
        boardView.acceptingMoves = false
        statusLabel.stringValue = "\(redToMove ? "红方" : "黑方")电脑正在思考…"
        startClock(forRed: redToMove)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.waitingForEngine, !self.isLayoutMode else { return }
            self.beginComputerSearch()
        }
    }

    private func makeFEN(position: [[Character]], redToMove: Bool) -> String {
        let ranks = position.map { rank -> String in
            var result = ""
            var empty = 0
            for piece in rank {
                if piece == " " {
                    empty += 1
                } else {
                    if empty > 0 { result += String(empty); empty = 0 }
                    result.append(piece)
                }
            }
            if empty > 0 { result += String(empty) }
            return result
        }
        return ranks.joined(separator: "/") + (redToMove ? " w - - 0 1" : " b - - 0 1")
    }

    private func engineAcceptsFEN(_ fen: String) -> Bool {
        validatorAccepts(position: "fen \(fen)", moves: [])
    }

    private func engineAcceptsMove(_ move: String) -> Bool {
        let position = customBaseFEN.map { "fen \($0)" } ?? "startpos"
        return validatorAccepts(position: position, moves: moves + [move])
    }

    private func validatorAccepts(position: String, moves: [String]) -> Bool {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: enginePath)
        process.currentDirectoryURL = URL(fileURLWithPath: engineDirectory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let suffix = moves.isEmpty ? "" : " moves " + moves.joined(separator: " ")
            let commands = "uci\nposition \(position)\(suffix)\nisready\nquit\n"
            input.fileHandleForWriting.write(commands.data(using: .utf8)!)
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let response = String(data: data, encoding: .utf8) ?? ""
            return response.split(whereSeparator: { $0.isNewline }).contains("readyok")
        } catch {
            return false
        }
    }

    private func illegalMoveExplanation(_ move: String) -> String {
        guard let decoded = decodeMove(move) else { return "着法格式无效。" }
        let piece = boardView.positionSnapshot()[decoded.y1][decoded.x1]
        let common = "也可能是该着法没有应将、造成将帅照面，或让己方帅/将继续受攻击。"
        switch String(piece).lowercased() {
        case "r": return "车只能沿横线或竖线移动，且路径中不能有其他棋子。\(common)"
        case "n": return "马必须走“日”字；靠近起点的马腿位置不能被棋子阻挡。\(common)"
        case "b": return "相/象必须走“田”字，象眼不能被阻挡，并且不能过河。\(common)"
        case "a": return "仕/士只能在本方九宫内沿斜线走一格。\(common)"
        case "k": return "帅/将只能在九宫内走一格，并且双方不能直接照面。\(common)"
        case "c": return "炮平移时路径必须畅通；吃子时起点与目标之间必须恰好有一个炮架。\(common)"
        case "p": return piece.isUppercase
            ? "兵只能向前走一格；过河后可以左右走，不能后退。\(common)"
            : "卒只能向前走一格；过河后可以左右走，不能后退。\(common)"
        default: return "该着法不符合中国象棋规则。\(common)"
        }
    }

    private func validateLayout(_ position: [[Character]]) -> String? {
        let flat = position.flatMap { $0 }
        guard flat.filter({ $0 == "K" }).count == 1 else { return "红方必须恰好有一个帅。" }
        guard flat.filter({ $0 == "k" }).count == 1 else { return "黑方必须恰好有一个将。" }

        let limits: [Character: Int] = [
            "R":2, "N":2, "B":2, "A":2, "K":1, "C":2, "P":5,
            "r":2, "n":2, "b":2, "a":2, "k":1, "c":2, "p":5
        ]
        let names: [Character: String] = [
            "R":"红车", "N":"红马", "B":"红相", "A":"红仕", "K":"红帅", "C":"红炮", "P":"红兵",
            "r":"黑车", "n":"黑马", "b":"黑象", "a":"黑士", "k":"黑将", "c":"黑炮", "p":"黑卒"
        ]
        for (piece, maximum) in limits where flat.filter({ $0 == piece }).count > maximum {
            return "\(names[piece] ?? String(piece))最多只能放 \(maximum) 枚。"
        }

        func point(_ x: Int, _ y: Int) -> String { "\(x),\(y)" }
        let redKing = Set((7...9).flatMap { y in (3...5).map { point($0, y) } })
        let blackKing = Set((0...2).flatMap { y in (3...5).map { point($0, y) } })
        let redAdvisor = Set([point(3,9), point(5,9), point(4,8), point(3,7), point(5,7)])
        let blackAdvisor = Set([point(3,0), point(5,0), point(4,1), point(3,2), point(5,2)])
        let redBishop = Set([point(2,9), point(6,9), point(0,7), point(4,7), point(8,7), point(2,5), point(6,5)])
        let blackBishop = Set([point(2,0), point(6,0), point(0,2), point(4,2), point(8,2), point(2,4), point(6,4)])

        for y in 0..<10 {
            for x in 0..<9 {
                let square = point(x, y)
                switch position[y][x] {
                case "K" where !redKing.contains(square): return "红帅必须位于九宫内。"
                case "k" where !blackKing.contains(square): return "黑将必须位于九宫内。"
                case "A" where !redAdvisor.contains(square): return "红仕只能放在本方九宫的仕位。"
                case "a" where !blackAdvisor.contains(square): return "黑士只能放在本方九宫的士位。"
                case "B" where !redBishop.contains(square): return "红相只能放在本方合法相位。"
                case "b" where !blackBishop.contains(square): return "黑象只能放在本方合法象位。"
                default: break
                }
            }
        }

        guard let redY = position.firstIndex(where: { $0.contains("K") }),
              let redX = position[redY].firstIndex(of: "K"),
              let blackY = position.firstIndex(where: { $0.contains("k") }),
              let blackX = position[blackY].firstIndex(of: "k") else { return "缺少帅或将。" }
        if redX == blackX {
            let range = (min(redY, blackY) + 1)..<max(redY, blackY)
            if range.allSatisfy({ position[$0][redX] == " " }) { return "帅和将不能在同一路上直接照面。" }
        }
        return nil
    }

    @objc private func undoMove() {
        guard !isLayoutMode else {
            detailLabel.stringValue = "布局模式下请直接移动或删除棋子"
            return
        }
        guard !moves.isEmpty else {
            detailLabel.stringValue = "当前没有可以撤回的着法"
            return
        }

        if waitingForEngine {
            pauseClock()
            ignoreNextBestMove = true
            engine.stopSearch()
            engineSearchingInfinite = false
            restartSearchAfterDiscard = false
            switchingThinkMode = false
            moves.removeLast()
            waitingForEngine = false
        } else {
            pauseClock()
            let playerSides = [true, false].filter { !sideIsComputer(red: $0) }
            if playerSides.count == 1,
               let lastPlayerPly = moves.indices.last(where: { sideIsRed(forPly: $0) == playerSides[0] }) {
                moves.removeSubrange(lastPlayerPly...)
            } else {
                moves.removeLast()
            }
        }

        boardView.rebuild(from: initialPosition, moves: moves)
        gameEnded = false
        boardView.acceptingMoves = false
        updateHistory()
        detailLabel.stringValue = "局面已恢复"
        predictionPositionChanged()
        resumeCurrentTurn(delay: 0.18)
    }

    @objc private func undoAllMoves() {
        guard !isLayoutMode else {
            detailLabel.stringValue = "布局模式下还没有对局着法可撤回"
            return
        }
        guard !moves.isEmpty else {
            detailLabel.stringValue = "当前已经位于本局起点"
            return
        }

        pauseClock()
        if waitingForEngine {
            ignoreNextBestMove = true
            engine.stopSearch()
        }
        waitingForEngine = false
        engineSearchingInfinite = false
        restartSearchAfterDiscard = false
        switchingThinkMode = false
        moves.removeAll()
        boardView.rebuild(from: initialPosition, moves: moves)
        boardView.acceptingMoves = false
        gameEnded = false
        updateHistory()
        predictionPositionChanged()

        let redToMove = currentSideIsRed()
        statusLabel.stringValue = "已悔至本局起点"
        if sideIsComputer(red: redToMove) {
            detailLabel.stringValue = "全部着法已撤回，电脑暂停；可将当前方切换为玩家，或点击“新对局”重新开始"
        } else {
            boardView.setMovableSide(isRed: redToMove)
            boardView.acceptingMoves = true
            detailLabel.stringValue = "全部着法已撤回，\(redToMove ? "红方" : "黑方")玩家可从起始局面继续"
            startClock(forRed: redToMove)
        }
    }

    private func sideIsRed(forPly index: Int) -> Bool {
        index.isMultiple(of: 2) ? initialSideIsRed : !initialSideIsRed
    }

    @objc private func rotateBoard() {
        boardView.toggleRotation()
        detailLabel.stringValue = "棋盘已旋转，对局与着法记录保持不变"
    }

    private var redIsComputer: Bool { redControllerSwitch.state == .on }
    private var blackIsComputer: Bool { blackControllerSwitch.state == .on }
    private var redFastWinEnabled: Bool { redIsComputer && redFastWinSwitch.state == .on }
    private var blackFastWinEnabled: Bool { blackIsComputer && blackFastWinSwitch.state == .on }
    private func sideIsComputer(red: Bool) -> Bool { red ? redIsComputer : blackIsComputer }
    private var controllerSummary: String {
        "红方\(redIsComputer ? "电脑" : "玩家") · 黑方\(blackIsComputer ? "电脑" : "玩家")"
    }
    private var preferredViewFromRed: Bool {
        if redIsComputer && !blackIsComputer { return false }
        return true
    }

    private func updateFastWinAvailability() {
        redFastWinSwitch.isEnabled = redIsComputer
        blackFastWinSwitch.isEnabled = blackIsComputer
    }

    @objc private func fastWinModeChanged() {
        let redState = redFastWinEnabled ? "开启" : "关闭"
        let blackState = blackFastWinEnabled ? "开启" : "关闭"
        appendEngineLog("⚡ 快速取胜设置：红方\(redState) · 黑方\(blackState)")
        detailLabel.stringValue = "快速取胜设置已更新，将从对应电脑方的下一次搜索开始生效"
    }

    private func thinkTimeMilliseconds() -> Int {
        let input = timeCombo.stringValue.replacingOccurrences(of: ",", with: ".")
        let seconds = min(max(Double(input) ?? 1.0, 0.1), 600.0)
        return Int((seconds * 1000).rounded())
    }

    private var usesInfiniteThinkTime: Bool {
        timeCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == "无限分析"
    }

    private func beginComputerSearch() {
        guard waitingForEngine, !gameEnded else { return }
        let engineSideIsRed = currentSideIsRed()
        engine.configureFastWin(red: redFastWinEnabled, black: blackFastWinEnabled)
        if (engineSideIsRed && redFastWinEnabled) || (!engineSideIsRed && blackFastWinEnabled) {
            appendEngineLog("⚡ \(engineSideIsRed ? "红方" : "黑方")快速取胜策略已交给底层搜索")
        }
        if usesInfiniteThinkTime {
            engineSearchingInfinite = true
            statusLabel.stringValue = "Pikafish 无限分析中…"
            detailLabel.stringValue = "切换到任意秒数即可停止分析并按当前最佳着法落子"
            engine.analyzeInfinite(baseFEN: customBaseFEN, moves: moves, sideToMoveIsRed: engineSideIsRed)
        } else {
            engineSearchingInfinite = false
            engine.search(baseFEN: customBaseFEN, moves: moves, milliseconds: thinkTimeMilliseconds(), sideToMoveIsRed: engineSideIsRed)
        }
    }

    @objc private func thinkTimeChanged() {
        synchronizeThinkModeWithControl()
        predictionPositionChanged()
    }

    private func synchronizeThinkModeWithControl() {
        guard waitingForEngine, !isLayoutMode, !switchingThinkMode else { return }
        if engineSearchingInfinite && !usesInfiniteThinkTime {
            switchingThinkMode = true
            engineSearchingInfinite = false
            statusLabel.stringValue = "正在结束无限分析并落子…"
            engine.stopSearch()
        } else if !engineSearchingInfinite && usesInfiniteThinkTime {
            switchingThinkMode = true
            restartSearchAfterDiscard = true
            ignoreNextBestMove = true
            engine.stopSearch()
            statusLabel.stringValue = "正在切换为无限分析…"
        }
    }

    private func resetClocks() {
        pauseClock()
        redTimeElapsed = 0
        blackTimeElapsed = 0
        updateClockLabels()
    }

    private func startClock(forRed: Bool) {
        pauseClock()
        activeClockIsRed = forRed
        clockLastTick = Date()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.clockTick()
        }
        updateClockLabels()
    }

    private func pauseClock() {
        if activeClockIsRed != nil { clockTick() }
        activeClockIsRed = nil
        clockTimer?.invalidate()
        clockTimer = nil
        updateClockLabels()
    }

    private func clockTick() {
        guard let redActive = activeClockIsRed else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(clockLastTick))
        clockLastTick = now
        if redActive { redTimeElapsed += elapsed } else { blackTimeElapsed += elapsed }
        synchronizeThinkModeWithControl()
        updateClockLabels()
    }

    private func updateClockLabels() {
        let indicatedSide: Bool? = (gameEnded || isLayoutMode) ? nil : currentSideIsRed()
        redClockLabel.stringValue = "\(indicatedSide == true ? "▶ " : "")红方 \(formatClock(redTimeElapsed))"
        blackClockLabel.stringValue = "\(indicatedSide == false ? "▶ " : "")黑方 \(formatClock(blackTimeElapsed))"
        scoreboardView.updateTimes(
            red: formatClock(redTimeElapsed),
            black: formatClock(blackTimeElapsed),
            activeRed: indicatedSide
        )
    }

    private func formatClock(_ interval: TimeInterval) -> String {
        let totalTenths = max(0, Int((interval * 10).rounded(.down)))
        let hours = totalTenths / 36000
        let minutes = (totalTenths / 600) % 60
        let seconds = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    @objc private func sideControllerChanged() {
        updateFastWinAvailability()
        subtitleLabel.stringValue = customBaseFEN == nil
            ? controllerSummary
            : "中残局练习 · \(currentSideIsRed() ? "红方" : "黑方")走 · \(controllerSummary)"

        if isLayoutMode {
            statusLabel.stringValue = "正在布局"
            detailLabel.stringValue = "布局完成后：\(controllerSummary)"
            return
        }
        guard !gameEnded else {
            detailLabel.stringValue = "双方控制方式已更新；棋盘、着法和计时保持不变"
            return
        }

        let redToMove = currentSideIsRed()
        let computerTakesCurrentTurn = sideIsComputer(red: redToMove)
        if waitingForEngine {
            // Changing the controller of the side that is not moving must not disturb a live search.
            if computerTakesCurrentTurn {
                detailLabel.stringValue = "双方控制方式已更新；当前电脑继续思考"
                return
            }
            pauseClock()
            ignoreNextBestMove = true
            engine.stopSearch()
            engineSearchingInfinite = false
            restartSearchAfterDiscard = false
            switchingThinkMode = false
            waitingForEngine = false
            boardView.acceptingMoves = false
        }

        detailLabel.stringValue = "已在当前局面切换控制方；棋盘、着法和计时均未重置"
        resumeCurrentTurn(delay: computerTakesCurrentTurn ? 0.15 : 0)
    }

    @objc private func newGame() {
        if isLayoutMode { leaveLayoutInterface() }
        if waitingForEngine { ignoreNextBestMove = true }
        engineSearchingInfinite = false
        restartSearchAfterDiscard = false
        switchingThinkMode = false
        resetClocks()
        gameEnded = false
        moves.removeAll(); waitingForEngine = false; boardView.reset(); boardView.configure(viewedFromRed: preferredViewFromRed)
        initialPosition = boardView.positionSnapshot()
        initialSideIsRed = true
        customBaseFEN = nil
        historyView.string = ""; detailLabel.stringValue = "Pikafish 已就绪"
        subtitleLabel.stringValue = controllerSummary + (preferredViewFromRed ? "" : " · 棋盘已旋转")
        engine.newGame()
        predictionPositionChanged()
        resumeCurrentTurn(delay: 0.15)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { pauseClock(); engine.stop(); predictionEngine.stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

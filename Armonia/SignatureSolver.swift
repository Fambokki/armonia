import Foundation
import JavaScriptCore

/// Decifra le firme dei flussi audio "protetti" (client TV di YouTube), che servono per i video
/// che visionOS non riceve, per esempio i contenuti "destinati ai bambini".
///
/// Come fa yt-dlp: si scarica il player JavaScript di YouTube e lo si passa al solver ufficiale
/// di yt-dlp (progetto "ejs", in `Resources/armonia-ejs.js`), eseguito nel motore JavaScript di iOS.
/// Il solver si può aggiornare senza reinstallare l'app: all'avvio si prova a scaricare
/// `solver/armonia-ejs.js` dal repository GitHub.
actor SignatureSolver {
    static let shared = SignatureSolver()

    enum SolverError: LocalizedError {
        case noSolver, noPlayer, noTimestamp, failed(String)

        var errorDescription: String? {
            switch self {
            case .noSolver: return "solver JavaScript non disponibile"
            case .noPlayer: return "player di YouTube non trovato"
            case .noTimestamp: return "firma del player non trovata"
            case .failed(let m): return "decifratura non riuscita (\(m))"
            }
        }
    }

    private let remoteSolverURL = URL(string: "https://raw.githubusercontent.com/Fambokki/armonia/main/solver/armonia-ejs.js")!
    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private var context: JSContext?
    private var solverSource: String?
    private var remoteChecked = false

    private var playerId: String?
    private var playerIdDate = Date.distantPast
    private var playerCode: [String: String] = [:]          // id → codice del player
    private var preprocessed: [String: String] = [:]        // id → player già preparato dal solver
    private var timestamps: [String: Int] = [:]             // id → signatureTimestamp

    /// Da dove arriva il solver (per la diagnostica).
    private(set) var solverOrigin = "incluso nell'app"

    // MARK: - Player di YouTube

    /// Versione attuale del player (si ricontrolla ogni 6 ore).
    func currentPlayer() async throws -> (id: String, sts: Int) {
        if playerId == nil || Date().timeIntervalSince(playerIdDate) > 6 * 3600 {
            var req = URLRequest(url: URL(string: "https://www.youtube.com/iframe_api")!, timeoutInterval: 15)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let text = String(decoding: data, as: UTF8.self)
            guard let r = text.range(of: #"player\\?/([0-9a-fA-F]{8})\\?/"#, options: .regularExpression) else {
                throw SolverError.noPlayer
            }
            let match = String(text[r])
            playerId = match.replacingOccurrences(of: "\\", with: "")
                .replacingOccurrences(of: "player/", with: "")
                .replacingOccurrences(of: "/", with: "")
            playerIdDate = Date()
        }
        guard let id = playerId else { throw SolverError.noPlayer }
        let code = try await player(id)
        if timestamps[id] == nil {
            if let r = code.range(of: #"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#, options: .regularExpression) {
                let digits = code[r].filter(\.isNumber)
                timestamps[id] = Int(digits.suffix(5))
            }
        }
        guard let sts = timestamps[id] else { throw SolverError.noTimestamp }
        return (id, sts)
    }

    private func player(_ id: String) async throws -> String {
        if let c = playerCode[id] { return c }
        let file = URL.cachesDirectory.appendingPathComponent("player-\(id).js")
        if let c = try? String(contentsOf: file, encoding: .utf8), !c.isEmpty {
            playerCode[id] = c
            return c
        }
        let url = URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SolverError.noPlayer }
        let code = String(decoding: data, as: UTF8.self)
        try? code.write(to: file, atomically: true, encoding: .utf8)
        playerCode[id] = code
        return code
    }

    // MARK: - Solver

    private func loadSolver() async throws -> JSContext {
        if let context { return context }
        if !remoteChecked {
            remoteChecked = true
            var req = URLRequest(url: remoteSolverURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                let s = String(decoding: data, as: UTF8.self)
                if s.contains("armoniaSolve") {
                    solverSource = s
                    solverOrigin = "aggiornato da GitHub"
                }
            }
        }
        if solverSource == nil,
           let url = Bundle.main.url(forResource: "armonia-ejs", withExtension: "js"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            solverSource = s
            solverOrigin = "incluso nell'app"
        }
        guard let src = solverSource, let ctx = JSContext() else { throw SolverError.noSolver }
        var jsError: String?
        ctx.exceptionHandler = { _, value in jsError = value?.toString() }
        ctx.evaluateScript(src)
        if let jsError { throw SolverError.failed(jsError) }
        guard ctx.objectForKeyedSubscript("armoniaSolve")?.isUndefined == false else { throw SolverError.noSolver }
        context = ctx
        return ctx
    }

    /// Risolve le sfide "n" (velocità) e "sig" (firma) per il player indicato.
    func solve(playerId id: String, n: [String], sig: [String]) async throws -> (n: [String: String], sig: [String: String]) {
        if n.isEmpty && sig.isEmpty { return ([:], [:]) }
        let ctx = try await loadSolver()
        var input: [String: Any] = [
            "requests": [
                ["type": "n", "challenges": n],
                ["type": "sig", "challenges": sig]
            ]
        ]
        if let pre = preprocessed[id] {
            input["type"] = "preprocessed"
            input["preprocessed_player"] = pre
        } else {
            input["type"] = "player"
            input["player"] = try await player(id)
            input["output_preprocessed"] = true
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)

        var jsError: String?
        ctx.exceptionHandler = { _, value in jsError = value?.toString() }
        let result = ctx.objectForKeyedSubscript("armoniaSolve").call(withArguments: [json])?.toString()
        if let jsError { throw SolverError.failed(jsError) }
        guard let result, let out = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] else {
            throw SolverError.failed("risposta vuota")
        }
        if let pre = out["preprocessed_player"] as? String {
            preprocessed[id] = pre
            playerCode[id] = nil   // il codice originale non serve più: si libera memoria
        }
        var nOut: [String: String] = [:], sigOut: [String: String] = [:]
        let responses = (out["responses"] as? [[String: Any]]) ?? []
        for (i, r) in responses.enumerated() {
            if r["type"] as? String == "error" { throw SolverError.failed((r["error"] as? String)?.components(separatedBy: "\n").first ?? "?") }
            let data = (r["data"] as? [String: String]) ?? [:]
            if i == 0 { nOut = data } else { sigOut = data }
        }
        return (nOut, sigOut)
    }

    /// Breve descrizione per la diagnostica.
    func status() -> String {
        "solver \(solverOrigin)\(playerId.map { " · player \($0)" } ?? "")"
    }
}

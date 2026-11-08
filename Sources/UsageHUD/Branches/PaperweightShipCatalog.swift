import Foundation

/// Stable persisted choices shared by the 3D scene and the cached rail miniatures.
enum PaperweightShipKind: String, CaseIterable, Identifiable, Sendable {
    case goingMerry, thousandSunny, miniMerry, sharkSubmerge
    case oroJackson, mobyDick, redForce, saberOfXebec, blackbeardRaft, queenMamaChanter, bigTop, bigTopBlaster, mammoth, snapperHead, pieceOfSpadille, striker
    case polarTang, victoriaPunk, jewelryMargherita, grudgeDolph, liberalHind, stayTune, hanjomaru, nostraCastello
    case goingLuffySenpai, sleepingWhiteHorse, yontaMaria, naglfar, usoland
    case missLoveDuck, bezanBlack, dreadnaughtSabre, sharkSuperb, baratie
    case perfumeYuda, numanciaFlamingo, thrillerBark, hitsugibune, sexyFoxy, greatEirik, arkMaxim, onePieceFlyingDutchman, noah, windGranma
    case garpWarship, marineWarship, germa66
    case sailboat, liner, sub, galleon, ghost, victory, treasure, carrier, cartoon, viking, steamer, tug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goingMerry: "Going Merry"
        case .thousandSunny: "Thousand Sunny"
        case .miniMerry: "Mini Merry II"
        case .sharkSubmerge: "Shark Submerge III"
        case .oroJackson: "Oro Jackson"
        case .mobyDick: "Moby Dick"
        case .redForce: "Red Force"
        case .saberOfXebec: "Saber of Xebec"
        case .blackbeardRaft: "Blackbeard’s log raft"
        case .queenMamaChanter: "Queen Mama Chanter"
        case .bigTop: "Big Top"
        case .bigTopBlaster: "Big Top Blaster"
        case .mammoth: "Mammoth"
        case .snapperHead: "Snapper Head"
        case .pieceOfSpadille: "Piece of Spadille"
        case .striker: "Striker"
        case .polarTang: "Polar Tang"
        case .victoriaPunk: "Victoria Punk"
        case .jewelryMargherita: "Jewelry Margherita"
        case .grudgeDolph: "Grudge Dolph"
        case .liberalHind: "Liberal Hind"
        case .stayTune: "Stay Tune"
        case .hanjomaru: "Hanjomaru"
        case .nostraCastello: "Nostra Castello"
        case .goingLuffySenpai: "Going Luffy-senpai"
        case .sleepingWhiteHorse: "Sleeping White Horse of the Forest"
        case .yontaMaria: "Yonta Maria"
        case .naglfar: "Naglfar"
        case .usoland: "Usoland"
        case .missLoveDuck: "Miss Love Duck"
        case .bezanBlack: "Bezan Black"
        case .dreadnaughtSabre: "Dreadnaught Sabre"
        case .sharkSuperb: "Shark Superb"
        case .baratie: "Baratie"
        case .perfumeYuda: "Perfume Yuda"
        case .numanciaFlamingo: "Numancia Flamingo"
        case .thrillerBark: "Thriller Bark"
        case .hitsugibune: "Hitsugibune"
        case .sexyFoxy: "Sexy Foxy"
        case .greatEirik: "Great Eirik"
        case .arkMaxim: "Ark Maxim"
        case .onePieceFlyingDutchman: "Flying Dutchman · One Piece"
        case .noah: "Noah"
        case .windGranma: "Wind Granma"
        case .garpWarship: "Garp’s dog-head warship"
        case .marineWarship: "Marine battleship"
        case .germa66: "Germa 66 castle ship"
        case .sailboat: "Sailboat"
        case .liner: "Titanic"
        case .sub: "Submarine"
        case .galleon: "Pirate galleon"
        case .ghost: "Flying Dutchman"
        case .victory: "HMS Victory"
        case .treasure: "Zheng He treasure ship"
        case .carrier: "Aircraft carrier"
        case .cartoon: "Cartoon pirate ship"
        case .viking: "Viking longship"
        case .steamer: "Paddle steamer"
        case .tug: "Tugboat"
        }
    }

    var collection: PaperweightShipCollection {
        switch self {
        case .goingMerry, .thousandSunny, .miniMerry, .sharkSubmerge: .strawHats
        case .oroJackson, .mobyDick, .redForce, .saberOfXebec, .blackbeardRaft, .queenMamaChanter, .bigTop, .bigTopBlaster, .mammoth, .snapperHead, .pieceOfSpadille, .striker: .emperors
        case .polarTang, .victoriaPunk, .jewelryMargherita, .grudgeDolph, .liberalHind, .stayTune, .hanjomaru, .nostraCastello: .worstGeneration
        case .goingLuffySenpai, .sleepingWhiteHorse, .yontaMaria, .naglfar, .usoland: .grandFleet
        case .missLoveDuck, .bezanBlack, .dreadnaughtSabre, .sharkSuperb, .baratie: .eastBlue
        case .perfumeYuda, .numanciaFlamingo, .thrillerBark, .hitsugibune, .sexyFoxy, .greatEirik, .arkMaxim, .onePieceFlyingDutchman, .noah, .windGranma: .grandLine
        case .garpWarship, .marineWarship, .germa66: .navy
        case .sailboat, .liner, .sub, .galleon, .ghost, .victory, .treasure, .carrier, .cartoon, .viking, .steamer, .tug: .classics
        }
    }
}

enum PaperweightShipCollection: String, CaseIterable, Identifiable, Sendable {
    case strawHats, emperors, worstGeneration, grandFleet, eastBlue, grandLine, navy, classics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strawHats: "Straw Hats"
        case .emperors: "Emperors & legends"
        case .worstGeneration: "Worst Generation"
        case .grandFleet: "Straw Hat Grand Fleet"
        case .eastBlue: "East Blue"
        case .grandLine: "Grand Line & beyond"
        case .navy: "Navy & kingdoms"
        case .classics: "Classic ships"
        }
    }

    var ships: [PaperweightShipKind] {
        PaperweightShipKind.allCases.filter { $0.collection == self }
    }
}

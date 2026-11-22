import Foundation

/// A verified ESPN soccer scoreboard route. A route is only listed here after
/// returning a valid ESPN league payload; unsupported or rejected slugs stay
/// out of the working registry rather than producing fabricated competitions.
struct KyroSoccerCompetition: Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let region: String
    let gender: Gender

    enum Gender: String, Sendable {
        case men
        case women
        case mixed
    }

    var id: String { key }
}

enum KyroSoccerCompetitionRegistry {
    /// ESPN scoreboard routes verified on 2026-11-10. This is deliberately a
    /// data table: new routes can be added after a live probe without adding
    /// mapping code or new `KyroSportLeague` cases.
    static let verified: [KyroSoccerCompetition] = [
        // Europe
        .init(key: "eng.1", name: "English Premier League", region: "England", gender: .men),
        .init(key: "esp.1", name: "La Liga", region: "Spain", gender: .men),
        .init(key: "ger.1", name: "Bundesliga", region: "Germany", gender: .men),
        .init(key: "ita.1", name: "Serie A", region: "Italy", gender: .men),
        .init(key: "fra.1", name: "Ligue 1", region: "France", gender: .men),
        .init(key: "ned.1", name: "Eredivisie", region: "Netherlands", gender: .men),
        .init(key: "por.1", name: "Primeira Liga", region: "Portugal", gender: .men),
        .init(key: "sco.1", name: "Scottish Premiership", region: "Scotland", gender: .men),
        .init(key: "bel.1", name: "Belgian Pro League", region: "Belgium", gender: .men),
        .init(key: "tur.1", name: "Süper Lig", region: "Türkiye", gender: .men),
        .init(key: "aut.1", name: "Austrian Bundesliga", region: "Austria", gender: .men),
        .init(key: "gre.1", name: "Super League", region: "Greece", gender: .men),
        // Americas
        .init(key: "usa.1", name: "Major League Soccer", region: "United States / Canada", gender: .men),
        .init(key: "mex.1", name: "Liga MX", region: "Mexico", gender: .men),
        .init(key: "bra.1", name: "Brasileirão Série A", region: "Brazil", gender: .men),
        .init(key: "bra.2", name: "Brasileirão Série B", region: "Brazil", gender: .men),
        .init(key: "arg.1", name: "Liga Profesional", region: "Argentina", gender: .men),
        .init(key: "col.1", name: "Primera A", region: "Colombia", gender: .men),
        .init(key: "chi.1", name: "Primera División", region: "Chile", gender: .men),
        .init(key: "uru.1", name: "Primera División", region: "Uruguay", gender: .men),
        // Asia and Oceania
        .init(key: "jpn.1", name: "J1 League", region: "Japan", gender: .men),
        .init(key: "aus.1", name: "A-League Men", region: "Australia", gender: .men),
        .init(key: "chn.1", name: "Chinese Super League", region: "China", gender: .men),
        .init(key: "ind.1", name: "Indian Super League", region: "India", gender: .men),
        // Club and national competitions
        .init(key: "uefa.champions", name: "UEFA Champions League", region: "Europe", gender: .men),
        .init(key: "uefa.europa", name: "UEFA Europa League", region: "Europe", gender: .men),
        .init(key: "uefa.europa.conf", name: "UEFA Conference League", region: "Europe", gender: .men),
        .init(key: "uefa.super_cup", name: "UEFA Super Cup", region: "Europe", gender: .men),
        .init(key: "conmebol.libertadores", name: "Copa Libertadores", region: "South America", gender: .men),
        .init(key: "conmebol.sudamericana", name: "Copa Sudamericana", region: "South America", gender: .men),
        .init(key: "concacaf.champions_cup", name: "CONCACAF Champions Cup", region: "North and Central America", gender: .men),
        .init(key: "afc.champions", name: "AFC Champions League", region: "Asia", gender: .men),
        .init(key: "caf.champions", name: "CAF Champions League", region: "Africa", gender: .men),
        .init(key: "fifa.cwc", name: "FIFA Club World Cup", region: "World", gender: .men),
        .init(key: "uefa.euro", name: "UEFA European Championship", region: "Europe", gender: .men),
        .init(key: "conmebol.america", name: "Copa América", region: "South America", gender: .men),
        .init(key: "concacaf.gold", name: "CONCACAF Gold Cup", region: "North and Central America", gender: .men),
        .init(key: "caf.nations", name: "Africa Cup of Nations", region: "Africa", gender: .men),
        .init(key: "afc.asian.cup", name: "AFC Asian Cup", region: "Asia", gender: .men),
        // Women’s competitions
        .init(key: "usa.nwsl", name: "NWSL", region: "United States", gender: .women),
        .init(key: "eng.w.1", name: "Women’s Super League", region: "England", gender: .women),
        .init(key: "esp.w.1", name: "Liga F", region: "Spain", gender: .women),
        .init(key: "fra.w.1", name: "Division 1 Féminine", region: "France", gender: .women),
        .init(key: "fifa.wwc", name: "FIFA Women’s World Cup", region: "World", gender: .women),
        .init(key: "uefa.weuro", name: "UEFA Women’s Euro", region: "Europe", gender: .women)
    ]

    static func competition(for key: String?) -> KyroSoccerCompetition? {
        guard let key else { return nil }
        return verified.first { $0.key == key }
    }
}

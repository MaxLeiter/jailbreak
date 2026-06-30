import SwiftUI
import Combine
import CoreLocation

struct WeatherHour: Identifiable { let id = UUID(); let label: String; let temp: Double; let code: Int }
struct WeatherDay: Identifiable { let id = UUID(); let name: String; let code: Int; let lo: Double; let hi: Double }

/// Current conditions + hourly + 7-day, from Open-Meteo (no key) for the device
/// location. Drives the weather card and weather screen.
@MainActor
final class WeatherModel: ObservableObject {
    @Published var place = "—"
    @Published var temp: Double?
    @Published var apparent = 0.0
    @Published var code = 0
    @Published var isDay = true
    @Published var hi = 0.0
    @Published var lo = 0.0
    @Published var humidity = 0
    @Published var wind = 0.0
    @Published var hours: [WeatherHour] = []
    @Published var days: [WeatherDay] = []
    @Published var updated: Date?
    @Published var denied = false

    var symbol: String { WMO.symbol(code) }
    var condition: String { WMO.text(code) }

    private let loc = LocationManager()
    private var bag = Set<AnyCancellable>()
    private var refresh: AnyCancellable?

    func start() {
        loc.request()
        loc.$denied.receive(on: RunLoop.main).sink { [weak self] in self?.denied = $0 }.store(in: &bag)
        loc.$coordinate.compactMap { $0 }.removeDuplicates { a, b in
            abs(a.latitude - b.latitude) < 0.01 && abs(a.longitude - b.longitude) < 0.01
        }
        .sink { [weak self] c in Task { await self?.load(c) } }
        .store(in: &bag)

        if refresh == nil {
            refresh = Timer.publish(every: 900, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in if let c = self?.loc.coordinate { Task { await self?.load(c) } } }
        }
    }

    private func load(_ c: CLLocationCoordinate2D) async {
        await reverseGeocode(c)
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        var q: [URLQueryItem] = []
        q.append(URLQueryItem(name: "latitude", value: String(c.latitude)))
        q.append(URLQueryItem(name: "longitude", value: String(c.longitude)))
        q.append(URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"))
        q.append(URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"))
        q.append(URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"))
        q.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit"))
        q.append(URLQueryItem(name: "wind_speed_unit", value: "mph"))
        q.append(URLQueryItem(name: "timezone", value: "auto"))
        q.append(URLQueryItem(name: "forecast_days", value: "7"))
        comps.queryItems = q
        guard let url = comps.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(Response.self, from: data) else { return }

        temp = r.current.temperature_2m
        apparent = r.current.apparent_temperature
        code = r.current.weather_code
        isDay = r.current.is_day != 0
        humidity = Int(r.current.relative_humidity_2m.rounded())
        wind = r.current.wind_speed_10m
        hi = r.daily.temperature_2m_max.first ?? r.current.temperature_2m
        lo = r.daily.temperature_2m_min.first ?? r.current.temperature_2m
        updated = Date()

        // Next ~7 hours from "now"
        let hourFmt = DateFormatter(); hourFmt.dateFormat = "ha"
        let nowIdx = nearestHourIndex(r.hourly.time)
        var hrs: [WeatherHour] = []
        for k in stride(from: nowIdx, to: min(nowIdx + 7, r.hourly.time.count), by: 1) {
            let label = k == nowIdx ? "Now" : (parseISO(r.hourly.time[k]).map { hourFmt.string(from: $0) } ?? "")
            hrs.append(WeatherHour(label: label, temp: r.hourly.temperature_2m[k], code: r.hourly.weather_code[k]))
        }
        hours = hrs

        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEEE"
        var ds: [WeatherDay] = []
        for i in r.daily.time.indices {
            let iso = r.daily.time[i]
            let name = i == 0 ? "Today" : (parseISO(iso).map { dayFmt.string(from: $0) } ?? iso)
            ds.append(WeatherDay(name: name, code: r.daily.weather_code[i],
                                 lo: r.daily.temperature_2m_min[i], hi: r.daily.temperature_2m_max[i]))
        }
        days = ds
    }

    private func reverseGeocode(_ c: CLLocationCoordinate2D) async {
        let gc = CLGeocoder()
        if let p = try? await gc.reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)).first {
            place = p.locality ?? p.administrativeArea ?? "Here"
        }
    }

    private func nearestHourIndex(_ iso: [String]) -> Int {
        let now = Date()
        var best = 0, bestDiff = Double.greatestFiniteMagnitude
        for (i, s) in iso.enumerated() {
            if let d = parseISO(s) { let diff = abs(d.timeIntervalSince(now)); if diff < bestDiff { bestDiff = diff; best = i } }
        }
        return best
    }

    private let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm"; f.timeZone = .current; return f
    }()
    private func parseISO(_ s: String) -> Date? { isoFmt.date(from: s) }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double, apparent_temperature: Double, weather_code: Int
            let is_day: Int, relative_humidity_2m: Double, wind_speed_10m: Double
        }
        struct Hourly: Decodable { let time: [String]; let temperature_2m: [Double]; let weather_code: [Int] }
        struct Daily: Decodable { let time: [String]; let weather_code: [Int]; let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current; let hourly: Hourly; let daily: Daily
    }
}

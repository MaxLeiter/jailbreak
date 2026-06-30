import SwiftUI

struct CurrentWeather {
    let temp: Double
    let apparent: Double
    let code: Int
    let hi: Double
    let lo: Double
    let isDay: Bool
}

/// Fetches current conditions from Open-Meteo (no API key required).
enum WeatherService {
    static func fetch(lat: Double, lon: Double) async throws -> CurrentWeather {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let r = try JSONDecoder().decode(Response.self, from: data)
        return CurrentWeather(
            temp: r.current.temperature_2m,
            apparent: r.current.apparent_temperature,
            code: r.current.weather_code,
            hi: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
            lo: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
            isDay: r.current.is_day != 0
        )
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }
}

/// WMO weather-code → SF Symbol + human label.
enum WMO {
    static func symbol(_ code: Int) -> String {
        switch code {
        case 0:            return "sun.max.fill"
        case 1, 2:         return "cloud.sun.fill"
        case 3:            return "cloud.fill"
        case 45, 48:       return "cloud.fog.fill"
        case 51...57:      return "cloud.drizzle.fill"
        case 61...67:      return "cloud.rain.fill"
        case 71...77:      return "cloud.snow.fill"
        case 80...82:      return "cloud.heavyrain.fill"
        case 85, 86:       return "cloud.snow.fill"
        case 95...99:      return "cloud.bolt.rain.fill"
        default:           return "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0:            return "Clear"
        case 1:            return "Mainly clear"
        case 2:            return "Partly cloudy"
        case 3:            return "Overcast"
        case 45, 48:       return "Fog"
        case 51...57:      return "Drizzle"
        case 61...67:      return "Rain"
        case 71...77:      return "Snow"
        case 80...82:      return "Rain showers"
        case 85, 86:       return "Snow showers"
        case 95...99:      return "Thunderstorm"
        default:           return "—"
        }
    }
}

/// Sky-coloured gradient for the weather card, by condition + day/night.
enum Sky {
    static func gradient(code: Int, isDay: Bool) -> LinearGradient {
        let colors: [Color]
        if !isDay {
            switch code {
            case 0, 1:        colors = [hex(0x0B1437), hex(0x1C2B57)]   // clear night
            case 95...99:     colors = [hex(0x141225), hex(0x2A2740)]   // storm night
            default:          colors = [hex(0x141A2E), hex(0x2B3450)]   // cloudy night
            }
        } else {
            switch code {
            case 0, 1:        colors = [hex(0x2E72C9), hex(0x6FB4F2)]   // clear day
            case 2:           colors = [hex(0x3D6FA8), hex(0x7FA8D4)]   // partly
            case 3, 45, 48:   colors = [hex(0x4A5564), hex(0x77828F)]   // overcast/fog
            case 51...67, 80...82: colors = [hex(0x35506B), hex(0x5C7C88)]  // rain
            case 71...86:     colors = [hex(0x556074), hex(0x8C99AC)]   // snow
            case 95...99:     colors = [hex(0x2B3140), hex(0x4A5266)]   // storm day
            default:          colors = [hex(0x3D6FA8), hex(0x7FA8D4)]
            }
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private static func hex(_ v: Int) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}

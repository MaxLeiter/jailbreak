import Foundation

struct CurrentWeather {
    let temp: Double
    let apparent: Double
    let code: Int
    let hi: Double
    let lo: Double
}

/// Fetches current conditions from Open-Meteo (no API key required).
enum WeatherService {
    static func fetch(lat: Double, lon: Double) async throws -> CurrentWeather {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
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
            lo: r.daily.temperature_2m_min.first ?? r.current.temperature_2m
        )
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
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

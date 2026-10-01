import CoreLocation
import Foundation
import Observation

/// Current weather from Open-Meteo (free, no account). Uses the city you typed in Settings,
/// or — if you allow it — your approximate location, rounded to about 1 km before it's sent.
/// Fetched only when the dashboard opens, and at most every 15 minutes.
@Observable
final class WeatherService: NSObject {
    struct Weather: Equatable {
        let place: String
        let temperature: Double
        let high: Double
        let low: Double
        let code: Int
        let isDay: Bool
        let fahrenheit: Bool
        let fetched: Date
    }

    enum State: Equatable {
        case needsSetup
        case loading
        case ready(Weather)
        case failed(String)
    }

    private(set) var state: State = .needsSetup

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    @ObservationIgnored private var lastQuery: String?
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    private var useFahrenheit: Bool {
        switch settings.temperatureUnit {
        case .celsius: false
        case .fahrenheit: true
        case .automatic: Locale.current.measurementSystem == .us
        }
    }

    /// Called when the dashboard appears. Cheap if the weather is fresh.
    func refreshIfNeeded() async {
        let query = "\(settings.weatherUsesLocation)|\(settings.weatherCity)|\(useFahrenheit)"
        if case .ready(let w) = state, query == lastQuery, Date.now.timeIntervalSince(w.fetched) < 15 * 60 { return }
        guard settings.weatherUsesLocation || !settings.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .needsSetup
            return
        }
        if case .ready = state {} else { state = .loading }
        lastQuery = query
        do {
            let (coordinate, place) = try await resolvePlace()
            state = .ready(try await forecast(at: coordinate, place: place))
        } catch let error as WeatherError {
            state = .failed(error.message)
        } catch {
            state = .failed("Couldn't load the weather")
        }
    }

    // MARK: Place

    private struct WeatherError: Error { let message: String }

    private func resolvePlace() async throws -> (CLLocationCoordinate2D, String) {
        if settings.weatherUsesLocation {
            guard let coordinate = await currentLocation() else {
                throw WeatherError(message: "Location unavailable — allow it in System Settings, or type a city")
            }
            // About 1 km of precision is plenty for weather.
            let rounded = CLLocationCoordinate2D(
                latitude: (coordinate.latitude * 100).rounded() / 100,
                longitude: (coordinate.longitude * 100).rounded() / 100
            )
            return (rounded, "My Location")
        }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: settings.weatherCity),
            URLQueryItem(name: "count", value: "1"),
        ]
        struct Response: Decodable {
            struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
            let results: [Result]?
        }
        let (data, _) = try await session.data(from: components.url!)
        guard let first = try JSONDecoder().decode(Response.self, from: data).results?.first else {
            throw WeatherError(message: "Couldn't find \u{201C}\(settings.weatherCity)\u{201D}")
        }
        return (CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude), first.name)
    }

    private func currentLocation() async -> CLLocationCoordinate2D? {
        let manager = manager ?? CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finishLocation(nil)
            default: manager.requestLocation()
            }
        }
    }

    private func finishLocation(_ coordinate: CLLocationCoordinate2D?) {
        locationContinuation?.resume(returning: coordinate)
        locationContinuation = nil
    }

    // MARK: Forecast

    private func forecast(at coordinate: CLLocationCoordinate2D, place: String) async throws -> Weather {
        let fahrenheit = useFahrenheit
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        let (data, _) = try await session.data(from: components.url!)
        let r = try JSONDecoder().decode(Response.self, from: data)
        return Weather(
            place: place, temperature: r.current.temperature_2m,
            high: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
            low: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
            code: r.current.weather_code, isDay: r.current.is_day == 1, fahrenheit: fahrenheit, fetched: .now
        )
    }

    /// SF Symbol and words for a WMO weather code.
    static func describe(_ code: Int, isDay: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51...57: ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82: ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: ("cloud.snow.fill", "Snow")
        case 95...99: ("cloud.bolt.rain.fill", "Thunderstorm")
        default: ("cloud.fill", "—")
        }
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard locationContinuation != nil else { return }
            switch status {
            case .authorized, .authorizedAlways: self.manager?.requestLocation()
            case .denied, .restricted: finishLocation(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        MainActor.assumeIsolated { finishLocation(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finishLocation(nil) }
    }
}

#if DEBUG
import Foundation
import SwiftUI

enum KitchenScreenshotScenario: String {
    case standby
    case dashboard
    case timers
    case recipe

    static var current: KitchenScreenshotScenario? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--screenshot=") }
            .flatMap { KitchenScreenshotScenario(rawValue: String($0.dropFirst("--screenshot=".count))) }
    }
}

extension WeatherModel {
    func applyScreenshotFixture() {
        place = "San Francisco"
        temp = 68
        apparent = 67
        code = 1
        isDay = true
        hi = 72
        lo = 56
        humidity = 62
        wind = 9
        hours = [
            WeatherHour(label: "Now", temp: 68, code: 1),
            WeatherHour(label: "5PM", temp: 67, code: 2),
            WeatherHour(label: "6PM", temp: 65, code: 3),
            WeatherHour(label: "7PM", temp: 62, code: 0),
            WeatherHour(label: "8PM", temp: 60, code: 0),
        ]
        days = [
            WeatherDay(name: "Today", code: 1, lo: 56, hi: 72),
            WeatherDay(name: "Saturday", code: 0, lo: 55, hi: 74),
            WeatherDay(name: "Sunday", code: 2, lo: 57, hi: 70),
            WeatherDay(name: "Monday", code: 61, lo: 54, hi: 64),
        ]
        updated = Date()
    }
}

extension TimersModel {
    func applyScreenshotFixture() {
        items = [
            Item(name: "Pasta", duration: 600, remaining: 372, running: true,
                 endDate: Date().addingTimeInterval(372)),
            Item(name: "Roast", duration: 2700, remaining: 1960, running: true,
                 endDate: Date().addingTimeInterval(1960)),
            Item(name: "Tea", duration: 180, remaining: 0, running: false, finished: true),
        ]
        selectedID = items.first?.id
    }
}

extension RecipeModel {
    func applyScreenshotFixture() {
        let pasta = Recipe(
            title: "Lemon Basil Pasta",
            minutes: 25,
            difficulty: "Easy",
            baseServings: 4,
            ingredients: [
                Ingredient(name: "Spaghetti", amount: 400, unit: "g"),
                Ingredient(name: "Lemons", amount: 2, unit: ""),
                Ingredient(name: "Parmesan", amount: 80, unit: "g"),
                Ingredient(name: "Basil", amount: 1, unit: "bunch"),
                Ingredient(name: "Olive oil", amount: 3, unit: "tbsp"),
            ],
            steps: [
                RecipeStep(text: "Boil salted water and cook the pasta until just shy of al dente.",
                           timerLabel: "Pasta", timerMinutes: 10),
                RecipeStep(text: "Whisk lemon zest, juice, olive oil, and parmesan into a glossy sauce."),
                RecipeStep(text: "Toss pasta with sauce, basil, and reserved cooking water until silky."),
            ])
        let eggs = Recipe(
            title: "Soft Eggs",
            minutes: 8,
            difficulty: "Easy",
            baseServings: 2,
            ingredients: [
                Ingredient(name: "Eggs", amount: 4, unit: ""),
                Ingredient(name: "Toast", amount: 2, unit: "slices"),
            ],
            steps: [
                RecipeStep(text: "Simmer eggs gently, then chill briefly before peeling.",
                           timerLabel: "Eggs", timerMinutes: 6)
            ])
        recipes = [pasta, eggs]
        currentID = pasta.id
        servings = 6
        stepIndex = 1
        checked = Set(pasta.ingredients.prefix(2).map(\.id))
    }
}

extension SonosController {
    func applyScreenshotFixture() {
        status = .connected
        let room = SonosRoom(uuid: "RINCON_KITCHEN", name: "Kitchen", ip: "10.0.0.42")
        rooms = [room, SonosRoom(uuid: "RINCON_DINING", name: "Dining", ip: "10.0.0.43")]
        selectedUUID = room.uuid
        groupOf = [room.uuid: room.uuid, "RINCON_DINING": room.uuid]
        transport = "PLAYING"
        volume = 38
        now = NowPlaying(title: "Dear Maria, Count Me In",
                         artist: "All Time Low",
                         album: "So Wrong, It's Right",
                         artURL: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/a5/cc/81/a5cc812e-ee1d-4145-c588-b576476ea841/00602517403624.rgb.jpg/300x300bb.jpg"))
        position = 72
        duration = 196
        trackNo = 4
        queue = [
            SonosItem(id: "1", title: "Dear Maria, Count Me In", uri: "", metadata: "", artURL: now?.artURL, isContainer: false, artist: "All Time Low"),
            SonosItem(id: "2", title: "Sweetness", uri: "", metadata: "", artURL: nil, isContainer: false, artist: "Jimmy Eat World"),
            SonosItem(id: "3", title: "The Middle", uri: "", metadata: "", artURL: nil, isContainer: false, artist: "Jimmy Eat World"),
        ]
    }
}
#endif

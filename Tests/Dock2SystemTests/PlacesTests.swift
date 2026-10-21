import Dock2System
import Foundation
import Testing

@Suite struct PlacesTests {
    private let places = [
        Place(name: "Home", url: URL(fileURLWithPath: "/Users/me"), kind: .home),
        Place(name: "Downloads", url: URL(fileURLWithPath: "/Users/me/Downloads"), kind: .downloads),
        Place(name: "Macintosh HD", url: URL(fileURLWithPath: "/", isDirectory: true), kind: .volume(internal: true, local: true)),
    ]

    @Test func theNearestPlaceHoldsAFolder() {
        #expect(Place.holding(URL(fileURLWithPath: "/Users/me/Downloads/Chango"), in: places) == 1)
        #expect(Place.holding(URL(fileURLWithPath: "/Users/me/Downloads"), in: places) == 1)
        // Home over the disk it is on; a name that only starts like a place is not in it.
        #expect(Place.holding(URL(fileURLWithPath: "/Users/me/Developer"), in: places) == 0)
        #expect(Place.holding(URL(fileURLWithPath: "/Users/me/Downloads2"), in: places) == 0)
        #expect(Place.holding(URL(fileURLWithPath: "/usr/local"), in: places) == 2)
        #expect(Place.holding(URL(fileURLWithPath: "/usr"), in: []) == nil)
    }
}

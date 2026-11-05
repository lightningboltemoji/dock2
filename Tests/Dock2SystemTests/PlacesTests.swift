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
    @Test func aServerHoldsItsShares() {
        let address = URL(string: "smb://Synology._smb._tcp.local")!
        var server = Place(name: "Synology", url: address, kind: .server)
        server.shares = [URL(fileURLWithPath: "/Volumes/Media")]
        let places = self.places + [server, Place(name: "Network", url: Servers.network, kind: .network)]
        // The server over the disk its share is mounted on, and over its shares not mounted.
        #expect(Place.holding(URL(fileURLWithPath: "/Volumes/Media/Movies"), in: places) == 3)
        #expect(Place.holding(URL(string: "smb://Synology._smb._tcp.local/home")!, in: places) == 3)
        #expect(Place.holding(address, in: places) == 3)
        #expect(Place.holding(Servers.network, in: places) == 4)
        // A share's name is not the folder of that name on this disk.
        #expect(Place.holding(URL(fileURLWithPath: "/home"), in: places) == 2)
    }

    @Test func aPlaceStartsWhereItsFoldersDo() {
        func start(_ paths: String...) -> Int { Place.start(along: paths.map { URL(fileURLWithPath: $0) }, in: places) }
        #expect(start("/Users/me") == 0)
        #expect(start("/Users/me", "/Users/me/Developer", "/Users/me/Developer/dock2") == 0)
        #expect(start("/Users/me", "/Users/me/Downloads") == 1)
        #expect(start("/Users/me", "/Users/me/Downloads", "/Users/me/Downloads/Chango") == 1)
        #expect(start("/", "/usr", "/usr/local") == 0)
        // Any depth down from the root, past folders of other places.
        #expect(start("/", "/Users", "/Users/me", "/Users/me/Downloads", "/Users/me/Downloads/Chango") == 3)
        #expect(Place.start(along: [], in: places) == 0)
        #expect(Place.start(along: [URL(fileURLWithPath: "/usr"), URL(fileURLWithPath: "/usr/local")], in: []) == 0)
    }

    @Test func aServerStartsAheadOfItsShares() {
        let address = URL(string: "smb://Synology._smb._tcp.local")!
        var server = Place(name: "Synology", url: address, kind: .server)
        server.shares = [URL(fileURLWithPath: "/Volumes/Media")]
        let path = [address, URL(fileURLWithPath: "/Volumes/Media"), URL(fileURLWithPath: "/Volumes/Media/Movies")]
        #expect(Place.start(along: path, in: places + [server]) == 0)
    }
}

@Suite struct ServersTests {
    private let server = URL(string: "smb://Synology._smb._tcp.local")!

    @Test func aServerIsNamedAsFinderNamesIt() {
        #expect(Servers.name(of: server) == "Synology")
        #expect(Servers.name(of: URL(string: "smb://nas.lan")!) == "nas.lan")
        #expect(Servers.name(of: Servers.url(host: "Tanner's Mac._smb._tcp.local")) == "Tanner's Mac")
        #expect(Servers.name(of: Servers.network) == "Network")
    }

    @Test func aShareHasOneAddress() {
        let remount = URL(string: "smb://tanner@Synology._smb._tcp.local/Media")!
        #expect(Servers.server(of: remount) == server && Servers.url(host: "Synology._smb._tcp.local") == server)
        #expect(Servers.isServer(server) && !Servers.isShare(server))
        #expect(Servers.isShare(remount) && !Servers.isServer(remount))
        #expect(!Servers.isServer(URL(fileURLWithPath: "/Volumes/Media")) && Servers.server(of: URL(fileURLWithPath: "/Volumes")) == nil)
        // Who it is reached as is not part of the share.
        #expect(Servers.plain(remount) == Servers.address(of: "Media", on: server))
        #expect(Servers.address(of: "Time Machine", on: server, user: "tanner").absoluteString == "smb://tanner@Synology._smb._tcp.local/Time%20Machine")
        #expect(Servers.address(of: "Time Machine", on: server).lastPathComponent == "Time Machine")
        #expect(Servers.address(of: nil, on: server, user: "tanner").absoluteString == "smb://tanner@Synology._smb._tcp.local")
        #expect(server.appendingPathComponent("Time Machine") == Servers.address(of: "Time Machine", on: server))
    }

    @Test func networkIsAboveServersAndServersAboveShares() {
        #expect(Servers.parent(of: Servers.network) == nil)
        #expect(Servers.parent(of: server) == Servers.network)
        #expect(Servers.parent(of: Servers.address(of: "home", on: server)) == server)
        #expect(Servers.parent(of: URL(fileURLWithPath: "/")) == nil)
        #expect(Servers.parent(of: URL(fileURLWithPath: "/nowhere/deeper")) == URL(fileURLWithPath: "/nowhere"))
    }
}

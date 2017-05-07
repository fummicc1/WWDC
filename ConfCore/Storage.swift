//
//  Storage.swift
//  WWDC
//
//  Created by Guilherme Rambo on 17/03/17.
//  Copyright © 2017 Guilherme Rambo. All rights reserved.
//

import Foundation
import RealmSwift
import RxSwift
import RxRealm

public final class Storage {
    
    private let realmConfig: Realm.Configuration
    private let realm: Realm
    private var backgroundRealm: Realm!
    
    private let backgroundQueue = DispatchQueue(label: "Storage", qos: .userInitiated)
    
    public init(_ configuration: Realm.Configuration) throws {
        self.realmConfig = configuration
        self.realm = try Realm(configuration: configuration)
    }
    
    /// Performs a write transaction on the database using `block`
    public func update(with block: @escaping () -> Void) {
        do {
            try realm.write {
                block()
            }
        } catch {
            NSLog("Error performing realm write: \(error)")
        }
    }
    
    func store(sessionsResult: Result<SessionsResponse, APIError>, scheduleResult: Result<ScheduleResponse, APIError>, completion: @escaping () -> Void) {
        backgroundQueue.async {
            if self.backgroundRealm == nil {
                do {
                    self.backgroundRealm = try Realm(configuration: self.realmConfig)
                } catch {
                    fatalError("Error initializing background Realm: \(error)")
                }
            }
            
            if case let .error(sessionsError) = sessionsResult {
                print("Error downloading sessions: \(sessionsError)")
            }
            if case let .error(scheduleError) = scheduleResult {
                print("Error downloading schedule: \(scheduleError)")
            }
            
            guard case let .success(sessionsResponse) = sessionsResult, case let .success(scheduleResponse) = scheduleResult else {
                return
            }
            
            self.backgroundRealm.beginWrite()
            
            // Merge existing session data, preserving user-defined data
            let consolidatedSessions = sessionsResponse.sessions.map { newSession -> (Session) in
                if let existingSession = self.backgroundRealm.object(ofType: Session.self, forPrimaryKey: newSession.identifier) {
                    existingSession.merge(with: newSession, in: self.backgroundRealm)
                    
                    return existingSession
                } else {
                    return newSession
                }
            }

            // Associate sessions with events
            sessionsResponse.events.forEach { event in
                let sessions = consolidatedSessions.filter({ $0.eventIdentifier == event.identifier })
                
                event.sessions.append(objectsIn: sessions)
            }
            
            // Associate assets with sessions
            consolidatedSessions.forEach { session in
                let components = session.identifier.components(separatedBy: "-")
                guard components.count == 2 else { return }
                guard let year = Int(components[0]) else { return }
                
                session.assets.removeAll()
                
                // Merge assets, preserving user-defined data
                let assets = sessionsResponse.assets.filter({ $0.year == year && $0.sessionId == components[1] }).map { newAsset -> (SessionAsset) in
                    if let existingAsset = self.backgroundRealm.object(ofType: SessionAsset.self, forPrimaryKey: newAsset.remoteURL) {
                        existingAsset.merge(with: newAsset, in: self.backgroundRealm)
                        
                        return existingAsset
                    } else {
                        return newAsset
                    }
                }
                
                session.assets.append(objectsIn: assets)
            }
            

            // Merge existing instance data, preserving user-defined data
            let consolidatedInstances = scheduleResponse.instances.map { newInstance -> (SessionInstance) in
                if let existingInstance = self.backgroundRealm.object(ofType: SessionInstance.self, forPrimaryKey: newInstance.identifier) {
                    existingInstance.merge(with: newInstance, in: self.backgroundRealm)
                    
                    return existingInstance
                } else {
                    return newInstance
                }
            }
            
            // Associate rooms with session instances
            scheduleResponse.rooms.forEach { room in
                let instances = consolidatedInstances.filter({ $0.roomName == room.name })
                
                room.instances.removeAll()
                room.instances.append(objectsIn: instances)
            }
            
            // Save everything
            self.backgroundRealm.add(scheduleResponse.rooms, update: true)
            self.backgroundRealm.add(scheduleResponse.tracks, update: true)
            self.backgroundRealm.add(sessionsResponse.events, update: true)
            
            // Associate instances with events
            consolidatedInstances.forEach { instance in
                guard let session = instance.session else { return }
                
                guard let event = self.backgroundRealm.objects(Session.self).filter({ $0.identifier == session.identifier && $0.number == session.number }).first?.event.first else {
                    return
                }
                event.sessionInstances.removeAll()
                
                event.sessionInstances.append(instance)
            }
            
            // Add sessions and session instances to tracks
            scheduleResponse.tracks.forEach { track in
                track.sessions.removeAll()
                track.instances.removeAll()
                
                track.sessions.append(objectsIn: consolidatedSessions.filter({ $0.trackName == track.name }))
                track.instances.append(objectsIn: consolidatedInstances.filter({ $0.trackName == track.name }))
            }
            
            do {
                try self.backgroundRealm.commitWrite()
                
                DispatchQueue.main.async {
                    _ = self.realm.refresh()
                    
                    completion()
                }
            } catch {
                NSLog("Realm error: \(error)")
            }
        }
    }
    
    public lazy var events: Observable<Results<Event>> = {
        let eventsSortedByDateDescending = self.realm.objects(Event.self).sorted(byKeyPath: "startDate", ascending: false)
        
        return Observable.collection(from: eventsSortedByDateDescending)
    }()
    
    public lazy var sessionsObservable: Observable<Results<Session>> = {
        return Observable.collection(from: self.realm.objects(Session.self))
    }()
    
    public var sessions: Results<Session> {
        return self.realm.objects(Session.self).filter("assets.@count > 0")
    }
    
    public func session(with identifier: String) -> Session? {
        return realm.object(ofType: Session.self, forPrimaryKey: identifier)
    }
    
    public func createFavorite(for session: Session) {
        do {
            try realm.write {
                session.favorites.append(Favorite())
            }
        } catch {
            NSLog("Error creating favorite for session \(session)")
        }
    }
    
    public func removeFavorite(for session: Session) {
        guard let favorite = session.favorites.first else { return }
        
        do {
            try realm.write {
                realm.delete(favorite)
            }
        } catch {
            NSLog("Error creating favorite for session \(session)")
        }
    }
    
    public lazy var activeDownloads: Observable<Results<Download>> = {
        let results = self.realm.objects(Download.self).filter("rawStatus != %@ AND rawStatus != %@", "none", "deleted")
        
        return Observable.collection(from: results)
    }()
    
    public func createDownload(for asset: SessionAsset) {
        // prevent multiple download instances per session asset
        guard asset.downloads.filter({ $0.status != .deleted && $0.status != .none }).count == 0 else { return }
        
        do {
            try realm.write {
                let download = Download()
                download.status = .paused
                asset.downloads.append(download)
            }
        } catch {
            NSLog("Error creating download for asset \(asset): \(error)")
        }
    }
    
    public func asset(with remoteURL: URL) -> SessionAsset? {
        return realm.objects(SessionAsset.self).filter("remoteURL == %@", remoteURL.absoluteString).first
    }
    
    public func download(for session: Session) -> Observable<Download?> {
        let download = session.assets.filter("rawType == %@", SessionAssetType.hdVideo.rawValue).first?.downloads.first
        
        return Observable.from(optional: download)
    }
    
}

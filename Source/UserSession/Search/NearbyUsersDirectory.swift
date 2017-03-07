//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import CoreData
import ZMCDataModel
import ZMTransport
import MultipeerConnectivity

@objc
public protocol NearbyUsersDirectoryDelegate : class {
    
    func nearbyUsersDirectoryDidUpdate()
    
}

@objc(ZMNearbyUsersDirectory)
public class NearbyUsersDirectory : NSObject {
    
    public weak var delegate : NearbyUsersDirectoryDelegate?
    
    fileprivate let userSession : ZMUserSession
    fileprivate let managedObjectContext : NSManagedObjectContext
    fileprivate let syncManagedObjectContext : NSManagedObjectContext
    fileprivate var serviceAdvertiser : MCNearbyServiceAdvertiser?
    fileprivate var serviceBrowser : MCNearbyServiceBrowser?
    
    var searchUsers : Dictionary<UUID, ZMSearchUser> = Dictionary()
    var nearbyPeers : Dictionary<MCPeerID, UUID> = Dictionary()
    
    public init(userSession : ZMUserSession) {
        self.userSession = userSession
        self.managedObjectContext = userSession.managedObjectContext
        self.syncManagedObjectContext = userSession.syncManagedObjectContext
    }
    
    public func startLookingForNearbyUsers() {
        createServiceAdvertiseIfNecessary()
        
        serviceBrowser?.startBrowsingForPeers()
        serviceAdvertiser?.startAdvertisingPeer()
    }
    
    public func stopLookingForNearbyUsers() {
        serviceBrowser?.stopBrowsingForPeers()
        serviceAdvertiser?.startAdvertisingPeer()
    }
    
    private func createServiceAdvertiseIfNecessary() {
        guard serviceAdvertiser == nil, serviceBrowser == nil else { return }
        
        let selfUser = ZMUser.selfUser(in: managedObjectContext)
        let peerID = MCPeerID(displayName: selfUser.displayName ??  "Unknown")
        
        let discoveryInfo = [
            "remoteIdentifier" : selfUser.remoteIdentifier?.transportString() ?? ""
        ]
        
        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: discoveryInfo, serviceType: "wire-find-user")
        serviceBrowser =  MCNearbyServiceBrowser(peer: peerID, serviceType: "wire-find-user")
        
        serviceAdvertiser?.delegate = self
        serviceBrowser?.delegate = self
    }
    
    fileprivate func fetchUser(withRemoteIdentifier remoteIdentifier: UUID, completion: @escaping (_ user : ZMSearchUser?) -> Void) {
        let request = ZMTransportRequest(getFromPath: "/users/\(remoteIdentifier.transportString())")
        
        request.add(ZMCompletionHandler(on: managedObjectContext, block: { (response) in
            
            guard let payload = response.payload?.asDictionary() else { return completion(nil) }
            
            let searchUser = ZMSearchUser(payload: payload, userSession: self.userSession)
            
            completion(searchUser)
        }))
        
        userSession.transportSession.enqueueSearch(request)
    }
    
    public var nearbyUsers : [ZMSearchUser] {
        return nearbyPeers.values.flatMap({ searchUsers[$0] })
    }

}

extension NearbyUsersDirectory : MCNearbyServiceBrowserDelegate {
    
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("found peer: \(peerID) with info: \(info)")
        
        guard let uuidString = info?["remoteIdentifier"], let remoteIdentifier = UUID(uuidString: uuidString) else {
            return
        }
        
        managedObjectContext.performGroupedBlock {
            self.nearbyPeers[peerID] = remoteIdentifier
            
            self.fetchUser(withRemoteIdentifier: remoteIdentifier, completion: { [weak self] (searchUser) in
                if let searchUser = searchUser {
                    self?.searchUsers[remoteIdentifier] = searchUser
                    self?.delegate?.nearbyUsersDirectoryDidUpdate()
                }
            })
        }
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("lost peer: \(peerID)")
        
        managedObjectContext.performGroupedBlock {
            if let remoteIdentifier = self.nearbyPeers.removeValue(forKey: peerID) {
                self.searchUsers.removeValue(forKey: remoteIdentifier)
            }
        }
    }
    
    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("did not start browing: \(error)")
    }
    
}

extension NearbyUsersDirectory : MCNearbyServiceAdvertiserDelegate {
    
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("did not start advertisng: \(error)")
    }
    
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(false, nil)
    }
    
}

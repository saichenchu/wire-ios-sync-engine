//
//  WireCallCenterV3+Notifications.swift
//  zmessaging-cocoa
//
//  Created by Sabine Geithner on 14/03/17.
//  Copyright © 2017 Zeta Project Gmbh. All rights reserved.
//

import Foundation


protocol SelfPostingNotification {
    static var notificationName : Notification.Name { get }
}

extension SelfPostingNotification {
    static var userInfoKey : String { return notificationName.rawValue }
    
    func post() {
        NotificationCenter.default.post(name: type(of:self).notificationName,
                                        object: nil,
                                        userInfo: [type(of:self).userInfoKey : self])
    }
}

/// MARK - Video call observer

public typealias WireCallCenterObserverToken = NSObjectProtocol

struct WireCallCenterV3VideoNotification : SelfPostingNotification {
    static let notificationName = Notification.Name("WireCallCenterVideoNotification")
    
    let receivedVideoState : ReceivedVideoState
    
    init(receivedVideoState: ReceivedVideoState) {
        self.receivedVideoState = receivedVideoState
    }

}

/// MARK - Call state observer

public protocol WireCallCenterCallStateObserver : class {
    func callCenterDidChange(callState: CallState, conversationId: UUID, userId: UUID?)
}

public struct WireCallCenterCallStateNotification : SelfPostingNotification {
    static let notificationName = Notification.Name("WireCallCenterNotification")
    
    let callState : CallState
    let conversationId : UUID
    let userId : UUID?
}

/// MARK - Missed call observer

public protocol WireCallCenterMissedCallObserver : class {
    func callCenterMissedCall(conversationId: UUID, userId: UUID, timestamp: Date, video: Bool)
}

struct WireCallCenterMissedCallNotification : SelfPostingNotification {
    static let notificationName = Notification.Name("WireCallCenterNotification")
    
    let conversationId : UUID
    let userId : UUID
    let timestamp: Date
    let video: Bool
}

/// MARK - ConferenceParticipantsObserver
protocol WireCallCenterConferenceParticipantsObserver : class {
    func callCenterConferenceParticipantsChanged(conversationId: UUID, userIds: [UUID])
}

struct WireCallCenterConferenceParticipantsChangedNotification : SelfPostingNotification {
    static let notificationName = Notification.Name("WireCallCenterNotification")
    
    let conversationId : UUID
    let userId : UUID
    let timestamp: Date
    let video: Bool
}


extension WireCallCenterV3 {
    
    // MARK - Observer
    
    /// Register observer of the call center call state. This will inform you when there's an incoming call etc.
    /// Returns a token which needs to unregistered with `removeObserver(token:)` to stop observing.
    public class func addCallStateObserver(observer: WireCallCenterCallStateObserver) -> WireCallCenterObserverToken  {
        return NotificationCenter.default.addObserver(forName: WireCallCenterCallStateNotification.notificationName, object: nil, queue: .main) { [weak observer] (note) in
            if let note = note.userInfo?[WireCallCenterCallStateNotification.userInfoKey] as? WireCallCenterCallStateNotification {
                observer?.callCenterDidChange(callState: note.callState, conversationId: note.conversationId, userId: note.userId)
            }
        }
    }
    
    /// Register observer of missed calls.
    /// Returns a token which needs to unregistered with `removeObserver(token:)` to stop observing.
    public class func addMissedCallObserver(observer: WireCallCenterMissedCallObserver) -> WireCallCenterObserverToken  {
        return NotificationCenter.default.addObserver(forName: WireCallCenterMissedCallNotification.notificationName, object: nil, queue: .main) { [weak observer] (note) in
            if let note = note.userInfo?[WireCallCenterMissedCallNotification.userInfoKey] as? WireCallCenterMissedCallNotification {
                observer?.callCenterMissedCall(conversationId: note.conversationId, userId: note.userId, timestamp: note.timestamp, video: note.video)
            }
        }
    }
    
    /// Register observer of the video state. This will inform you when the remote caller starts, stops sending video.
    /// Returns a token which needs to unregistered with `removeObserver(token:)` to stop observing.
    public class func addReceivedVideoObserver(observer: ReceivedVideoObserver) -> WireCallCenterObserverToken {
        return NotificationCenter.default.addObserver(forName: WireCallCenterV3VideoNotification.notificationName, object: nil, queue: .main) { [weak observer] (note) in
            if let note = note.userInfo?[WireCallCenterV3VideoNotification.userInfoKey] as? WireCallCenterV3VideoNotification {
                observer?.callCenterDidChange(receivedVideoState: note.receivedVideoState)
            }
        }
    }
    
    public class func removeObserver(token: WireCallCenterObserverToken) {
        NotificationCenter.default.removeObserver(token)
    }
    
}


class VoiceChannelParticipantV3Snapshot {
    
    fileprivate var state : SetSnapshot
    public private(set) var activeFlowParticipantsState : [UUID]
    public private(set) var callParticipantState : [UUID]
    
    fileprivate let conversationId : UUID
    fileprivate let selfUserID : UUID
    
    init(conversationId: UUID, selfUserID: UUID) {
        self.conversationId = conversationId
        self.selfUserID = selfUserID
        guard let callCenter = WireCallCenterV3.activeInstance else {
            fatal("WireCallCenterV3 not accessible")
        }
        
        activeFlowParticipantsState = callCenter.activeFlowParticipants(in: conversationId).filter{$0 != selfUserID}
        callParticipantState = callCenter.activeParticipants(in: conversationId).filter{$0 != selfUserID}
        state = SetSnapshot(set: NSOrderedSet(array: callParticipantState), moveType: .uiCollectionView)
        notifyInitialChange()
    }
    
    func notifyInitialChange(){
        let changedIndexes = ZMChangedIndexes(start: ZMOrderedSetState(orderedSet: NSOrderedSet()),
                                              end: ZMOrderedSetState(orderedSet: NSOrderedSet(array: callParticipantState)),
                                              updatedState: ZMOrderedSetState(orderedSet: NSOrderedSet()))!
        let changeInfo = SetChangeInfo(observedObject: conversationId as NSUUID,
                                       changeSet: changedIndexes)
        VoiceChannelParticipantNotification(setChangeInfo: changeInfo, conversationId: conversationId).post()
    }
    
    /// participants who have an updated flow, but are still in the voiceChannel
    func activeFlowParticipantsChanged(newParticipants: [UUID]) {
        let filteredNew = newParticipants.filter{$0 != selfUserID}
        if activeFlowParticipantsState == filteredNew { return }
        
        let newConnected =  filteredNew.filter{!activeFlowParticipantsState.contains($0)}
        let newDisconnected = activeFlowParticipantsState.filter{!filteredNew.contains($0)}
        
        activeFlowParticipantsState = filteredNew
        recalculateSet(updated: newConnected + newDisconnected)
    }
    
    /// participants who left or joined the voiceChannel / call
    func callParticipantsChanged(newParticipants: [UUID]) {
        let filteredNew = newParticipants.filter{$0 != selfUserID}
        if callParticipantState == filteredNew { return }
        
        callParticipantState = filteredNew
        recalculateSet(updated: [])
    }
    
    /// calculate inserts / deletes / moves
    func recalculateSet(updated: [UUID]) {
        guard let newStateUpdate = state.updatedState(NSOrderedSet(array: updated),
                                                      observedObject: conversationId as NSUUID,
                                                      newSet: NSOrderedSet(array: callParticipantState))
        else { return}
        
        state = newStateUpdate.newSnapshot
        VoiceChannelParticipantNotification(setChangeInfo: newStateUpdate.changeInfo, conversationId: conversationId).post()
        
    }
}

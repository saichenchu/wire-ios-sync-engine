/*
 * Wire
 * Copyright (C) 2016 Wire Swiss GmbH
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import avs

private extension String {
    
    init?(cString: UnsafePointer<Int8>?) {
        if let cString = cString {
            self.init(cString: cString)
        } else {
            return nil
        }
    }
    
}

private extension UUID {
    
    init?(uuidString: String?) {
        if let uuidString = uuidString {
            self.init(uuidString: uuidString)
        } else {
            return nil
        }
    }
    
    init?(cString: UnsafePointer<Int8>?) {
        if let aString = String(cString: cString){
            self.init(uuidString: aString)
        }
        return nil
    }

}

private class Box<T : Any> {
    var value : T
    
    init(value: T) {
        self.value = value
    }
}

public enum CallClosedReason : Int32 {
    /// Ongoing call was closed by remote or self user
    case normal
    /// Call was closed because of internal error in AVS
    case internalError
    /// Call was closed due to a input/output error (couldn't access microphone)
    case inputOutputError
    /// Outgoing call timed out
    case timeout
    /// Ongoing call lost media and was closed
    case lostMedia
    /// Incoming call was canceled by remote
    case canceled
    /// Incoming call was answered on another device
    case anweredElsewhere
    /// Call was closed for an unknown reason. This is most likely a bug.
    case unknown
    
    init(reason: Int32) {
        switch reason {
        case WCALL_REASON_NORMAL:
            self = .normal
        case WCALL_REASON_CANCELED:
            self = .canceled
        case WCALL_REASON_ANSWERED_ELSEWHERE:
            self = .anweredElsewhere
        case WCALL_REASON_TIMEOUT:
            self = .timeout
        case WCALL_REASON_LOST_MEDIA:
            self = .lostMedia
        case WCALL_REASON_ERROR:
            self = .internalError
        case WCALL_REASON_IO_ERROR:
            self = .inputOutputError
        default:
            self = .unknown
        }
    }
}

private let zmLog = ZMSLog(tag: "calling")

public enum CallState : Equatable {
    
    /// There's no call
    case none
    /// Outgoing call is pending
    case outgoing
    /// Incoming call is pending
    case incoming(video: Bool, shouldRing: Bool)
    /// Call is answered
    case answered
    /// Call is established (media is flowing)
    case established
    /// Call in process of being terminated
    case terminating(reason: CallClosedReason)
    /// Unknown call state
    case unknown
    
    public static func ==(lhs: CallState, rhs: CallState) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            fallthrough
        case (.outgoing, .outgoing):
            fallthrough
        case (.incoming, .incoming):
            fallthrough
        case (.answered, .answered):
            fallthrough
        case (.established, .established):
            fallthrough
        case (.terminating, .terminating):
            fallthrough
        case (.unknown, .unknown):
            return true
        default:
            return false
        }
    }
    
    init(wcallState: Int32) {
        switch wcallState {
        case WCALL_STATE_NONE:
            self = .none
        case WCALL_STATE_INCOMING:
            self = .incoming(video: false, shouldRing: false)
        case WCALL_STATE_OUTGOING:
            self = .outgoing
        case WCALL_STATE_ANSWERED:
            self = .answered
        case WCALL_STATE_MEDIA_ESTAB:
            self = .established
        case WCALL_STATE_TERM_LOCAL: fallthrough
        case WCALL_STATE_TERM_REMOTE:
            self = .terminating(reason: .unknown)
        default:
            self = .none // FIXME check with AVS when WCALL_STATE_UNKNOWN can happen
        }
    }
    
    func postNotificationOnMain(conversationID: UUID, userID: UUID?){
        DispatchQueue.main.async {
            WireCallCenterCallStateNotification(callState: self,
                                                conversationId: conversationID,
                                                userId: userID).post()
        }
    }
    
    func logState(){
        switch self {
        case .answered:
            zmLog.debug("answered call")
        case .incoming(video: let isVideo, shouldRing: let shouldRing):
            zmLog.debug("incoming call, isVideo: \(isVideo), shouldRing: \(shouldRing)")
        case .established:
            zmLog.debug("established call")
        case .outgoing:
            zmLog.debug("outgoing call")
        case .terminating(reason: let reason):
            zmLog.debug("terminating call reason: \(reason)")
        case .none:
            zmLog.debug("no call")
        case .unknown:
            zmLog.debug("unknown call state")
        }
    }
}


/// MARK - Call center transport

@objc
public protocol WireCallCenterTransport: class {
    func send(data: Data, conversationId: UUID, userId: UUID, completionHandler: @escaping ((_ status: Int) -> Void))
}

private typealias WireCallMessageToken = UnsafeMutableRawPointer


/// MARK - C convention functions

    /// Handles incoming calls
    private func IncomingCallHandler(conversationId: UnsafePointer<Int8>?, userId: UnsafePointer<Int8>?, isVideoCall: Int32, shouldRing: Int32, contextRef: UnsafeMutableRawPointer?)
    {
        guard let contextRef = contextRef, let convID = UUID(cString: conversationId), let userID = UUID(cString: userId) else { return }
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callState.notifyObservers(callState: .incoming(video: isVideoCall != 0, shouldRing: shouldRing != 0),
                                  conversationID: convID,
                                  userID: nil)
    }

    /// Handles missed calls
    private func MissedCallHandler(conversationId: UnsafePointer<Int8>?, messageTime: UInt32, userId: UnsafePointer<Int8>?, isVideoCall: Int32, contextRef: UnsafeMutableRawPointer?)
    {
        guard let contextRef = contextRef, let convID = UUID(cString: conversationId), let userID = UUID(cString: userId) else { return }
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callCenter.missed(conversationId: convID,
                          userId: userID,
                          timestamp: Date(timeIntervalSince1970: TimeInterval(messageTime)),
                          isVideoCall: (isVideoCall != 0))
    }

    /// Handles answered calls
    private func AnsweredCallHandler(conversationId: UnsafePointer<Int8>?, contextRef: UnsafeMutableRawPointer?){
        guard let contextRef = contextRef, let convID = UUID(cString: conversationId) else { return }
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callState.notifyObservers(callState: .terminating(reason: CallClosedReason(reason: reason)),
                                  conversationID: convID,
                                  userID: nil)
    }

    /// Handles established calls
    private func EstablishedCallHandler(conversationId: UnsafePointer<Int8>?, userId: UnsafePointer<Int8>?,contextRef: UnsafeMutableRawPointer?)
    {
        guard let contextRef = contextRef, let convID = UUID(cString: conversationId), let userID = UUID(cString: userId) else { return }
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callState.notifyObservers(callState: .established, conversationID: convID, userID: nil)
    }

    /// Handles ended calls
    private func ClosedCallHandler(reason:Int32, conversationId: UnsafePointer<Int8>?, userId: UnsafePointer<Int8>?, metrics:UnsafePointer<Int8>?, contextRef: UnsafeMutableRawPointer?)
    {
        guard let contextRef = contextRef, let convID = UUID(cString: conversationId) else { return }
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callState.notifyObservers(callState: .terminating(reason: CallClosedReason(reason: reason)),
                                  conversationID: convID,
                                  userID: UUID(cString: userId))
    }

    /// Handles sending call messages
    private func SendCallHandler(token: UnsafeMutableRawPointer?, conversationId: UnsafePointer<Int8>?, userId: UnsafePointer<Int8>?, clientId: UnsafePointer<Int8>?, data: UnsafePointer<UInt8>?, dataLength: Int, contextRef: UnsafeMutableRawPointer?) -> Int32
    {
        guard let token = token, let contextRef = contextRef, let conversationId = conversationId, let userId = userId, let clientId = clientId, let data = data else {
            return EINVAL // invalid argument
        }
        
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        return callCenter.send(token: token,
                               conversationId: String.init(cString: conversationId),
                               userId: String(cString: userId),
                               clientId: String(cString: clientId),
                               data: data,
                               dataLength: dataLength)
    }

    /// Sets the calling protocol when AVS is ready
    private func ReadyHandler(version: Int32, contextRef: UnsafeMutableRawPointer?){
        guard let contextRef = contextRef else { return }
        
        if let callingProtocol = CallingProtocol(rawValue: Int(version)) {
            let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
            callCenter.callingProtocol = callingProtocol
        } else {
            zmLog.error("wcall initialized with unknown protocol version: \(version)")
        }
    }

    /// Handles users establishing the flow
    private func ActiveFlowParticipantsHandler(conversationIdRef: UnsafePointer<Int8>?, participantCount: Int32, userIdRef: UnsafePointer<uuid_t>?, contextRef: UnsafeMutableRawPointer?){
        guard let contextRef = contextRef, let convID = UUID(cString: conversationIdRef) else { return }
        var userIds = [UUID]()
        for i in 0..<participantCount {
            guard let uuidRef = userIdRef?[Int(i)] else { return }
            userIds.append(UUID(uuid: uuidRef))
        }
        // TODO Sabine release reference
        
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callCenter.activeFlowParticipantsChanged(conversationId: convID, participants: userIds)
    }


    /// Handles users joining the call
    private func CallParticipantsHandler(conversationIdRef: UnsafePointer<Int8>?, participantCount: Int32, userIdRef: UnsafePointer<uuid_t>?, contextRef: UnsafeMutableRawPointer?){
        guard let contextRef = contextRef, let convID = UUID(cString: conversationIdRef) else { return }
        var userIds = [UUID]()
        for i in 0..<participantCount {
            guard let uuidRef = userIdRef?[Int(i)] else { return }
            userIds.append(UUID(uuid: uuidRef))
        }
        // TODO Sabine release reference
        
        let callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(contextRef).takeUnretainedValue()
        callCenter.callParticipantsChanged(conversationId: convID, participants: userIds)
    }


/// MARK - WireCallCenterV3

/**
 * WireCallCenter is used for making wire calls and observing their state. There can only be one instance of the WireCallCenter. You should instantiate WireCallCenter once a keep a strong reference to it, other consumers can access this instance via the `activeInstance` property.
 * Thread safety: WireCallCenter instance methods should only be called from the main thread, class method can be called from any thread.
 */
@objc public class WireCallCenterV3 : NSObject {
    
    /// The selfUser remoteIdentifier
    fileprivate let userId : UUID
    
    /// activeInstance - Currenly active instance of the WireCallCenter.
    public private(set) static weak var activeInstance : WireCallCenterV3?
    
    /// establishedDate - Date of when the call was established (Participants can talk to each other). This property is only valid when the call state is .established.
    public private(set) var establishedDate : Date?
    
    public weak var transport : WireCallCenterTransport? = nil
    
    public fileprivate(set) var callingProtocol : CallingProtocol = .version2
    
    /// We keep a snapshot of all participants so that we can notify the UI when a user is connected or when the stereo sorting changes
    fileprivate var participantSnapshots : [UUID : VoiceChannelParticipantV3Snapshot] = [:]

    deinit {
        wcall_close()
    }
    
    public required init(userId: UUID, clientId: String, registerObservers : Bool = true) {
        self.userId = userId
        super.init()
        
        if WireCallCenterV3.activeInstance != nil {
            fatal("Only one WireCallCenter can be instantiated")
        }
        
        if (registerObservers) {
            let observer = Unmanaged.passUnretained(self).toOpaque()
            
            let resultValue = wcall_init(
                userId.transportString(),
                clientId,
                ReadyHandler,
                SendCallHandler,
                IncomingCallHandler,
                MissedCallHandler,
                AnsweredCallHandler,
                EstablishedCallHandler,
                ClosedCallHandler,
                observer)
            
            if resultValue != 0 {
                fatal("Failed to initialise WireCallCenter")
            }
            
            wcall_set_video_state_handler({ (state, _) in
                guard let state = ReceivedVideoState(rawValue: UInt(state)) else { return }
                
                DispatchQueue.main.async {
                    WireCallCenterV3VideoNotification(receivedVideoState: state).post()
                }
            })
        }
        
        WireCallCenterV3.activeInstance = self
    }
    
    private func send(token: WireCallMessageToken, conversationId: String, userId: String, clientId: String, data: UnsafePointer<UInt8>, dataLength: Int) -> Int32 {
        
        let bytes = UnsafeBufferPointer<UInt8>(start: data, count: dataLength)
        let transformedData = Data(buffer: bytes)
        
        transport?.send(data: transformedData, conversationId: UUID(uuidString: conversationId)!, userId: UUID(uuidString: userId)!, completionHandler: { status in
            wcall_resp(Int32(status), "", token)
        })
        
        return 0
    }
    
    fileprivate func notifyObservers(callState: CallState, conversationId: UUID, userId: UUID) {
        callState.logState()
        switch callState {
        case .established:
            established(conversationId: conversationId, userId: userId)
        default:
            callState.postNotificationOnMain(conversationID: conversationId, userID: userId)
        }
    }
    
    fileprivate func missed(conversationId: UUID, userId: UUID, timestamp: Date, isVideoCall: Bool) {
        zmLog.debug("missed call")
        
        DispatchQueue.main.async {
            WireCallCenterMissedCallNotification(conversationId: conversationId, userId:userId, timestamp: timestamp, video: isVideoCall).post()
        }
    }
    
    fileprivate func established(conversationId: String, userId: String) {
        zmLog.debug("established call")
        
        if wcall_is_video_call(conversationId) == 1 {
            wcall_set_video_send_active(conversationId, 1)
        }
        
        DispatchQueue.main.async {
            self.establishedDate = Date()
            
            WireCallCenterCallStateNotification(callState: .established, conversationId: UUID(uuidString: conversationId)!, userId: UUID(uuidString: userId)!).post()
        }
    }
    
    public func received(data: Data, currentTimestamp: Date, serverTimestamp: Date, conversationId: UUID, userId: UUID, clientId: String) {
        data.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) in
            let currentTime = UInt32(currentTimestamp.timeIntervalSince1970)
            let serverTime = UInt32(serverTimestamp.timeIntervalSince1970)
            
            wcall_recv_msg(bytes, data.count, currentTime, serverTime, conversationId.transportString(), userId.transportString(), clientId)
        }
    }
}



// MARK - Call state methods

extension WireCallCenterV3 {
    
    @objc(answerCallForConversationID:isGroup:)
    public func answerCall(conversationId: UUID, isGroup: Bool) -> Bool {
        let answered = wcall_answer(conversationId.transportString(), isGroup ? 1 : 0) == 0
        
        if answered {
            WireCallCenterCallStateNotification(callState: .answered, conversationId: conversationId, userId: self.userId).post()
        }
        return answered
    }
    
    @objc(startCallForConversationID:video:isGroup:)
    public func startCall(conversationId: UUID, video: Bool, isGroup: Bool) -> Bool {
        let started = wcall_start(conversationId.transportString(), video ? 1 : 0, (isGroup ? 1 : 0)) == 0
        
        if started {
            WireCallCenterCallStateNotification(callState: .outgoing, conversationId: conversationId, userId: userId).post()
        }
        return started
    }
    
    @objc(closeCallForConversationID:isGroup:)
    public func closeCall(conversationId: UUID, isGroup: Bool) {
        wcall_end(conversationId.transportString(), isGroup ? 1 : 0)
    }
    
    @objc(rejectCallForConversationID:isGroup:)
    public func rejectCall(conversationId: UUID, isGroup: Bool) {
        wcall_reject(conversationId.transportString(), isGroup ? 1 : 0)
        WireCallCenterCallStateNotification(callState: .terminating(reason: .canceled), conversationId: conversationId, userId: userId).post()
    }
    
    @objc(toogleVideoForConversationID:isActive:)
    public func toogleVideo(conversationID: UUID, active: Bool) {
        wcall_set_video_send_active(conversationID.transportString(), active ? 1 : 0)
    }
    
    @objc(isVideoCallForConversationID:)
    public class func isVideoCall(conversationId: UUID) -> Bool {
        return wcall_is_video_call(conversationId.transportString()) == 1 ? true : false
    }
    
    /// nonIdleCalls maps all non idle conversations to their corresponding call state
    public class var nonIdleCalls : [UUID : CallState] {
        
        typealias CallStateDictionary = [UUID : CallState]
        
        let box = Box<CallStateDictionary>(value: [:])
        let pointer = Unmanaged<Box<CallStateDictionary>>.passUnretained(box).toOpaque()
        
        wcall_iterate_state({ (conversationId, state, pointer) in
            guard let conversationId = conversationId, let pointer = pointer else { return }
            guard let uuid = UUID(uuidString: String(cString: conversationId)) else { return }
            
            let box = Unmanaged<Box<CallStateDictionary>>.fromOpaque(pointer).takeUnretainedValue()
            box.value[uuid] = CallState(wcallState: state)
        }, pointer)
        
        return box.value
    }
 
    public func callState(conversationId: UUID) -> CallState {
        return CallState(wcallState: wcall_get_state(conversationId.transportString()))
    }
}


// MARK - WireCallCenterV3 - Call Participants

extension WireCallCenterV3 {
    
    /// Call this method when the flowParticipants changed and avs calls the handler `wcall_group_changed_h`
    fileprivate func activeFlowParticipantsChanged(conversationId: UUID, participants: [UUID]) {
        if let snapshot = participantSnapshots[conversationId] {
            snapshot.activeFlowParticipantsChanged(newParticipants: participants)
        } else {
            participantSnapshots[conversationId] = VoiceChannelParticipantV3Snapshot(conversationId: conversationId, selfUserID: userId)
        }
    }
    
    // TODO Sabine: Update comment
    /// Call this method when the call participants changed and avs calls the handler `wcall_group_changed_h`
    fileprivate func callParticipantsChanged(conversationId: UUID, participants: [UUID]) {
        if let snapshot = participantSnapshots[conversationId] {
            snapshot.callParticipantsChanged(newParticipants: participants)
        } else {
            participantSnapshots[conversationId] = VoiceChannelParticipantV3Snapshot(conversationId: conversationId, selfUserID: userId)
        }
    }

    /// Calls `wcall_get_group` on avs to get the current activeFlowParticipants
    public func activeFlowParticipants(in conversationId: UUID) -> [UUID] {
//        let (uuidsRef, count) = wcall_get_group(conversationId.transportString())
//        var userIds = [UUID]()
//        for i in 0..<count {
//            guard let uuidRef = uuidsRef?[Int(i)] else { return }
//            userIds.append(UUID(uuid: uuidRef))
//        }
//        return userIds
        return []
    }
    
    // TODO Sabine: Update comment
    /// Calls `wcall_get_group` on avs to get the current activeFlowParticipants
    public func activeParticipants(in conversationId: UUID) -> [UUID] {
//        let (uuidsRef, count) = wcall_get_group(conversationId.transportString())
//        var userIds = [UUID]()
//        for i in 0..<count {
//            guard let uuidRef = uuidsRef?[Int(i)] else { return }
//            userIds.append(UUID(uuid: uuidRef))
//        }
//        return userIds
        return []
    }
    
    /// Returns the connectionState of a user in a conversation
    /// We keep a snapshot of the callParticipants and activeFlowParticipants
    /// If the user is contained in the callParticipants and in the activeFlowParticipants, he is connected
    /// If the user is only contained in the callParticipants, he is connecting
    /// Otherwise he is notConnected
    public func connectionState(forUserWith userId: UUID, in conversationId: UUID) -> VoiceChannelV2ConnectionState {
        guard let snapshot = participantSnapshots[conversationId] else { return .invalid }
        let isJoined = snapshot.callParticipantState.contains(userId)
        let isFlowActive = snapshot.activeFlowParticipantsState.contains(userId)

        switch (isJoined, isFlowActive) {
        case (false, _):    return .notConnected
        case (true, true):  return .connected
        case (true, false): return .connecting
        }
    }
}

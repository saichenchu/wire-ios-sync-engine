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

public protocol AVSWrapperType {
    init(userId: UUID, clientId: String, observer: UnsafeMutableRawPointer?)
    func getCallState(conversationId: UUID) -> CallState
    func startCall(conversationId: UUID, video: Bool, isGroup: Bool) -> Bool
    func answerCall(conversationId: UUID, isGroup: Bool) -> Bool
    func endCall(conversationId: UUID, isGroup: Bool)
    func rejectCall(conversationId: UUID, isGroup: Bool)
    func close()
    func received(data: Data, currentTimestamp: Date, serverTimestamp: Date, conversationId: UUID, userId: UUID, clientId: String)
    func toggleVideo(conversationID: UUID, active: Bool) 
}

/// Wraps AVS calls for dependency injection and better testing
public class AVSWrapper : AVSWrapperType {
    
    required public init(userId: UUID, clientId: String, observer: UnsafeMutableRawPointer?) {
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
            fatal("Failed to initialise AVS")
        }
        
        wcall_set_video_state_handler({ (state, _) in
            guard let state = ReceivedVideoState(rawValue: UInt(state)) else { return }
            
            DispatchQueue.main.async {
                WireCallCenterV3VideoNotification(receivedVideoState: state).post()
            }
        })
        
        wcall_set_group_changed_handler(GroupMemberHandler, observer)
    }
    
    public func getCallState(conversationId: UUID) -> CallState {
        return CallState(wcallState:wcall_get_state(conversationId.transportString()))
    }
    
    public func startCall(conversationId: UUID, video: Bool, isGroup: Bool) -> Bool {
        return wcall_start(conversationId.transportString(), video ? 1 : 0, (isGroup ? 1 : 0)) == 0
    }
    
    public func answerCall(conversationId: UUID, isGroup: Bool) -> Bool {
        return wcall_answer(conversationId.transportString(), isGroup ? 1 : 0) == 0
    }
    
    public func endCall(conversationId: UUID, isGroup: Bool) {
        wcall_end(conversationId.transportString(), isGroup ? 1 : 0)
    }
    
    public func rejectCall(conversationId: UUID, isGroup: Bool) {
        wcall_reject(conversationId.transportString(), isGroup ? 1 : 0)
    }
    
    public func close(){
        wcall_close()
    }
    
    public func received(data: Data, currentTimestamp: Date, serverTimestamp: Date, conversationId: UUID, userId: UUID, clientId: String) {
        data.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) in
            let currentTime = UInt32(currentTimestamp.timeIntervalSince1970)
            let serverTime = UInt32(serverTimestamp.timeIntervalSince1970)
            
            wcall_recv_msg(bytes, data.count, currentTime, serverTime, conversationId.transportString(), userId.transportString(), clientId)
        }
    }
    
    public func toggleVideo(conversationID: UUID, active: Bool) {
        wcall_set_video_send_active(conversationID.transportString(), active ? 1 : 0)
    }
}

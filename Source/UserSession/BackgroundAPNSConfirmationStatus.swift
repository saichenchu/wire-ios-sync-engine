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

import UIKit

@objc open class BackgroundAPNSConfirmationStatus : NSObject {
    
    /// Switch for sending delivery receipts
    public static let sendDeliveryReceipts : Bool = true
    static let backgroundNameBase : String = "Sending confirmation message with nonce"
    
    let backgroundTime : TimeInterval = 25
    private var tornDown = false
    private var messageNonces : [UUID : ZMBackgroundActivity] = [:]
    private unowned var application : Application
    private unowned var managedObjectContext : NSManagedObjectContext
    private unowned var backgroundActivityFactory : BackgroundActivityFactory

    open var needsToSyncMessages : Bool {
        return messageNonces.count > 0 && application.applicationState == .background
    }
    
    @objc public init(application: Application,
                      managedObjectContext: NSManagedObjectContext,
                      backgroundActivityFactory: BackgroundActivityFactory) {
        self.application = application
        self.managedObjectContext = managedObjectContext
        self.backgroundActivityFactory = backgroundActivityFactory
        
        super.init()
    }

    public func tearDown(){
        messageNonces.values.forEach{$0.end()}
        messageNonces.removeAll()
        tornDown = true
    }
    
    deinit {
        assert(tornDown, "Needs to tear down BackgroundAPNSConfirmationStatus")
    }
    
    // Called after a confirmation message has been created from an event received via APNS
    public func needsToConfirmMessage(_ messageNonce: UUID) {
        let backgroundTask = backgroundActivityFactory.backgroundActivity(withName: "\(BackgroundAPNSConfirmationStatus.backgroundNameBase) \(messageNonce.transportString())") { [weak self] in
            guard let strongSelf = self else { return }
            // The message failed to send in time. We won't continue trying.
            strongSelf.managedObjectContext.performGroupedBlock{
                strongSelf.messageNonces.removeValue(forKey: messageNonce)
            }
        }
        managedObjectContext.performGroupedBlock{
            self.messageNonces[messageNonce] = backgroundTask
        }
    }
    
    // Called after a confirmation message has made the round-trip to the backend and was successfully sent
    public func didConfirmMessage(_ messageNonce: UUID) {
        managedObjectContext.performGroupedBlock{
            guard let task = self.messageNonces.removeValue(forKey: messageNonce) else { return }
            task.end()
        }
    }
}


//
//  MooltipassBleDelegate.swift
//  MooltipassBle
//
//  Created by Kai Dederichs on 12.04.22.
//

import Foundation
import CoreBluetooth

public protocol MooltipassBleDelegate : AnyObject {
    func bluetoothChange(state: CBManagerState)-> Void
    func onError(errorMessage: String) -> Void
    func lockedStatus(locked: Bool) -> Void
    func credentialsReceived(username: String, password: String) -> Void
    func mooltipassConnected() -> Void
}

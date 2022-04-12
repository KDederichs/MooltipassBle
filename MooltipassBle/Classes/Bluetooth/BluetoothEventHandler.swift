//
// Created by Kai Dederichs on 23.02.22.
//

import Foundation
import CoreBluetooth

extension MooltipassBleManager: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }

        print("services discovered")
        for service in services {
            let serviceUuid = service.uuid.uuidString
            print("discovered service: \(serviceUuid)")

            if serviceUuid == self.commServiceUUID.uuidString {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        print("characteristics discovered")
        for characteristic in characteristics {
            let characteristicUuid = characteristic.uuid.uuidString
            print("discovered characteristic: \(characteristicUuid) | read=\(characteristic.properties.contains(.read)) | write=\(characteristic.properties.contains(.write))")
            if characteristicUuid == self.charWriteUUID.uuidString {
                peripheral.setNotifyValue(true, for: characteristic)

                self.writeCharacteristic = characteristic
                writeConnected = true
            }

            if characteristicUuid == self.charReadUUID.uuidString {
                peripheral.setNotifyValue(true, for: characteristic)

                self.readCharacteristic = characteristic
                readConnected = true
            }
            if (readConnected && writeConnected) {
                self.delegate?.mooltipassConnected()
                if (connectedCallback != nil) {
                    connectedCallback!()
                    connectedCallback = nil
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value {
            handleFlush(data: data)
            //print("didUpdateValueFor \(characteristic.uuid.uuidString) = count: \(data.count) | \(self.hexEncodedString(data))")
            let id = Int(data[1]) >> 4
            if (currentId == id) {
                if (nil == expectedPacketCount && 0 == id) {
                    expectedPacketCount = Int((data[1] % 16) + 1)
                }
                print("Reading package \(id + 1) of \(expectedPacketCount) (current ID is \(currentId))")
                debugPrint(hexEncodedString(data))
                
                if (readResult == nil) {
                    readResult = [Data](repeating: Data([0]), count: expectedPacketCount!)
                }
                
                readResult![currentId] = data
                if (currentId == expectedPacketCount! - 1) {
                    handleResult()
                    resetState()
                } else {
                    currentId += 1
                    releaseSemaphore()
                    startRead()
                }
            } else {
                debugPrint("Received ID \(id) doesn't match with current ID counter \(currentId)")
                resetState()
                releaseSemaphore()
            }

        } else {
            print("didUpdateValueFor \(characteristic.uuid.uuidString) with no data")
            releaseSemaphore()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            print("error while writing value to \(characteristic.uuid.uuidString): \(error.debugDescription)")
        } else {
            print("didWriteValueFor \(characteristic.uuid.uuidString)")
            startRead()
        }
    }

    private func hexEncodedString(_ data: Data?) -> String {
        let format = "0x%02hhX "
        return data?.map { String(format: format, $0) }.joined() ?? ""
    }

    private func handleResult() {
        let factory = BleMessageFactory()
        let message = factory.deserialize(data: readResult!)
        if (message == nil) {
            debugPrint("Result could not be parsed!")
            resetState()
            releaseSemaphore()
            return
        }

        switch (message!.cmd) {
        case .MOOLTIPASS_STATUS_BLE:
            deviceLocked = tryParseLocked(message: message!)
            self.delegate?.lockedStatus(locked: (deviceLocked == true))
            resetState()
            break
        case .GET_CREDENTIAL_BLE:
            if (message?.data != nil && message!.data!.count > 0) {
                //debugPrint(hexEncodedString(message!.data!))
                //debugPrint("Login \(parseCredentialsPart(idx: 0, data: message!.data!))")
//                debugPrint("Description \(parseCredentialsPart(idx: 2, data: message!.data!))")
//                debugPrint("Third \(parseCredentialsPart(idx: 4, data: message!.data!))")
                //debugPrint("Password \(parseCredentialsPart(idx: 6, data: message!.data!))")
                let username = parseCredentialsPart(idx: 0, data: message!.data!)
                let password = parseCredentialsPart(idx: 6, data: message!.data!)
                if (username != nil && password != nil) {
                    self.delegate?.credentialsReceived(username: username!, password: password!)
                } else {
                    self.delegate?.onError(errorMessage: "Error decoding credentials")
                }
            }
            resetState()
            break
        case .PLEASE_RETRY_BLE:
            if (retryCount < 5) {
                debugPrint("Retrying operation")
                retryCount += 1
                flushRead(completion: flushCompleteHandler)
            } else {
                resetState()
                self.delegate?.onError(errorMessage: "Could not read from Mooltipass")
            }
            break
        default:
            resetState()
            break
        }
        releaseSemaphore()
    }

    private func parseCredentialsPart(idx: Int, data: Data) -> String? {
        print("Idx \(idx)")
        print("UInt16 \(BleMessageFactory.toUInt16(bytes: data, index: idx + data.startIndex))")
        let offset = Int(BleMessageFactory.toUInt16(bytes: data, index: idx + data.startIndex)) * 2 + data.startIndex + 8
        print("Offset \(offset)")
        let slice = data[Int(offset)..<data.endIndex]
        print("Slice Start Idx \(slice.startIndex)")
        let partLength = BleMessageFactory.strLenUtf16(bytes: slice)
        if (partLength != nil) {
            print("Part Length \(partLength!)")
            return String(bytes: slice[slice.startIndex..<Int(partLength!)], encoding: String.Encoding.utf16LittleEndian)
        }
        return nil
    }

    private func resetState(clearRetryCount: Bool = true) {
        currentId = 0
        if (clearRetryCount) {
            retryCount = 0
        }
        readResult = nil
    }
    
    private func handleFlush(data: Data) {
        if (!flushing) {
            return;
        }
        if (flushData == nil) {
            flushData = data;
            debugPrint("Flush: Read for nil Data")
            releaseSemaphore()
            startRead()
        } else {
            if (!flushData!.elementsEqual(data)) {
                flushData = data
                debugPrint("Flush: Read for missmatch")
                releaseSemaphore()
                startRead()
            } else {
                debugPrint("Flush complete")
                flushing = false
                flushData = nil
                resetState(clearRetryCount: false)
                releaseSemaphore()
                flushCompleteHandler()
            }
        }
    }
}

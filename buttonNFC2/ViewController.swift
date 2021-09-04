//
//  ViewController.swift
//  buttonNFC2
//
//  Created by Jonathan Bobrow on 8/17/21.
//

import UIKit
import CoreNFC

class ViewController: UIViewController, NFCTagReaderSessionDelegate {
    
    private var tagSession: NFCTagReaderSession!
    
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        print("active NFC")
    }
    
    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print("ended session with an error from NFC")
        
    }
    
    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        print("did detect NFC")
        
        if tags.count > 1 {
            print("Wow! more than one Blink found.")
            //tagSession.restartPolling()
            return
        }
        
        
        var iso15693Tag: NFCISO15693Tag!
        
        switch tags.first! {
        case let .iso15693(tag):
            iso15693Tag = tag .asNFCISO15693Tag()!
            break
            
        default:
            print( "Tag not valid or not type5")
            //session.restartPolling()
            return
        }

        /* Begin Swift Async Callback Pyrimd of Doom */
       
        session.connect(to: tags.first!) { (error: Error?) in
            guard error == nil else {
                print("session connect error")
                print(error!)
                print("end session connect")
                session.invalidate(errorMessage: "Connection error. Please try again.")
                return
            }
            print("session.connnect success")
                    
            print( "sending GPO pulse")
            
            /* Send GPO pulse to wake blink */
            iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xa9, customRequestParameters: Data(_: [0x80])) { (response: Data, error: Error?) in
                print("in GPO send callback")
                guard error == nil else {
                    print("error in Send GPO")
                    session.invalidate(errorMessage: "Could not send GPO command. Please try again."+error!.localizedDescription)
                    print(error!)
                    print(error!.localizedDescription)
                    print("end error in custom command")
                    return
                }

                print("waiting for blink to power up, enable mailbox, and send high score block")
             
                // The blink controls this number. TODO: Actually figure it out, probably *much* shorter than this
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: {
                                    
                    print("get highscore block")

                    /* Read message command, starting at pointer 0, read 256 bytes (0 means read 256, any other value means n+1 bytes */
                    iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xac, customRequestParameters: Data(_:[0x00,0x00])) { (response: Data, error: Error?) in
                        print("Read message callback")
                        guard error == nil else {
                            print("start Read message error")
                            print(error!)
                            print("end read message error")
                            return
                        }
                        print("start read message response")
                        
                        let message_string = String( bytes: response, encoding: .ascii)
                        print("len:",response.count)
                        print(message_string!)
                        
                        print("end read message response")
                        
                        // TODO: check the block starts with "bks1" magic cookie. If not, tell user "not a blink"
                        
                        // OK, now the beef - send new game to blink as a series of 256 byte blocks
                        
                        // First block has game len and checksum
                        
                        let gameImage = [UInt8] ("This is an example of a game block that should be 256 bytes long. This is an example of a game block that should be 256 bytes long. This is an example of a game block that should be 256 bytes long.".utf8)
                        
                        // Next compute the game header block
                        
                        // find the length of the game
                        let gameLength = gameImage.count
                        
                        print("compute crc")
                        
                        // compute the checksum
                        // https://www.nongnu.org/avr-libc/user-manual/group__util__crc.html

                        let crc = gameImage.reduce(0xffff) {(crc,a)->UInt16 in
                            var newCrc = crc ^ UInt16(a)

                            for _ in 0 ..< 8 {
                                if  (newCrc & 0x0001) == 0x0001 {
                                    newCrc = (newCrc >> 1) ^ 0xA001;
                                } else {
                                    newCrc = ( newCrc >> 1);
                                }
                            }
                            
                            return newCrc
                        }
                        
                        
                        print("game length:\(gameLength) crc: \(crc)")
                                        
                        let headerBlockBytes = [UInt8(gameLength&0xFF), UInt8(gameLength/0x100), UInt8(crc&0xFF), UInt8(crc/0x100)]
                        
                        // This creates a a byte array with len-1 as the leading byte as expected by the write message command
                        func makeWriteMessageParam( block : [UInt8] ) -> [UInt8] {
                            return [ UInt8(block.count-1) ] + block
                        }
                        
                        // Send the header block
                        
                        print("sending header block")
                        
                        iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xaa, customRequestParameters: Data(_: makeWriteMessageParam( block: headerBlockBytes ) )) {  (response: Data, error: Error?) in
                            
                            print("In send header block message callback")
                            
                            guard error == nil else {
                                print("error sending header block ")
                                print(error!)
                                return;
                            }
                        
                            // Send the game blocks. Written LISP style, so will call itself recusively until error or done
                        
                            func sendNextBlock( gameImageBlance: [UInt8] ) {
                         
                                let blockBytes = Array(gameImageBlance.prefix(256))
                                
                                print( "sending a block len:",blockBytes.count)
                                
                                iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xaa, customRequestParameters: Data(_: makeWriteMessageParam( block: blockBytes ) )) {  (response: Data, error: Error?) in
                                    
                                    print("In send_block message callback")
                                    
                                    // ONly try once for now TODO: fix this
                                    return
                                    
                                    // Check if RF command failed becuase interface was busy
                                    if let nfcReaderError = error as? NFCReaderError {
                                        
                                        // It appears that the Apple NFC API only offers the response code back to us in the error string dictionary
                                        // How ugly.
                                        
                                        func extractIso15693ErrorCode(error :NFCReaderError) -> Int {
                                            
                                            let iso15693ErrorDictionary = error.errorUserInfo
                                            
                                            if iso15693ErrorDictionary["ISO15693TagResponseErrorCode"] != nil {
                                                let responseCode = iso15693ErrorDictionary["ISO15693TagResponseErrorCode"] as! Int
                                                return responseCode
                                            }
                                
                                            return 0x00
                                        }
                                    
                                        // Response code 0x0f means "chip is busy with i2c transaction. If we get this, then
                                        // we should retry the transaction. Really no need to delay.
                                        
                                        let responseCode = extractIso15693ErrorCode(error: nfcReaderError )
                                        if responseCode == 0x0f {
                                            // Note here we are resending the same block again, rather than the next block
                                            print("Chip busy, resend same block")
                                            
                                            // Wait for now just to prevent the output console from overflowing
                                            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(7), execute: {
                                                  
                                                sendNextBlock(gameImageBlance: gameImageBlance)
                                            
                                            })
                                            
                                            // The new call will take over flow, so do not fall though
                                            return
                                            
                                        }
                                        
                                    }
                                    
                                    guard error == nil else {
                                        print("error sending block ")
                                        print("type=",type(of: error! ))
                                        print("Response:", error! )
                                        print(error!)
                                        return;
                                    }
                                    
                                    if blockBytes.count == 256 {
                                        
                                        let nextGameImageBalance =  gameImageBlance[256... ]
                                        if (nextGameImageBalance.count > 0 ) {
                                            print( "sending next block...")
                                            sendNextBlock(gameImageBlance: Array( nextGameImageBalance ) )
                                            // We are done
                                            return
                                        }
                                        
                                    }
                                    print( "finished sending game")
                                    return
                                    
                                    // If we get here then we are done sending the game!
                                }
                                    
                            }
                            
                            // Send first block, which will kickstart the rest
                             sendNextBlock(gameImageBlance: gameImage)
                        }
                    }
                
                })
                    
            }
        }
    }
        
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        print("view did load")
        
        guard NFCNDEFReaderSession.readingAvailable else {
            let alertController = UIAlertController(
                title: "Scanning Not Supported",
                message: "This device doesn't support Blinks",
                preferredStyle: .alert
            )
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alertController, animated: true, completion: nil)
            //                print("This device doesn't support tag scanning.")
            
            return
        }
        
        tagSession = NFCTagReaderSession(pollingOption: [.iso15693], delegate: self, queue: nil)
        
        //            print("Hold your iPhone near an NFC tag to start ST25DV-PWM Demo.")
        tagSession?.alertMessage = "Hold your iPhone to your Blink"
        tagSession?.begin()
    }
    
    func installGame( gameImage: [UInt8] ) { //, progress: @escaping (Float) -> Void, completionHandler: @escaping (Error?) -> Void) {
    //func downloadGame(gameImage: [UInt8]) { // share progress or error
        // find the length of the game
        let gameLength = gameImage.count
        
        // compute the checksum
        let checksum = gameImage.reduce(0x0000) {(sum,current)->UInt16 in
            return (sum + UInt16(current)) & 0xFFFF
        }
        print("game length:\(gameLength) checksum: \(checksum)")
        
        
        let headerBlock = [UInt8(gameLength&0xFF), UInt8(gameLength/0x100), UInt8(checksum&0xFF), UInt8(checksum/0x100)]
        // send header block
        sendBlock(block: headerBlock)
        
        var bytesLeft = gameLength
        
        while(bytesLeft > 0) {
            
            //progress(Float(gameLength - bytesLeft) / Float(gameLength))
            
            let blockSize = min(bytesLeft,256)
            
            // send block
            
            let remainingBytes = gameImage[(gameLength - bytesLeft)...]
            let blockBytes = remainingBytes[..<blockSize]   // TODO: figure out how to get just the blockBytes
            
            print("block size sent: \(blockBytes.count)")
            // slice of the game (256 bytes max)
            
            // sendBlock the length of blockSize
            sendBlock(block: gameImage) // blockBytes
            // length of blockSize

            bytesLeft -= blockSize
        }
        
        // Success!!! Game Loaded
//        completionHandler(nil)
    }
    
    /*
     Send a block of the game
     */
    func sendBlock(block: [UInt8]) {
        // wait for the slot to be available (using a customCommand)
//        iso15693Tag.customCommandCode: 0xA0, customRequestParameters: Data(bytes: [0x00])){ (response: Data, error: Error?) in
//        }
        //            print("inside the response")
        // send block (using a customCommand)
//        iso15693Tag.customCommandCode: 0xA0, customRequestParameters: Data(bytes: [0x00])){ (response: Data, error: Error?) in
//        }
    }
    
}


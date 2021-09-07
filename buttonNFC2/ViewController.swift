//
//  ViewController.swift
//  buttonNFC2
//
//  Created by Jonathan Bobrow on 8/17/21.
//

import UIKit
import CoreNFC

enum BlinkNFCProtocol {
    
    // This cookie is at the begining of the gamestats block sent by a blink on connection.
    static let blinkGameStatCookie = "bks1".utf8
    
    // Number of bytes in each consecutive block of game data.
    // Choosen becuase apple customCOmmand does not seem to let us send the max of 256 bytes per packet, so mind as well
    // send an exact FLASH block to make blink code simpler.
    static let blockSize = 128         // Number of bytes in a game image block

}

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
            session.invalidate( errorMessage:  "Too many blinks. Try just one.")
            return
        }
        
        var iso15693Tag: NFCISO15693Tag!
        
        switch tags.first! {
        case let .iso15693(tag):
            iso15693Tag = tag .asNFCISO15693Tag()!
            break
            
        default:
            session.invalidate( errorMessage:  "Not a blink. Must be NFC type5 tag.")
            return
        }


        /* Begin Swift Async Callback Pyrimd of Doom */
        /* sync/await would be more eligant here, but I don't know howw to enable them */
       
        session.connect(to: tags.first!) { (error: Error?) in
            guard error == nil else {
                session.invalidate(errorMessage: "Error connecting to blink:"+error!.localizedDescription)
                return
            }
            print( "sending GPO pulse")
            
            /* Send GPO pulse to wake blink */
            iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xa9, customRequestParameters: Data(_: [0x80])) { (response: Data, error: Error?) in
                print("in GPO send callback")
                guard error == nil else {
                    session.invalidate(errorMessage: "Could not send GPO command:"+error!.localizedDescription)
                    return
                }

                print("waiting for blink to power up, enable mailbox, and send high score block")
             
                // The blink controls this number. TODO: Actually figure it out, probably *much* shorter than this
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: {
                                    
                    print("get gamestat block")

                    /* Read message command, starting at pointer 0, read 256 bytes (0 means read 256, any other value means n+1 bytes */
                    iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xac, customRequestParameters: Data(_:[0x00,0x00])) { (response: Data, error: Error?) in
                        print("Read gamestat callback")
                        guard error == nil else {
                            session.invalidate( errorMessage:  "Error reading gamestat block from blink: " + error!.localizedDescription )
                            print( error! )
                            return
                        }
                        
                        guard response.starts(with: BlinkNFCProtocol.blinkGameStatCookie ) else {
                            session.invalidate( errorMessage:  "Blink magic cookie not found." )
                            print("blink magic cookie not found")
                            return
                        }
                        
                        // let gameStatBlock = [UInt8](response)       // Convert to immutible byte array
                        // TODO: pass the message string back to the app to be parsed and stored.
                        
                        
                        let gameImage = [UInt8] ("""
                            ’Twas brillig, and the slithy toves
                                  Did gyre and gimble in the wabe:
                            All mimsy were the borogoves,
                                  And the mome raths outgrabe.

                            “Beware the Jabberwock, my son!
                                  The jaws that bite, the claws that catch!
                            Beware the Jubjub bird, and shun
                                  The frumious Bandersnatch!”

                            He took his vorpal sword in hand;
                                  Long time the manxome foe he sought—
                            So rested he by the Tumtum tree
                                  And stood awhile in thought.

                            And, as in uffish thought he stood,
                                  The Jabberwock, with eyes of flame,
                            Came whiffling through the tulgey wood,
                                  And burbled as it came!

                            One, two! One, two! And through and through
                                  The vorpal blade went snicker-snack!
                            He left it dead, and with its head
                                  He went galumphing back.

                            “And hast thou slain the Jabberwock?
                                  Come to my arms, my beamish boy!
                            O frabjous day! Callooh! Callay!”
                                  He chortled in his joy.

                            ’Twas brillig, and the slithy toves
                                  Did gyre and gimble in the wabe:
                            All mimsy were the borogoves,
                                  And the mome raths outgrabe.
                        """.utf8 )
                            
                      
                        if gameImage == nil {
                            // No game to send, just wanted to update gamestats
                            return
                        }
                        
                        // OK, now the beef - send new game to blink as a series of 256 byte blocks
                        
                        // First block has game len and checksum
                        
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
                           
                        // Protocol for header block is 2 byte game image len and 2 byte CRC
                        let headerBlockBytes = [UInt8(gameLength&0xFF), UInt8(gameLength/0x100), UInt8(crc&0xFF), UInt8(crc/0x100)]
                        
                        // This creates a a byte array with len-1 as the leading byte as expected by the NFC write message command
                        func makeWriteMessageParam( block : [UInt8] ) -> [UInt8] {
                            return [ UInt8(block.count-1) ] + block
                        }
                        
                        // Send the header block
                        
                        print("sending header block")
                        
                        iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xaa, customRequestParameters: Data(_: makeWriteMessageParam( block: headerBlockBytes ) )) {  (response: Data, error: Error?) in
                            
                            print("In send header block message callback")
                            
                            guard error == nil else {
                                // Note that we do not check for busy here since the blink should be passively waiting for this header
                                session.invalidate( errorMessage:  "Error sending header block:" + error!.localizedDescription )
                                return;
                            }
                        
                            // Send the game blocks. Written LISP style, so will call itself recusively until error or done
                        
                            func sendNextBlock( gameImageBlance: [UInt8] ) {
                         
                                // Peel off the next block
                                let blockBytes = Array(gameImageBlance.prefix( BlinkNFCProtocol.blockSize ))
                                
                                print( "sending a block len:",blockBytes.count)
                                
                                iso15693Tag.customCommand(requestFlags: RequestFlag(rawValue: 0x02), customCommandCode: 0xaa, customRequestParameters: Data(_: makeWriteMessageParam( block: blockBytes ) )) {  (response: Data, error: Error?) in
                                    
                                    print("In send_block message callback")
                                    
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
                                            
                                            // Wait 1ms for now just to prevent the output console from overflowing
                                            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1), execute: {
                                                  
                                                sendNextBlock(gameImageBlance: gameImageBlance)
                                            
                                            })
                                            
                                            // The new call will take over flow, so do not fall though
                                            return
                                            
                                        }
                                        
                                    }
                                    
                                    guard error == nil else {
                                        session.invalidate( errorMessage:  "Error sending game block:" + error!.localizedDescription );
                                        return;
                                    }
                                    
                                    if blockBytes.count == BlinkNFCProtocol.blockSize {
                                        
                                        // Last block was full, so maybe more
                                        
                                        let nextGameImageBalance =  gameImageBlance[ BlinkNFCProtocol.blockSize... ]
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
    
    
}


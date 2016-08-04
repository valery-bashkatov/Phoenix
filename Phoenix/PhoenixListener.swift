//
//  PhoenixListener.swift
//  TestPhoenix
//
//  Created by Valery Bashkatov on 31.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

/// The `PhoenixListener` protocol describes methods of the `Phoenix`'s listeners.
@objc public protocol PhoenixListener: class {
    
    /**
     Called when `Phoenix` connected.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     */
    optional func phoenixDidConnect(phoenix: Phoenix)
    
    /**
     Called when `Phoenix` disconnected.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter error: An error object with the cause.
     */
    optional func phoenixDidDisconnect(phoenix: Phoenix, error: NSError?)

    /**
     Called when the channel joined.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter topic: The channel's topic.
     */
    optional func phoenix(phoenix: Phoenix, didJoin topic: String)
    
    /**
     Called when the channel closed.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter topic: The channel's topic.
     - parameter error: An error object with the cause.
     */
    optional func phoenix(phoenix: Phoenix, didClose topic: String, error: NSError?)

    /**
     Called when a message is received.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter message: The received message.
     */
    func phoenix(phoenix: Phoenix, didReceive message: PhoenixMessage)
}
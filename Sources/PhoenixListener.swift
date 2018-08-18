//
//  PhoenixListener.swift
//  TestPhoenix
//
//  Created by Valery Bashkatov on 31.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

/// The `PhoenixListener` protocol describes methods of the `Phoenix`'s listeners.
public protocol PhoenixListener: class {
    
    /**
     Called when a message is received.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter message: The received message.
     */
    func phoenix(_ phoenix: Phoenix, didReceive message: PhoenixMessage)
    
    /**
     Called when `Phoenix` connected.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     */
    func phoenixDidConnect(_ phoenix: Phoenix)
    
    /**
     Called when `Phoenix` disconnected.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter error: An error object with the cause.
     */
    func phoenixDidDisconnect(_ phoenix: Phoenix, error: Error?)

    /**
     Called when the channel joined.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter topic: The channel's topic.
     */
    func phoenix(_ phoenix: Phoenix, didJoin topic: String)
    
    /**
     Called when the channel closed.
     
     - parameter phoenix: The `Phoenix` object that triggered the event.
     - parameter topic: The channel's topic.
     - parameter error: An error object with the cause.
     */
    func phoenix(_ phoenix: Phoenix, didClose topic: String, error: Error?)
}

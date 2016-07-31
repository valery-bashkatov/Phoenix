//
//  PhoenixListener.swift
//  TestPhoenix
//
//  Created by Valery Bashkatov on 31.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

public protocol PhoenixListener: class {
 
    /*
     /**
     The `PhoenixDelegate` protocol describes the methods that `Phoenix` objects call on their delegates to handle events.
     */
     public protocol PhoenixDelegate: class {
     
     /**
     Tells the delegate that `Phoenix` is connected.
     
     - parameter phoenix: The `Phoenix` object that dispatched the event.
     */
     func phoenixDidConnect(phoenix: Phoenix)
     
     /**
     Tells the delegate that `Phoenix` is disconnected.
     
     - parameter phoenix: The `Phoenix` object that dispatched the event.
     - parameter error: The error object, if it specified.
     */
     func phoenixDidDisconnect(phoenix: Phoenix, error: NSError?)
     }
     */
}
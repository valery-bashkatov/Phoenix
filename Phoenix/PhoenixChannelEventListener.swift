//
//  PhoenixChannelEventListener.swift
//  TestPhoenix
//
//  Created by Valery Bashkatov on 30.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

public protocol PhoenixChannelEventListener: PhoenixListener {
    func phoenix(phoenix: Phoenix, didReceive message: PhoenixMessage)
}
//
//  PhoenixChannelListener.swift
//  TestPhoenix
//
//  Created by Valery Bashkatov on 31.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

public protocol PhoenixChannelListener: PhoenixListener {
    func phoenix(phoenix: Phoenix, didJoin topic: String)
    //func phoenix(phoenix: Phoenix, didJoinFailed topic: String, error: NSError)
    //func phoenix(phoenix: Phoenix, didLeaveChannel topic: String)
    //func phoenix(phoenix: Phoenix, didCloseChannel topic: String)
}
//
//  WeakPhoenixListener.swift
//  TestPhoenix
//
//  Created by Valery Bashkatov on 31.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

struct WeakPhoenixListener {
    weak var value: PhoenixListener?
    
    init(value: PhoenixListener?) {
        self.value = value
    }
}
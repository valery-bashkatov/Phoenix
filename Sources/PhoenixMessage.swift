//
//  PhoenixMessage.swift
//  Phoenix
//
//  Created by Valery Bashkatov on 24.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

/**
 The `PhoenixMessage` struct defines the messages dispatched through the `Phoenix`.
 */
public struct PhoenixMessage: CustomStringConvertible, Hashable {
    
    // MARK: - Properties

    /// The topic.
    public let topic: String
    
    /// An event name.
    public let event: String
    
    /// The message payload.
    public let payload: [String: AnyObject]?
    
    /// The unique ref (message ID).
    public let ref: String
    
    /// The JSON representation for sending via `Phoenix`.
    private(set) var json: String
        
    /// :nodoc:
    public var hashValue: Int {
        return ref.hash
    }
    
    /// The description of the message.
    public var description: String {
        return json
    }
    
    // MARK: - Initialization
    
    /**
     Creates `PhoenixMessage` object with specified parameters.
     
     - parameter topic: The message's topic name.
     - parameter event: An event name.
     - parameter payload: The payload of the message.
     - parameter ref: The message ID.
     
     - returns: The `PhoenixMessage`.
     */
    init(topic: String, event: String, payload: [String: AnyObject]? = nil, ref: String) {
        self.topic = topic
        self.event = event
        self.payload = payload
        self.ref = ref
        
        let jsonObject: [String: AnyObject] = [
            "topic": topic as AnyObject,
            "event": event as AnyObject,
            "payload": (payload as AnyObject?) ?? NSNull(),
            "ref": ref as AnyObject
        ]
        
        let jsonData = try! JSONSerialization.data(withJSONObject: jsonObject, options: [])
        
        self.json = String(data: jsonData, encoding: String.Encoding.utf8)!
    }
    
    /**
     Creates `PhoenixMessage` instance from the JSON string containing the topic, event, payload and ref values.
     
     - parameter json: The JSON string.
     
     - returns: The `PhoenixMessage` instance.
     */
    init(json: String) {
        let jsonData = json.data(using: String.Encoding.utf8)!
        let jsonObject = try! JSONSerialization.jsonObject(with: jsonData, options: []) as! [String: AnyObject]
        
        self.init(topic: jsonObject["topic"] as! String,
                  event: jsonObject["event"] as! String,
                  payload: jsonObject["payload"] as? [String: AnyObject],
                  ref: jsonObject["ref"] as? String ?? NSUUID().uuidString)
    }
    
    /**
     Creates `PhoenixMessage` object with specified parameters.
     
     - parameter topic: The message's topic name.
     - parameter event: An event name.
     - parameter payload: The payload of the message.
     
     - returns: The `PhoenixMessage`.
     */
    public init(topic: String, event: String, payload: [String: AnyObject]? = nil) {
        self.init(topic: topic, event: event, payload: payload, ref: NSUUID().uuidString)
    }
}

// MARK: - Equatable

/// :nodoc:
public func ==(lhs: PhoenixMessage, rhs: PhoenixMessage) -> Bool {
    return lhs.ref == rhs.ref
}

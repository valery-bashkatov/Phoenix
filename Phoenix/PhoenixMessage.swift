//
//  PhoenixMessage.swift
//  Phoenix
//
//  Created by Valery Bashkatov on 24.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation

/**
 The `PhoenixMessage` class defines the messages dispatched through the `Phoenix`.
 */
public class PhoenixMessage: NSObject {
    
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
    
    /// The response message.
    internal(set) public var response: PhoenixMessage? {
        didSet {
            
            // Execute response handler in the background
            NSOperationQueue().addOperationWithBlock {
                
                if self.response?.payload?["status"] as? String == "ok" {
                    self.responseHandler?(message: self, error: nil)
                } else {
                    let errorReason = self.response?.payload?["response"]?["reason"] as? String
                        ??
                        self.response?.payload?["response"]?["error"] as? String
                        ?? ""
                    
                    let errorDescription = "Sending a message failed because: \(errorReason)"
                    
                    let error = NSError(domain: "phoenix.message.error",
                        code: 0,
                        userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                   NSLocalizedDescriptionKey: errorDescription])
                    
                    self.responseHandler?(message: self, error: error)
                }
            }
        }
    }
    
    /// The closure, which will be executed in the background after setting response.
    var responseHandler: ((message: PhoenixMessage, error: NSError?) -> Void)?
    
    /// :nodoc:
    public override var hash: Int {
        return ref.hash
    }
    
    /// The description of the message.
    override public var description: String {
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
    public init(topic: String, event: String, payload: [String: AnyObject]? = nil, ref: String = NSUUID().UUIDString) {
        self.topic = topic
        self.event = event
        self.payload = payload
        self.ref = ref
        
        let jsonObject: [String: AnyObject] = [
            "topic": topic,
            "event": event,
            "payload": payload ?? NSNull(),
            "ref": ref
        ]
        
        let jsonData = try! NSJSONSerialization.dataWithJSONObject(jsonObject, options: .PrettyPrinted)
        
        self.json = String(data: jsonData, encoding: NSUTF8StringEncoding)!
    }
    
    /**
     Creates `PhoenixMessage` instance from the JSON string containing the topic, event, payload and ref values.
     
     - parameter json: The JSON string.
     
     - returns: The `PhoenixMessage` instance.
     */
    convenience init(json: String) {
        let jsonData = json.dataUsingEncoding(NSUTF8StringEncoding)!
        let jsonObject = try! NSJSONSerialization.JSONObjectWithData(jsonData, options: [])
        
        self.init(topic: jsonObject["topic"] as! String,
                  event: jsonObject["event"] as! String,
                  payload: jsonObject["payload"] as? [String: AnyObject],
                  ref: jsonObject["ref"] as? String ?? NSUUID().UUIDString)
    }
    
    // MARK: - Comparison
    
    /// :nodoc:
    public override func isEqual(object: AnyObject?) -> Bool {
        guard let object = object as? PhoenixMessage else {
            return false
        }
        
        return object.ref == ref
    }
}
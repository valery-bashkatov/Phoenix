//
//  Phoenix.swift
//  Phoenix
//
//  Created by Valery Bashkatov on 24.07.16.
//  Copyright © 2016 Valery Bashkatov. All rights reserved.
//

import Foundation
import Starscream

/**
 The `Phoenix`
 */
public class Phoenix: WebSocketDelegate {
    
    // MARK: - System Events
    
    /// The close channel event.
    static let closeEvent = "phx_close"
    
    /// The error event. Used for receiving the error messages.
    static let errorEvent = "phx_error"
    
    /// The join channel event.
    static let joinEvent  = "phx_join"
    
    /// The reply event. Used for receiving all response messages.
    static let replyEvent = "phx_reply"
    
    /// The leave channel event.
    static let leaveEvent = "phx_leave"
    
    // MARK: - Properties
    
    /// The WebSocket object.
    private var socket: WebSocket
    
    /**
     The channels information. 
     
     Structure:
     
     ```
     [
       "system": (isJoined: true,
                  eventListeners: [
                    ("change": [listener1, listener2],
                    ("remove": [listener3])]),
     
       "chat1": (isJoined: nil,
                 eventListeners: [])
     
       "chat2": (isJoined: false,
                 eventListeners: [listener4])
     ]
     ```
     */
    private var channels: [String: (isJoined: Bool?, eventListeners: [String: [WeakPhoenixListener]])]
    
    /// The queue of messages to send.
    private var sendingQueue: [(message: PhoenixMessage,
                                completionHandler: ((message: PhoenixMessage,
                                                     response: PhoenixMessage,
                                                     error: NSError?) -> Void)?)]
    
    /// A Boolean value that indicates a connection status.
    public var isConnected: Bool {
        return socket.isConnected
    }
    
    // MARK: - Initialization
    
    /**
     Creates the `Phoenix` object.
     
     - parameter url: The URL of the WebSocket.
     - parameter parameters: The URL encoded parameters that will be joined to the URL.
     
     returns: The `Phoenix` instance.
     */
    public init(url: NSURL, parameters: [String: String]? = nil) {
        
        // Make url with parameters from components
        let urlComponents = NSURLComponents(URL: url, resolvingAgainstBaseURL: false)!
        
        if let parameters = parameters?.map({NSURLQueryItem(name: $0, value: $1)}) {

            if urlComponents.queryItems == nil {
                urlComponents.queryItems = parameters
            } else {
                urlComponents.queryItems! += parameters
            }
        }
        
        channels = [:]
        sendingQueue = []
        
        socket = WebSocket(url: urlComponents.URL!)
        socket.delegate = self
    }
    
    // MARK: - Connection
    
    /**
     Connects `Phoenix`.
     */
    public func connect() {
        if !isConnected {
            socket.connect()
        }
    }
    
    /**
     Disconnects `Phoenix`.
     */
    public func disconnect() {
        if isConnected {
            socket.disconnect()
            
            channels = [:]
            sendingQueue = []
        }
    }
    
    // MARK: - Channels Management
    
    /**
     Joins the channel with specified topic.
     
     - parameter topic: The channel's topic.
     */
    private func join(topic: String) {
        if channels[topic] == nil {
            channels[topic] = (isJoined: nil, eventListeners: [:])
        }
        
        guard isConnected && channels[topic]?.isJoined == nil else {
            return
        }
        
        log("Join needed: \(topic)", tag: "Channel")
        log("Start joining: \(topic)", tag: "Channel")
        
        channels[topic]?.isJoined = false
        
        // Send join message
        let joinMessage = PhoenixMessage(topic: topic, event: Phoenix.joinEvent)
        
        send(joinMessage) {
            (message: PhoenixMessage, response: PhoenixMessage, error: NSError?) in
            
            guard error == nil else {
                self.channels[message.topic]?.isJoined = false
                self.log("Join failed: \(message.topic). Error: \(error!)", tag: "Channel")
                return
            }
            
            self.channels[message.topic]?.isJoined = true
            self.log("Joined: \(message.topic)", tag: "Channel")
            
            // Notify listeners about joining
            self.channels[message.topic]!.eventListeners.flatMap {$1}.forEach {
                ($0.value as? PhoenixChannelListener)?.phoenix(self, didJoin: message.topic)
            }
            
            self.log("Sending messages waiting to join channel: \(message.topic)", tag: "Channel")
            self.sendingQueue.forEach {
                if $0.message.topic == message.topic {
                    self.send($0.message, completionHandler: $0.completionHandler)
                }
            }
        }
    }
    
    // MARK: - Sending and Receiving Messages
    
    /**
     Adds a message to the sending queue.
     
     - parameter message: The message to send.
     - parameter completionHandler: The closure, which is called after message sending and receiving a response from the server.
     */
    public func send(message: PhoenixMessage,
                     completionHandler: ((message: PhoenixMessage,
                                          response: PhoenixMessage,
                                          error: NSError?) -> Void)? = nil) {
        
        join(message.topic)
        
        // Add message to queue if needed
        if !sendingQueue.contains({$0.message.ref == message.ref}) {
            sendingQueue.append((message: message, completionHandler: completionHandler))
            log("Added to queue: \(message)", tag: "Message")
        } else {
            log("Already in queue: \(message)", tag: "Message")
        }
        
        // If Phoenix is not connected
        guard isConnected else {
            log("Not connected", tag: "Phoenix")
            return
        }
        
        // If message's channel is not joined or it is not channel join message
        guard (channels[message.topic]?.isJoined ?? false) || message.event == Phoenix.joinEvent else {
            log("Not yet joined: \(message.topic)", tag: "Channel")
            return
        }
        
        // Send data to socket
        socket.writeString(message.json) {
            self.log("Sent to socket: \(message)", tag: "Message")
        }
    }
    
    /**
     Receives `PhoenixMessage` from the socket.
     
     - parameter message: The received message.
     */
    private func receive(message: PhoenixMessage) {
        
        // If recieved message is a response message
        guard message.event != Phoenix.replyEvent else {
            let responseMessage = message
            
            log("Response received: \(responseMessage)", tag: "Message")
            
            guard let original = sendingQueue.filter({$0.message.ref == responseMessage.ref}).first else {
                log("Response without original message in queue", tag: "Message")
                return
            }
            
            sendingQueue = sendingQueue.filter {$0.message.ref != original.message.ref}
            log("Removed from queue: \(original.message)", tag: "Message")
            
            // Execute completion handler
            NSOperationQueue().addOperationWithBlock {
                
                if responseMessage.payload?["status"] as? String == "ok" {
                    original.completionHandler?(message: original.message, response: responseMessage, error: nil)
                    
                } else {
                    let errorReason = responseMessage.payload?["response"]?["reason"] as? String
                                      ??
                                      responseMessage.payload?["response"]?["error"] as? String
                                      ?? ""
                    
                    let errorDescription = "Sending a message failed because: \(errorReason)"
                    
                    let error = NSError(domain: "phoenix.message.error",
                                        code: 0,
                                        userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                                   NSLocalizedDescriptionKey: errorDescription])
                    
                    original.completionHandler?(message: original.message, response: responseMessage, error: error)
                }
            }
            
            return
        }
        
        log("Received: \(message)", tag: "Message")
        
        log("Sending to listeners of channel topic: \(message.topic), event: \(message.event): \(message)", tag: "Message")
        channels[message.topic]!.eventListeners[message.event]?.forEach {
            ($0.value as? PhoenixChannelEventListener)?.phoenix(self, didReceive: message)
        }
    }
    
    // MARK: - Adding and Removing Listeners
    
    /**
     Adds a listener object for the specified channel topic and event.
     
     - parameter listener: The listener.
     - parameter topic: The channel's topic.
     - parameter event: The event name.
     */
    public func addListener(listener: PhoenixListener, forChannel topic: String, event: String) {
        removeListener(listener, forChannel: topic, event: event)
        
        join(topic)
        
        if channels[topic]?.eventListeners[event] == nil {
            channels[topic]?.eventListeners[event] = []
        }
        
        channels[topic]?.eventListeners[event]!.append(WeakPhoenixListener(value: listener))
    }
    
    /**
     Removes the listener object for the specified channel topic and event.
     
     - parameter listener: The listener.
     - parameter topic: The channel's topic.
     - parameter event: The event name.
     */
    public func removeListener(listener: PhoenixListener, forChannel topic: String, event: String) {
        
        if let eventListeners = channels[topic]?.eventListeners[event] {
            channels[topic]?.eventListeners[event] = eventListeners.filter {$0.value !== listener}
        }
    }
    
    // MARK: - Logging
    
    /**
     Utility method for logging events.
     
     - parameter text: The text.
     - parameter tag: The tag for the text.
     */
    private func log(text: String, tag: String) {
        let formater = NSDateFormatter()
        formater.dateFormat = "HH:mm:ss"
        
        print("[\(tag) \(formater.stringFromDate(NSDate()))] \(text)")
    }
    
    // MARK: - WebSocketDelegate
    
    /// :nodoc:
    public func websocketDidConnect(socket: WebSocket) {
        channels.forEach {join($0.0)}
        log("Joining channels", tag: "Phoenix")
        
        //delegate?.phoenixDidConnect(self)
        log("Connected", tag: "Phoenix")
    }
    
    /// :nodoc:
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {
        channels.forEach {channels[$0.0]?.isJoined = nil}
        sendingQueue = sendingQueue.filter {$0.message.event != Phoenix.joinEvent}
        log("Channels left", tag: "Phoenix")
        
        //delegate?.phoenixDidDisconnect(self, error: error)
        log("Disconnected. Reason: \(error)", tag: "Phoenix")
    }
    
    /// :nodoc:
    public func websocketDidReceiveMessage(socket: WebSocket, text: String) {
        receive(PhoenixMessage(json: text))
    }
    
    /// :nodoc:
    public func websocketDidReceiveData(socket: WebSocket, data: NSData) {
        websocketDidReceiveMessage(socket, text: String(data: data, encoding: NSUTF8StringEncoding)!)
    }
}
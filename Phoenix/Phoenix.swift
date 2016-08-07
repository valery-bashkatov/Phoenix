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
 The `Phoenix` class provides a convenient mechanism to communicate with [Phoenix Framework Channels](http://www.phoenixframework.org/docs/channels).
 
 - seealso: [Phoenix Framework Overview](http://www.phoenixframework.org/docs/overview)
 */
public class Phoenix: NSObject, WebSocketDelegate {
    
    /// A structure for wrapping a weak reference of the `PhoenixListener` object.
    private struct WeakPhoenixListener {
        weak var listener: PhoenixListener?
        
        init(listener: PhoenixListener?) {
            self.listener = listener
        }
    }
    
    // MARK: - System Events
    
    /// An event for join the channel.
    private static let joinEvent = "phx_join"
    
    /// An event of closing the channel.
    private static let closeEvent = "phx_close"
    
    /// An event of error on channel.
    private static let errorEvent = "phx_error"
    
    /// An event for receiving response messages.
    private static let replyEvent = "phx_reply"
    
    /// An event for the messages of heart beating.
    private static let heartbeat = "heartbeat"
    
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
    private var channels = [String: (isJoined: Bool?, eventListeners: [String: [WeakPhoenixListener]])]()
    
    /// The queue of messages to send.
    private var sendingQueue = [PhoenixMessage]()
    
    /// The heartbeat timer.
    private var heartbeatTimer = NSTimer()
    
    /// The heartbeat interval (in seconds).
    private var heartbeatInterval = 20.0
    
    /// A Boolean value that indicates a need of auto reconnections.
    public var autoReconnect = true
    
    /// The auto reconnection delay intervals (in seconds). The first try, second, third and so on.
    public var autoReconnectIntervals = [1.0, 2.0, 3.0, 4.0, 5.0]
    
    /// An index of the current reconnection interval in the `autoReconnectIntervals` list.
    private var autoReconnectCurrentIntervalIndex = 0

    /// A Boolean value that indicates a connection status.
    public var isConnected: Bool {
        return socket.isConnected
    }
    
    /// The operation queue, which is used to call listeners' methods.
    private let queue = (starscream: dispatch_queue_create("phoenix.starscream", DISPATCH_QUEUE_CONCURRENT),
                         message: dispatch_queue_create("phoenix.message", DISPATCH_QUEUE_CONCURRENT),
                         channel: dispatch_queue_create("phoenix.channel", DISPATCH_QUEUE_CONCURRENT),
                         listener: dispatch_queue_create("phoenix.listener", DISPATCH_QUEUE_CONCURRENT))
    
    
    // MARK: - Initialization
    
    /**
     Creates the `Phoenix` object.
     
     - parameter url: The URL of the WebSocket.
     - parameter parameters: The URL encoded parameters that will be joined to the URL.
     
     - returns: The `Phoenix` instance.
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
        
        socket = WebSocket(url: urlComponents.URL!)
        
        super.init()
        
        socket.queue = queue.starscream
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
     Disconnects `Phoenix`. If `autoReconnect` is true, it will be set to false.
     */
    public func disconnect() {
        if autoReconnect {
            autoReconnect = false
        }
        
        if isConnected {
            socket.disconnect()
            
            dispatch_barrier_sync(queue.channel) {
                self.channels = [:]
            }
            
            dispatch_barrier_sync(queue.message) {
                self.sendingQueue = []
            }
        }
    }
    
    // MARK: - Channels Management
    
    /**
     Joins the channel with specified topic.
     
     - parameter topic: The channel topic.
     */
    private func join(topic: String) {
        var needSendJoinMessage = false
        
        // If channel is not yet joined and joining is not started
        dispatch_barrier_sync(queue.channel) {
            if self.channels[topic] == nil {
                self.channels[topic] = (isJoined: nil, eventListeners: [:])
            }
            
            // isJoined == nil means that joining the channel is not yet started
            if self.isConnected && self.channels[topic]?.isJoined == nil {
                
                // isJoined == false means that joining started but not yet completed
                self.channels[topic]?.isJoined = false
                
                // Need to send join message
                needSendJoinMessage = true
            }
        }
        
        guard needSendJoinMessage else {
            return
        }

        // Send join message with special response handler
        let joinMessage = PhoenixMessage(topic: topic, event: Phoenix.joinEvent)
        
        send(joinMessage) {
            (message: PhoenixMessage, error: NSError?) in
        
            var needResendMessages = false
            
            dispatch_barrier_sync(self.queue.channel) {
                
                // Join failed
                if error != nil {
                    
                    // Reset channel joining status
                    self.channels[message.topic]?.isJoined = nil
                    
                    // Notify channel listeners about joining error
                    let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                    
                    dispatch_async(self.queue.listener) {
                        eventListeners?.forEach {
                            $0.listener?.phoenix?(self, didClose: message.topic, error: error)
                        }
                    }
                    
                // Successful joining
                } else {
                    
                    // Set channel status to is joined
                    self.channels[message.topic]?.isJoined = true
                    
                    // Notify channel listeners about successful joining
                    let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                    
                    dispatch_async(self.queue.listener) {
                        eventListeners?.forEach {
                            $0.listener?.phoenix?(self, didJoin: message.topic)
                        }
                    }
                    
                    needResendMessages = true
                }
            }
            
            guard needResendMessages else {
                return
            }
            
            // Sending messages waiting channel join
            var sendingQueue: [PhoenixMessage]!
            
            dispatch_sync(self.queue.message) {
                sendingQueue = self.sendingQueue
            }
            
            sendingQueue.forEach {
                if $0.topic == message.topic {
                    self.send($0)
                }
            }
        }
        
    }
    
    // MARK: - Sending Messages
    
    /**
     Adds a message to the sending queue.
     
     - parameter message: The message to send.
     - parameter responseHandler: The closure, which is called after message sending and receiving a response from the server. It will be executed in the background queue.
     */
    public func send(message: PhoenixMessage,
                     responseHandler: ((message: PhoenixMessage, error: NSError?) -> Void)? = nil) {
        
        // Join the channel (if needed)
        join(message.topic)
        
        // Add message to the queue if needed
        dispatch_barrier_sync(queue.message) {
            if !self.sendingQueue.contains(message) {
                message.responseHandler = responseHandler
                self.sendingQueue.append(message)
            }
        }
        
        var isChannelJoined = false
        
        dispatch_sync(queue.channel) {
            isChannelJoined = self.channels[message.topic]?.isJoined ?? false
        }
        
        // Send message if phoenix is connected, channel joined (or it's a join channel message) and message's response is empty
        if isConnected && (isChannelJoined || message.event == Phoenix.joinEvent) && message.response == nil {
            socket.writeString(message.json)
        }
    }
    
    // MARK: - Receiving Messages
    
    /**
     Receives `PhoenixMessage` from the socket.
     
     - parameter message: The received message.
     */
    private func receive(message: PhoenixMessage) {
        
        switch message.event {
            
        // Response message
        case Phoenix.replyEvent:
            
            dispatch_barrier_async(queue.message) {
                let responseMessage = message
                
                // If the original message found
                if let originalMessageIndex = self.sendingQueue.indexOf(responseMessage) {
                    
                    // Get original message
                    let originalMessage = self.sendingQueue[originalMessageIndex]
                    
                    // Remove original message from the queue
                    self.sendingQueue.removeAtIndex(originalMessageIndex)
                    
                    // Set response of the original message
                    originalMessage.response = responseMessage
                }
            }
            
        // Error or close channel message
        case Phoenix.errorEvent, Phoenix.closeEvent:
            
            dispatch_barrier_async(queue.channel) {
                self.channels[message.topic]?.isJoined = nil
                
                // Notify channel listeners
                let errorReason = message.payload?["response"]?["reason"] as? String
                    ??
                    message.payload?["response"]?["error"] as? String
                    ?? ""
                
                let errorDescription = "Channel is closed by the server because: \(errorReason)"
                
                let error = NSError(domain: "phoenix.message.error",
                                    code: 0,
                                    userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                               NSLocalizedDescriptionKey: errorDescription])
                
                // Notify channel listeners about channel error or closing
                let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                
                dispatch_async(self.queue.listener) {
                    eventListeners?.forEach {
                        $0.listener?.phoenix?(self, didClose: message.topic, error: error)
                    }
                }
            }
            
        // Standard message
        default:
            
            // Notify channel and event listeners, channel listeners
            dispatch_async(queue.channel) {
                let eventListeners = (self.channels[message.topic]?.eventListeners[message.event] ?? []) +
                                     (self.channels[message.topic]?.eventListeners["*"] ?? [])
                
                dispatch_async(self.queue.listener) {
                    eventListeners.forEach {
                        $0.listener?.phoenix(self, didReceive: message)
                    }
                }
            }
        }
    }
    
    // MARK: - Adding and Removing Listeners
    
    /**
     Adds a listener object for the specified channel topic and event.
     
     - parameter listener: The listener.
     - parameter topic: The channel topic.
     - parameter event: The event name. Asterisk for all channel events.
     */
    public func addListener(listener: PhoenixListener, forChannel topic: String, event: String = "*") {
        
        // Remove the listener if it already exist
        removeListener(listener, forChannel: topic, event: event)
        
        // Join the channel (if needed)
        join(topic)
        
        dispatch_barrier_sync(queue.channel) {
            if self.channels[topic]?.eventListeners[event] == nil {
                self.channels[topic]?.eventListeners[event] = []
            }
            
            // Add listener as a weak reference
            self.channels[topic]?.eventListeners[event]!.append(WeakPhoenixListener(listener: listener))
        }
    }
    
    /**
     Removes the listener object for the specified channel topic and event.
     
     - parameter listener: The listener.
     - parameter topic: The channel topic.
     - parameter event: The event name. Asterisk for all channel events.
     */
    public func removeListener(listener: PhoenixListener, forChannel topic: String, event: String = "*") {
        
        // Remove the listener
        dispatch_barrier_sync(queue.channel) {
            if let eventListeners = self.channels[topic]?.eventListeners[event] {
                self.channels[topic]?.eventListeners[event] = eventListeners.filter {$0.listener !== listener}
            }
        }
    }
    
    // MARK: - Heartbeat
    
    @objc private func sendHeartbeat() {
        if isConnected {
            let heartbeatMessage = PhoenixMessage(topic: "phoenix", event: Phoenix.heartbeat)
            
            socket.writeString(heartbeatMessage.json)
        }
    }
    
    // MARK: - WebSocketDelegate
    
    /// :nodoc:
    public func websocketDidConnect(socket: WebSocket) {
        
        var channels: [String: (isJoined: Bool?, eventListeners: [String: [WeakPhoenixListener]])]!
        
        // Notify listeners about connection
        dispatch_sync(queue.channel) {
            let eventListeners = self.channels.flatMap {$1.eventListeners.flatMap {$1}}
            
            dispatch_async(self.queue.listener) {
                eventListeners.forEach {
                    $0.listener?.phoenixDidConnect?(self)
                }
            }
            
            channels = self.channels
        }
        
        channels.forEach {join($0.0)}
        
        heartbeatTimer.invalidate()
        heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(heartbeatInterval,
                                                                target: self,
                                                                selector: #selector(sendHeartbeat),
                                                                userInfo: nil,
                                                                repeats: true)
        
        autoReconnectCurrentIntervalIndex = 0
    }
    
    /// :nodoc:
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {

        heartbeatTimer.invalidate()

        dispatch_barrier_sync(queue.channel) {
            self.channels.forEach {self.channels[$0.0]?.isJoined = nil}
        }

        dispatch_barrier_sync(queue.message) {
            self.sendingQueue = self.sendingQueue.filter {$0.event != Phoenix.joinEvent}
        }
        
        if autoReconnect && autoReconnectCurrentIntervalIndex <= autoReconnectIntervals.count - 1 {
        
            // Without auto reconnection just notify listeners about disconnection
            dispatch_async(queue.channel) {
                let eventListeners = self.channels.flatMap {$1.eventListeners.flatMap {$1}}
                
                dispatch_async(self.queue.listener) {
                    eventListeners.forEach {
                        $0.listener?.phoenixDidDisconnect?(self, error: error)
                    }
                }
            }
        } else {
            
            // Auto reconnect after delay interval
            NSTimer.scheduledTimerWithTimeInterval(autoReconnectIntervals[autoReconnectCurrentIntervalIndex],
                                                   target: self,
                                                   selector: #selector(connect),
                                                   userInfo: nil,
                                                   repeats: false)
            
            autoReconnectCurrentIntervalIndex += 1
        }
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
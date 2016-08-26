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
                    "change": [listener1, listener2],
                    "remove": [listener3]
                  ]
                 ),
     
       "chat1": (isJoined: nil,
                 eventListeners: [:])
     
       "chat2": (isJoined: false,
                 eventListeners: [
                    "message": [listener4]
                 ]
                )
     ]
     ```
     */
    private var channels: [String: (isJoined: Bool?, eventListeners: [String: [WeakPhoenixListener]])] = [:]

    /// The queue of messages to send. A message is deleted from it after receiving a response.
    private var sendingBuffer: [(message: PhoenixMessage,
                                 responseHandler: ((response: PhoenixMessage, error: NSError?) -> Void)?)] = []
    
    /// The access queues, which will be used for concurrent access to the `channels` and `sendingBuffer` objects.
    private let accessQueue = (channels: dispatch_queue_create("phoenix.channels", DISPATCH_QUEUE_CONCURRENT),
                               sendingBuffer: dispatch_queue_create("phoenix.sendingBuffer", DISPATCH_QUEUE_CONCURRENT))
    
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
    
    /// The operation queue, which is used to call listeners methods.
    public var listenerQueue = NSOperationQueue.mainQueue()
    
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
        
        socket.queue = dispatch_queue_create("phoenix", DISPATCH_QUEUE_CONCURRENT)
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
        autoReconnect = false
        
        if isConnected {
            socket.disconnect()
            
            dispatch_barrier_sync(accessQueue.channels) {
                self.channels = [:]
            }
            
            dispatch_barrier_sync(accessQueue.sendingBuffer) {
                self.sendingBuffer = []
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
        dispatch_barrier_sync(accessQueue.channels) {
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
            
            dispatch_barrier_sync(self.accessQueue.channels) {
                
                // Join failed
                guard error == nil else {
                    
                    // Reset channel joining status
                    self.channels[message.topic]?.isJoined = nil
                    
                    // Notify channel listeners about joining error
                    let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                    
                    self.listenerQueue.addOperationWithBlock {
                        eventListeners?.forEach {
                            $0.listener?.phoenix?(self, didClose: message.topic, error: error)
                        }
                    }
                    
                    return
                }
                
                // Successful join
                
                // Set channel status to is joined
                self.channels[message.topic]?.isJoined = true
                
                // Notify channel listeners about successful joining
                let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                
                self.listenerQueue.addOperationWithBlock {
                    eventListeners?.forEach {
                        $0.listener?.phoenix?(self, didJoin: message.topic)
                    }
                }
                
                needResendMessages = true
            }
            
            guard needResendMessages else {
                return
            }
            
            // Sending messages waiting channel join
            var sendingBuffer: [(message: PhoenixMessage,
                                 responseHandler: ((response: PhoenixMessage, error: NSError?) -> Void)?)]!
            
            dispatch_sync(self.accessQueue.sendingBuffer) {
                sendingBuffer = self.sendingBuffer
            }
            
            sendingBuffer.forEach {
                if $0.message.topic == message.topic {
                    self.send($0.message)
                }
            }
        }
    }
    
    // MARK: - Sending Messages
    
    /**
     Adds a message to the sending queue.
     
     - parameter message: The message to send.
     - parameter responseHandler: The closure, which is called after message sending and receiving a response from the server. It will be executed in the `listenerQueue`.
     */
    public func send(message: PhoenixMessage,
                     responseHandler: ((response: PhoenixMessage, error: NSError?) -> Void)? = nil) {
        
        // Join the channel (if needed)
        join(message.topic)
        
        // Add message to the queue if needed
        dispatch_barrier_sync(accessQueue.sendingBuffer) {
            if !self.sendingBuffer.contains({$0.message.isEqual(message)}) {
                self.sendingBuffer.append((message: message, responseHandler: responseHandler))
            }
        }
        
        var isChannelJoined = false
        
        dispatch_sync(accessQueue.channels) {
            isChannelJoined = self.channels[message.topic]?.isJoined ?? false
        }
        
        // Send message if phoenix is connected, channel joined (or it's a join channel message) and message's response is empty
        if isConnected && (isChannelJoined || message.event == Phoenix.joinEvent) {
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
            
            dispatch_barrier_async(accessQueue.sendingBuffer) {
                let responseMessage = message
                
                // If original message found
                if let originalMessageIndex = self.sendingBuffer.indexOf({$0.message.isEqual(responseMessage)}) {
                    
                    // Get original message
                    let originalMessage = self.sendingBuffer[originalMessageIndex]
                    
                    // Remove original message from the queue
                    self.sendingBuffer.removeAtIndex(originalMessageIndex)
                    
                    // Execute response handler
                    self.listenerQueue.addOperationWithBlock {
                        
                        // Error response
                        guard responseMessage.payload?["status"] as? String == "ok" else {
                        
                            let errorReason = responseMessage.payload?["response"]?["reason"] as? String
                                ??
                                responseMessage.payload?["response"]?["error"] as? String
                                ?? ""
                            
                            let errorDescription = "Sending a message failed because: \(errorReason)"
                            
                            let error = NSError(domain: "phoenix.message.error",
                                                code: 0,
                                                userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                                           NSLocalizedDescriptionKey: errorDescription])
                            
                            originalMessage.responseHandler?(response: responseMessage, error: error)
                            
                            return
                        }
                        
                        
                        // Successful response
                        originalMessage.responseHandler?(response: responseMessage, error: nil)
                    }
                }
            }
            
        // Error or close channel message
        case Phoenix.errorEvent, Phoenix.closeEvent:
            
            dispatch_barrier_async(accessQueue.channels) {
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
                
                self.listenerQueue.addOperationWithBlock {
                    eventListeners?.forEach {
                        $0.listener?.phoenix?(self, didClose: message.topic, error: error)
                    }
                }
            }
            
        // Standard message
        default:
            
            // Notify channel and event listeners, channel listeners
            dispatch_async(accessQueue.channels) {
                
                let eventListeners = (self.channels[message.topic]?.eventListeners[message.event] ?? []) +
                                     (self.channels[message.topic]?.eventListeners["*"] ?? [])
                
                self.listenerQueue.addOperationWithBlock {
                    eventListeners.forEach {
                        $0.listener?.phoenix(self, didReceive: message)
                    }
                }
            }
        }
    }
    
    // MARK: - Adding and Removing Listeners
    
    /**
     Adds a listener object for the specified channel topic and event. Listener methods will be executed in the `listenerQueue`.
     
     - parameter listener: The listener.
     - parameter topic: The channel topic.
     - parameter event: The event name. If is `nil`, then all events of the channel.
     */
    public func addListener(listener: PhoenixListener, forChannel topic: String, event: String? = nil) {

        // Asterisk is equal to all events of the channel
        let event = event ?? "*"
        
        var needAddListener = true
        
        // If listener already exists, do not add it again
        dispatch_sync(accessQueue.channels) {
            needAddListener = !(self.channels[topic]?.eventListeners[event]?.contains({$0.listener === listener}) ?? false)
        }
        
        guard needAddListener else {
            return
        }
        
        // Join the channel (if needed)
        join(topic)
        
        dispatch_barrier_sync(accessQueue.channels) {

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
     - parameter event: The event name; `nil` means all events of the channel.
     */
    public func removeListener(listener: PhoenixListener, forChannel topic: String, event: String? = nil) {
        
        // Remove the listener
        dispatch_barrier_sync(accessQueue.channels) {
            
            // If event == nil, then remove listener from all events
            guard let event = event else {

                self.channels[topic]?.eventListeners.forEach {
                    if let index = self.channels[topic]?.eventListeners[$0.0]?.indexOf({$0.listener === listener}) {
                        self.channels[topic]?.eventListeners[$0.0]?.removeAtIndex(index)
                    }
                }
                
                return
            }
            
            // Otherwise, from specified event
            if let index = self.channels[topic]?.eventListeners[event]?.indexOf({$0.listener === listener}) {
                self.channels[topic]?.eventListeners[event]?.removeAtIndex(index)
            }
        }
    }
    
    // MARK: - Heartbeat
    
    /**
     Sends heartbeat message.
     */
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
        
        // If this is the initial connection, then notify listeners about connection
        dispatch_sync(accessQueue.channels) {
            if self.autoReconnectCurrentIntervalIndex == 0 {
                
                var uniqueEventListeners = [WeakPhoenixListener]()
                let eventListeners = self.channels.flatMap {$1.eventListeners.flatMap {$1}}
                
                eventListeners.forEach {
                    (eventListener: WeakPhoenixListener) in
                    
                    if !uniqueEventListeners.contains({$0.listener === eventListener.listener}) {
                        uniqueEventListeners.append(eventListener)
                    }
                }
                
                self.listenerQueue.addOperationWithBlock {
                    uniqueEventListeners.forEach {
                        $0.listener?.phoenixDidConnect?(self)
                    }
                }
                
                channels = self.channels
            }
        }
        
        channels.forEach {join($0.0)}
        
        dispatch_async(dispatch_get_main_queue()) {
            self.heartbeatTimer.invalidate()
            self.heartbeatTimer = NSTimer.scheduledTimerWithTimeInterval(self.heartbeatInterval,
                                                                         target: self,
                                                                         selector: #selector(self.sendHeartbeat),
                                                                         userInfo: nil,
                                                                         repeats: true)
        }
        
        autoReconnectCurrentIntervalIndex = 0
    }
    
    /// :nodoc:
    public func websocketDidDisconnect(socket: WebSocket, error: NSError?) {

        dispatch_async(dispatch_get_main_queue()) {
            self.heartbeatTimer.invalidate()
        }

        dispatch_barrier_sync(accessQueue.channels) {
            self.channels.forEach {self.channels[$0.0]?.isJoined = nil}
        }

        dispatch_barrier_sync(accessQueue.sendingBuffer) {
            self.sendingBuffer = self.sendingBuffer.filter {$0.message.event != Phoenix.joinEvent}
        }
        
        dispatch_async(accessQueue.channels) {
            if self.autoReconnect && self.autoReconnectCurrentIntervalIndex <= self.autoReconnectIntervals.count - 1 {
                
                // Auto reconnect after delay interval
                dispatch_async(dispatch_get_main_queue()) {
                    NSTimer.scheduledTimerWithTimeInterval(self.autoReconnectIntervals[self.autoReconnectCurrentIntervalIndex],
                                                           target: self,
                                                           selector: #selector(self.connect),
                                                           userInfo: nil,
                                                           repeats: false)
                    
                    self.autoReconnectCurrentIntervalIndex += 1
                }
                
            } else {
                
                // Notify listeners about disconnection
                var uniqueEventListeners = [WeakPhoenixListener]()
                let eventListeners = self.channels.flatMap {$1.eventListeners.flatMap {$1}}
                
                eventListeners.forEach {
                    (eventListener: WeakPhoenixListener) in
                    
                    if !uniqueEventListeners.contains({$0.listener === eventListener.listener}) {
                        uniqueEventListeners.append(eventListener)
                    }
                }
                
                self.listenerQueue.addOperationWithBlock {
                    uniqueEventListeners.forEach {
                        $0.listener?.phoenixDidDisconnect?(self, error: error)
                    }
                }
                
                self.autoReconnectCurrentIntervalIndex = 0
            }
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
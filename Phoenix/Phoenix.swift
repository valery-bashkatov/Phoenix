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
 The `Phoenix` class provides a convenient mechanism to communicate with the [Phoenix Framework Channels](http://www.phoenixframework.org/docs/channels).
 
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

    /// The operation queue, which is used to call listeners' methods.
    public var listenerQueue = NSOperationQueue()
    
    /// A Boolean value that indicates a connection status.
    public var isConnected: Bool {
        return socket.isConnected
    }
    
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
        socket.queue = dispatch_queue_create("org.bashkatov.valery.phoenix.starscream.queue", DISPATCH_QUEUE_CONCURRENT)
        
        super.init()
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
        
        // Set channel info if not exist
        if channels[topic] == nil {
            channels[topic] = (isJoined: nil, eventListeners: [:])
        }
        
        // If there is no connection, then exit. Joining will take place after the connection
        guard isConnected else {
            return
        }
        
        // If isJoined != nil, then exit, because the joining is already in progress
        guard channels[topic]?.isJoined == nil else {
            return
        }
        
        // Set status to false for change channel status to "Joining in progress"
        channels[topic]?.isJoined = false
        
        // Send join message
        let joinMessage = PhoenixMessage(topic: topic, event: Phoenix.joinEvent)
        
        send(joinMessage) {
            (message: PhoenixMessage, error: NSError?) in
            
            // Received error
            guard error == nil else {
                self.channels[message.topic]?.isJoined = nil
                
                // Notify channel listeners
                self.listenerQueue.addOperationWithBlock {
                    [unowned self] in
                    
                    self.channels[message.topic]?.eventListeners.flatMap {$1}.forEach {
                        $0.listener?.phoenix?(self, didClose: message.topic, error: error)
                    }
                }
                
                return
            }
            
            // Received OK
            self.channels[message.topic]?.isJoined = true
            
            // Notify channel listeners
            self.listenerQueue.addOperationWithBlock {
                [unowned self] in
                
                self.channels[message.topic]?.eventListeners.flatMap {$1}.forEach {
                    $0.listener?.phoenix?(self, didJoin: message.topic)
                }
            }
            
            // Sending messages waiting channel join
            self.sendingQueue.forEach {
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
        
        join(message.topic)
        
        // Add message to queue if needed
        if !sendingQueue.contains(message) {
            message.responseHandler = responseHandler
            sendingQueue.append(message)
        }
        
        // If Phoenix is not connected, then exit. Messages are sent after connecting
        guard isConnected else {
            return
        }
        
        // If message's channel is not joined or it is not channel join message, then exit
        guard (channels[message.topic]?.isJoined ?? false) || message.event == Phoenix.joinEvent else {
            return
        }
        
        // Send data to the socket
        socket.writeString(message.json)
    }
    
    // MARK: - Receiving Messages
    
    /**
     Receives `PhoenixMessage` from the socket.
     
     - parameter message: The received message.
     */
    private func receive(message: PhoenixMessage) {
        
        // If recieved response message
        guard message.event != Phoenix.replyEvent else {
            let responseMessage = message
            
            guard let originalMessageIndex = sendingQueue.indexOf(responseMessage) else {
                return
            }
            
            let originalMessage = sendingQueue[originalMessageIndex]
            
            // Remove original message from the queue
            sendingQueue.removeAtIndex(originalMessageIndex)
            
            // Set response of the original message
            originalMessage.response = responseMessage
            
            return
        }
        
        // Received error or close the channel message
        guard message.event != Phoenix.closeEvent && message.event != Phoenix.errorEvent else {
            channels[message.topic]?.isJoined = nil
            
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
            
            listenerQueue.addOperationWithBlock {
                [unowned self] in
                
                self.channels[message.topic]?.eventListeners.flatMap {$1}.forEach {
                    $0.listener?.phoenix?(self, didClose: message.topic, error: error)
                }
            }
            
            return
        }
        
        // Received not response message
        
        // Notify channel and event listeners, channel listeners
        listenerQueue.addOperationWithBlock {
            [unowned self] in
            
            self.channels[message.topic]?.eventListeners[message.event]?.forEach {
                $0.listener?.phoenix(self, didReceive: message)
            }
            
            self.channels[message.topic]?.eventListeners["*"]?.forEach {
                $0.listener?.phoenix(self, didReceive: message)
            }
        }
    }
    
    // MARK: - Adding and Removing Listeners
    
    /**
     Adds a listener object for the specified channel topic and event.
     
     - parameter listener: The listener.
     - parameter topic: The channel's topic.
     - parameter event: The event name.
     */
    public func addListener(listener: PhoenixListener, forChannel topic: String, event: String = "*") {
        
        // Remove if already exist
        removeListener(listener, forChannel: topic, event: event)
        
        // Initiate channel
        join(topic)
        
        if channels[topic]?.eventListeners[event] == nil {
            channels[topic]?.eventListeners[event] = []
        }
        
        // Add listener object as a weak reference
        channels[topic]?.eventListeners[event]!.append(WeakPhoenixListener(listener: listener))
    }
    
    /**
     Removes the listener object for the specified channel topic and event.
     
     - parameter listener: The listener.
     - parameter topic: The channel's topic.
     - parameter event: The event name.
     */
    public func removeListener(listener: PhoenixListener, forChannel topic: String, event: String = "*") {
        
        // Remove listener
        if let eventListeners = channels[topic]?.eventListeners[event] {
            channels[topic]?.eventListeners[event] = eventListeners.filter {$0.listener !== listener}
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
        
        // Notify listeners about connection
        listenerQueue.addOperationWithBlock {
            [unowned self] in
            
            self.channels.flatMap {$1.eventListeners.flatMap {$1}}.forEach {
                $0.listener?.phoenixDidConnect?(self)
            }
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

        channels.forEach {channels[$0.0]?.isJoined = nil}
        sendingQueue = sendingQueue.filter {$0.event != Phoenix.joinEvent}
        
        // Without auto reconnection just notify listeners about disconnection
        guard autoReconnect && autoReconnectCurrentIntervalIndex <= autoReconnectIntervals.count - 1 else {
            
            listenerQueue.addOperationWithBlock {
                [unowned self] in
             
                self.channels.flatMap {$1.eventListeners.flatMap {$1}}.forEach {
                    $0.listener?.phoenixDidDisconnect?(self, error: error)
                }
            }
            
            return
        }
        
        // Auto reconnect after delay interval
        NSTimer.scheduledTimerWithTimeInterval(autoReconnectIntervals[autoReconnectCurrentIntervalIndex],
                                               target: self,
                                               selector: #selector(connect),
                                               userInfo: nil,
                                               repeats: false)
        
        autoReconnectCurrentIntervalIndex += 1
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
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
    
    /// The WebSocket URL.
    public let url: String
    
    /// The parameters, that will be added into the URL.
    public let urlParameters: [String: String]?
    
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
    private var sendingBuffer: [PhoenixMessage: (responseTimeoutTimer: DispatchSourceTimer,
                                                 responseHandler: ((_ response: PhoenixMessage, _ error: Error?) -> Void)?)] = [:]
    
    /// The response timeout (in seconds). The default value is 10 seconds.
    public var responseTimeout = 10
    
    /// The heartbeat timer.
    private var heartbeatTimer = Timer()
    
    /// The heartbeat interval (in seconds). The default value is 20 seconds.
    public var heartbeatInterval = 20
    
    /// A Boolean value that indicates a need of auto reconnections.
    public var autoReconnect = true
    
    /// The auto reconnection delay intervals (in seconds). The first try, second, third and so on. The default value is [3, 3, 3, 3, 3, 3, 3, 3, 3, 3] (30 seconds in sum).
    public var autoReconnectIntervals = [3, 3, 3, 3, 3, 3, 3, 3, 3, 3]
    
    /// An index of the current reconnection interval in the `autoReconnectIntervals` list.
    private var autoReconnectCurrentIntervalIndex = 0

    /// A Boolean value that indicates a connection status.
    public var isConnected: Bool {
        return socket.isConnected
    }

    /// The queue for all internal operations.
    private let phoenixQueue = DispatchQueue(label: "phoenix")

    /// The queue will be used to call listeners methods.
    public var listenerQueue = DispatchQueue(label: "phoenix.listener")
    
    /// The queue will be used to call send's responses.
    public var responseQueue = DispatchQueue(label: "phoenix.response", attributes: .concurrent)
    
    // MARK: - Initialization
    
    /**
     Creates the `Phoenix` object.
     
     - parameter url: The URL of the WebSocket.
     - parameter urlParameters: The parameters, that will be URL encoded and added into the URL.
     
     - returns: The `Phoenix` instance.
     */
    public init(url: String, urlParameters: [String: String]? = nil) {
        
        // Make url with parameters from components
        let urlComponents = NSURLComponents(string: url)!
        
        if let queryItems = urlParameters?.map({URLQueryItem(name: $0, value: $1)}) {
            
            if urlComponents.queryItems == nil {
                urlComponents.queryItems = queryItems
            } else {
                urlComponents.queryItems! += queryItems
            }
        }
        
        self.url = url
        self.urlParameters = urlParameters
        self.socket = WebSocket(url: urlComponents.url!)
        
        super.init()
        
        socket.callbackQueue = phoenixQueue
        socket.delegate = self
    }

    // MARK: - Connection
    
    /**
     Connects `Phoenix`.
     */
    @objc public func connect() {
        phoenixQueue.async {
            if !self.isConnected {
                self.socket.connect()
            }
        }
    }
    
    /**
     Disconnects `Phoenix`. If `autoReconnect` is true, it will be set to false.
     */
    public func disconnect() {
        phoenixQueue.async {
            self.autoReconnect = false
            
            if self.isConnected {
                self.socket.disconnect()
                
                self.channels = [:]
                self.sendingBuffer = [:]
            }
        }
    }
    
    // MARK: - Channels Management
    
    /**
     Joins the channel with specified topic.
     
     - parameter topic: The channel topic.
     */
    public func join(topic: String) {
        var needSendJoinMessage = false
        
        // If channel is not yet joined and joining is not started
        if channels[topic] == nil {
            channels[topic] = (isJoined: nil, eventListeners: [:])
        }
        
        // isJoined == nil means that joining the channel is not yet started
        if isConnected && self.channels[topic]?.isJoined == nil {
            
            // isJoined == false means that joining started but not yet completed
            channels[topic]?.isJoined = false
            
            // Need to send join message
            needSendJoinMessage = true
        }
        
        guard needSendJoinMessage else {
            return
        }

        // Send join message with special response handler
        let joinMessage = PhoenixMessage(topic: topic, event: Phoenix.joinEvent)
        
        send(joinMessage) {
            (message: PhoenixMessage, error: Error?) in
        
            self.phoenixQueue.async {
                
                // Join failed
                guard error == nil else {
                    
                    // Reset channel joining status
                    self.channels[message.topic]?.isJoined = nil
                    
                    // Notify channel listeners about joining error
                    let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                    
                    self.listenerQueue.async {
                        eventListeners?.forEach {
                            $0.listener?.phoenix(self, didClose: message.topic, error: error)
                        }
                    }
                    
                    return
                }
                
                // Successful join
                
                // Set channel status to is joined
                self.channels[message.topic]?.isJoined = true
                
                // Notify channel listeners about successful joining
                let eventListeners = self.channels[message.topic]?.eventListeners.flatMap {$1}
                
                self.listenerQueue.async {
                    eventListeners?.forEach {
                        $0.listener?.phoenix(self, didJoin: message.topic)
                    }
                }
                
                // Sending messages waiting channel join
                self.sendingBuffer.forEach {
                    if $0.0.topic == message.topic {
                        self.send($0.0)
                    }
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
    public func send(_ message: PhoenixMessage,
                     responseHandler: ((_ response: PhoenixMessage, _ error: Error?) -> Void)? = nil) {
        
        phoenixQueue.async {
            
            // Join the channel (if needed)
            self.join(topic: message.topic)
            
            // Add message to the queue if needed
            if self.sendingBuffer[message] == nil {
                
                // Create and set response timeout timer
                
                let responseTimeoutTimer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0),
                                                                          queue: self.responseQueue)
                
                responseTimeoutTimer.schedule(deadline: .now() + .seconds(self.responseTimeout),
                                              repeating: .seconds(self.responseTimeout),
                                              leeway: .nanoseconds(1))
                
                
                // If the timer is triggered, cancel it, find and delete message from sending queue and call message's response handler with timeout error
                responseTimeoutTimer.setEventHandler {

                    responseTimeoutTimer.cancel()
                    
                    self.phoenixQueue.async {

                        if self.sendingBuffer.removeValue(forKey: message) != nil {
                            
                            self.responseQueue.async {
                                
                                let errorReason = "Response timeout expired."
                                let errorDescription = "PhoenixMessage failed to send: response timeout expired."
                                
                                let error = NSError(domain: "phoenix.message.error",
                                                    code: 2,
                                                    userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                                               NSLocalizedDescriptionKey: errorDescription])
                                
                                let payload: [String: AnyObject] = ["status": "error" as AnyObject,
                                                                    "response": ["reason": errorReason,
                                                                                 "error": errorDescription] as AnyObject]

                                let response = PhoenixMessage(topic: message.topic,
                                                              event: Phoenix.replyEvent,
                                                              payload: payload)
                                
                                responseHandler?(response, error)
                            }
                        }
                    }
                }
                
                responseTimeoutTimer.resume()
                
                self.sendingBuffer[message] = (responseTimeoutTimer: responseTimeoutTimer,
                                               responseHandler: responseHandler)
            }
            
            let isChannelJoined = self.channels[message.topic]?.isJoined ?? false
            
            // Send message if phoenix is connected, channel joined (or it's a join channel message) and message's response is empty
            if self.isConnected && (isChannelJoined || message.event == Phoenix.joinEvent) {
                self.socket.write(string: message.json)
            }
        }
    }
    
    // MARK: - Receiving Messages
    
    /**
     Receives `PhoenixMessage` from the socket.
     
     - parameter message: The received message.
     */
    private func receive(_ message: PhoenixMessage) {
        
        switch message.event {
            
        // Response message
        case Phoenix.replyEvent:
            
            let responseMessage = message
            
            // If original message found, delete it and call response handler
            if let originalMessage = sendingBuffer.removeValue(forKey: responseMessage) {
                
                // Stop response timeout timer
                originalMessage.responseTimeoutTimer.cancel()
                
                // Execute response handler
                responseQueue.async {
                    
                    // Error response
                    guard responseMessage.payload?["status"] as? String == "ok" else {
                        
                        let errorReason = responseMessage.payload?["response"]?["reason"] as? String
                                          ??
                                          responseMessage.payload?["response"]?["error"] as? String
                                          ?? ""
                        
                        let errorDescription = "PhoenixMessage failed to send: \(errorReason)"
                        
                        let error = NSError(domain: "phoenix.message.error",
                                            code: 0,
                                            userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                                       NSLocalizedDescriptionKey: errorDescription])
                        
                        originalMessage.responseHandler?(responseMessage, error)
                        
                        return
                    }
                    
                    // Successful response
                    originalMessage.responseHandler?(responseMessage, nil)
                }
            }
            
        // Error or close channel message
        case Phoenix.errorEvent, Phoenix.closeEvent:
            
            channels[message.topic]?.isJoined = nil
            
            // Notify channel listeners
            let errorReason = message.payload?["response"]?["reason"] as? String
                              ??
                              message.payload?["response"]?["error"] as? String
                              ?? ""
            
            let errorDescription = "Channel is closed by the server because: \(errorReason)"
            
            let error = NSError(domain: "phoenix.channel.error",
                                code: 1,
                                userInfo: [NSLocalizedFailureReasonErrorKey: errorReason,
                                           NSLocalizedDescriptionKey: errorDescription])
            
            // Notify channel listeners about channel error or closing
            let eventListeners = channels[message.topic]?.eventListeners.flatMap {$1}
            
            listenerQueue.async {
                eventListeners?.forEach {
                    $0.listener?.phoenix(self, didClose: message.topic, error: error)
                }
            }
            
        // Standard message
        default:
            
            // Notify channel and event listeners, channel listeners
            let eventListeners = (channels[message.topic]?.eventListeners[message.event] ?? []) +
                                 (channels[message.topic]?.eventListeners["*"] ?? [])
            
            listenerQueue.async {
                eventListeners.forEach {
                    $0.listener?.phoenix(self, didReceive: message)
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

        phoenixQueue.async {
            
            // Asterisk is equal to all events of the channel
            let event = event ?? "*"
            
            // If listener already exists, do not add it again
            let needAddListener = !(self.channels[topic]?.eventListeners[event]?.contains(where: {$0.listener === listener}) ?? false)
            
            guard needAddListener else {
                return
            }
            
            // Join the channel (if needed)
            self.join(topic: topic)
            
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
        
        phoenixQueue.async {
            
            // If event == nil, then remove listener from all events
            guard let event = event else {
                
                self.channels[topic]?.eventListeners.forEach {
                    if let index = self.channels[topic]?.eventListeners[$0.0]?.index(where: {$0.listener === listener}) {
                        self.channels[topic]?.eventListeners[$0.0]?.remove(at: index)
                    }
                }
                
                return
            }
            
            // Otherwise, from specified event
            if let index = self.channels[topic]?.eventListeners[event]?.index(where: {$0.listener === listener}) {
                self.channels[topic]?.eventListeners[event]?.remove(at: index)
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
            
            socket.write(string: heartbeatMessage.json)
        }
    }
    
    // MARK: - WebSocketDelegate
    
    /// :nodoc:
    public func websocketDidConnect(socket: WebSocketClient) {
        
        // If this is the initial connection, then notify listeners about connection
        if autoReconnectCurrentIntervalIndex == 0 {
            
            // Needed only unique listeners
            var uniqueEventListeners = [WeakPhoenixListener]()
            
            channels.flatMap {$1.eventListeners.flatMap {$1}}.forEach {
                (eventListener: WeakPhoenixListener) in
                
                if !uniqueEventListeners.contains(where: {$0.listener === eventListener.listener}) {
                    uniqueEventListeners.append(eventListener)
                }
            }
            
            listenerQueue.async {
                uniqueEventListeners.forEach {
                    $0.listener?.phoenixDidConnect(self)
                }
            }
        }
        
        // Rejoin all channels
        channels.forEach {join(topic: $0.0)}
        
        // Start heartbeat
        DispatchQueue.main.async {
            self.heartbeatTimer.invalidate()
            self.heartbeatTimer = Timer.scheduledTimer(timeInterval: Double(self.heartbeatInterval),
                                                       target: self,
                                                       selector: #selector(self.sendHeartbeat),
                                                       userInfo: nil,
                                                       repeats: true)
        }
        
        autoReconnectCurrentIntervalIndex = 0
    }
    
    /// :nodoc:
    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {

        heartbeatTimer.invalidate()
        channels.forEach {channels[$0.0]?.isJoined = nil}
        
        // Remove join event messages
        sendingBuffer.forEach {
            if $0.0.event == Phoenix.joinEvent {
                sendingBuffer.removeValue(forKey: $0.0)
            }
        }
        
        if autoReconnect && autoReconnectCurrentIntervalIndex <= autoReconnectIntervals.count - 1 {
            
            // Auto reconnect after delay interval
            DispatchQueue.main.async {
                Timer.scheduledTimer(timeInterval: Double(self.autoReconnectIntervals[self.autoReconnectCurrentIntervalIndex]),
                                     target: self,
                                     selector: #selector(self.connect),
                                     userInfo: nil,
                                     repeats: false)

                self.autoReconnectCurrentIntervalIndex += 1
            }
            
        } else {
            
            // Notify unique listeners about disconnection
            var uniqueEventListeners = [WeakPhoenixListener]()
            
            channels.flatMap {$1.eventListeners.flatMap {$1}}.forEach {
                (eventListener: WeakPhoenixListener) in
                
                if !uniqueEventListeners.contains(where: {$0.listener === eventListener.listener}) {
                    uniqueEventListeners.append(eventListener)
                }
            }
            
            listenerQueue.async {
                uniqueEventListeners.forEach {
                    $0.listener?.phoenixDidDisconnect(self, error: error)
                }
            }
            
            autoReconnectCurrentIntervalIndex = 0
        }
    }
    
    /// :nodoc:
    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        receive(PhoenixMessage(json: text))
    }
    
    /// :nodoc:
    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        websocketDidReceiveMessage(socket: socket, text: String(data: data, encoding: String.Encoding.utf8)!)
    }
}

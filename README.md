# Phoenix

[![Carthage compatible](https://img.shields.io/badge/Carthage-compatible-4BC51D.svg?style=flat)](https://github.com/Carthage/Carthage)
[![Platform](https://img.shields.io/badge/platform-ios-lightgrey.svg)]()

## Description
The `Phoenix` class provides a convenient mechanism to communicate with [Phoenix Framework Channels](http://www.phoenixframework.org/docs/channels).

## Requirements
- iOS 8.0+
- Xcode 7.3+

## Dependencies
- [Starscream](https://github.com/daltoniam/Starscream)

## Installation
### Carthage

To integrate `Phoenix` into your project using [Carthage](https://github.com/Carthage/Carthage), specify it in your `Cartfile`:

```
github "valery-bashkatov/Phoenix"
```
And then follow the [instructions](https://github.com/Carthage/Carthage#if-youre-building-for-ios-tvos-or-watchos) to install the framework and its dependencies.

## Documentation
API Reference is located at [http://valery-bashkatov.github.io/Phoenix](http://valery-bashkatov.github.io/Phoenix).

## Usage

```swift
import Phoenix

class RadioController: NSObject, PhoenixListener {

    var phoenix: Phoenix

    override init() {
        phoenix = Phoenix(url: NSURL(string: "ws://sample.com/websocket")!)
        
        super.init()

        phoenix.connect()
        phoenix.addListener(self, forChannel: "radio", event: "new_message")

        let message = PhoenixMessage(topic: "radio", event: "ping")

		phoenix.send(message) {
			(message: PhoenixMessage, error: NSError?) in
            
    		guard error == nil else {
    			print(error)
    			return
    		}

	    	print(message)
	    	print(message.response!.payload)
		}
    }
    
    func phoenix(phoenix: Phoenix, didReceive message: PhoenixMessage) {
    	print("Received message: \(message)")
    }
    
    func phoenix(phoenix: Phoenix, didJoin topic: String) {
        print("Channel \(topic) joined")
    }
    
    func phoenix(phoenix: Phoenix, didClose topic: String, error: NSError?) {
        print("Channel \(topic) closed with error: \(error)")
    }
    
    func phoenixDidConnect(phoenix: Phoenix) {
        print("Phoenix connected")
    }
    
    func phoenixDidDisconnect(phoenix: Phoenix, error: NSError?) {
        print("Phoenix disconnected")
    }
}
```
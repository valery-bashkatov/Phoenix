# Phoenix
The `Phoenix` class provides a convenient mechanism to communicate with [Phoenix Framework Channels](http://www.phoenixframework.org/docs/channels).

## Requirements
- iOS 9.0+

## Dependencies
- [Starscream](https://github.com/daltoniam/Starscream)

## Installation
### Carthage
To integrate `Phoenix` into your project using [Carthage](https://github.com/Carthage/Carthage), specify it in your `Cartfile`:

```
github "valery-bashkatov/Phoenix" ~> 1.0.2
```
And then follow the [instructions](https://github.com/Carthage/Carthage#if-youre-building-for-ios-tvos-or-watchos) to install the framework and its dependencies.

## Documentation
API Reference is located at [http://valery-bashkatov.github.io/Phoenix](http://valery-bashkatov.github.io/Phoenix).

## Sample
```swift
import Phoenix

class RadioController: PhoenixListener {

    var phoenix: Phoenix

    init() {
        phoenix = Phoenix(url: "ws://sample.com/websocket")

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

## Edit by telegramd

### Introduce

Default connect to telegramd test server.

If you want to connect to your own server, you can modify the following code:

```
submodules/TelegramCore/TelegramCore/Network.swift
L371
            if testingEnvironment {
                seedAddressList = [
                    1: "127.0.0.1",
                    2: "127.0.0.1"
                  
                ]
            } else {
                seedAddressList = [
                    1: "127.0.0.1",
                    2: "127.0.0.1",
                    3: "127.0.0.1",
                    4: "127.0.0.1",
                    5: "127.0.0.1"
                ]
            }

```

### Compile


### Feedback
Please report bugs, concerns, suggestions by issues, or join telegram group [Telegramd](https://t.me/joinchat/D8b0DRJiuH8EcIHNZQmCxQ) to discuss problems around source code.


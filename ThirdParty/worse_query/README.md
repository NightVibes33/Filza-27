# worse_query

### A sandbox escape for iOS 26.0 - 26.7.2 / 27.2.

This is a proof-of-concept for developers and isn't useful by itself.

worse_query is the direct successor to [bad_query](https://github.com/forcequitOS/bad_query) and essentially replaces it. To use worse_query, you'll have to set up an App Group container for your app.

worse_query can access these paths:

```
/var/containers/Data/System (iOS 27)
/var/containers/Shared/SystemGroup/* (iOS 27)
/var/mobile/Containers/Data/Application/*
/var/mobile/Containers/Data/InternalDaemon/*
/var/mobile/Containers/Data/PluginKitPlugin/*
/var/mobile/Containers/Shared/AppGroup/*
/var/mobile/Containers/Shared/AppGroup (iOS 27)
```

<sub>**This is not relevant to a jailbreak and never will be.** Please don't mislead people into believing otherwise.</sub>
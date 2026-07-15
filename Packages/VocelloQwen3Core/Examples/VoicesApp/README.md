# Examples

## VoicesApp Initial Setup

Create a local config file:

```sh
   cp Examples/VoicesApp/Config/Local.xcconfig.template Examples/VoicesApp/Config/Local.xcconfig
```

Edit `Examples/VoicesApp/Config/Local.xcconfig` and set:

`APP_BUNDLE_ID` to something unique (e.g. `com.yourname.VoicesApp`)

`DEVELOPMENT_TEAM` to your Apple Developer Team ID

Open `Examples/VoicesApp/VoicesApp.xcodeproj` in Xcode and build.



```sh
xcodebuild \
  -scheme VoicesApp \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

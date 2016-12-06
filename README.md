##WebRTC Build Scripts

A set of build scripts useful for building WebRTC libraries for iOS.

###iOS (armv7, arm64, i386) and Mac (X86_64) -- [Guide here](http://tech.pristine.io/build-ios-apprtc/)
These steps must be run on Mac OSX

Source the [ios build scripts](/ios/build.sh)

```shell
source ios/build.sh
```

Specify if you want to build for Debug/Profile/Release by setting either WEBRTC_DEBUG, WEBRTC_PROFILE, WEBRTC_RELEASE as an environment variable in your bash or xcode scheme run settings.
```shell
WEBRTC_DEBUG=true
WEBRTC_PROFILE=true 
#or
WEBRTC_RELEASE=true
```


#### Building the libraries

Then you can build the iOS example
```shell
# We use the term webrtc dance a lot to build 
dance

# Or in two steps
get_webrtc
# Make changes then build WebRTC
build_webrtc
```
Mac example
```shell
# Get WebRTC
get_webrtc
# Make changes then build WebRTC
build_webrtc_mac
```


Check which [revision](https://code.google.com/p/webrtc/source/list) you are using at ./webrtc-build-scripts/ios/webrtc/libWebRTC-LATEST-Universal-Debug.a.version.txt

You can also build a particular [revision](https://code.google.com/p/webrtc/source/list)
```shell
    #Pull WebRTC
    update2Revision 6783
```
Make changes then,
```shell
    #Build WebRTC
    build_webrtc
```
Make sure you label your new binaries that are generated in 
```shell
./webrtc-build-scripts/ios/webrtc/libWebRTC_builds 
```

###### Requirements
A fast internet connection.... for your own sanity


###### Versioning

The versioning can be explained as follows:

 
[6931](https://code.google.com/p/webrtc/source/detail?r=6931).2.0 

6931 reflects the SVN revision from the WebRTC root Google Code Project

2 reflects a Release Build (0 for Debug, 1 for Profile)

Profile builds are no longer built by default

The minor 0 reflects any changes I might need to make to the sample xcode project itself to work (incremented normally)



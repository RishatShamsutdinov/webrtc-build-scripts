#!/bin/sh

#  build.sh
#  WebRTC
#
#  Created by Rahul Behera on 6/18/14.
#  Copyright (c) 2014 Pristine, Inc. All rights reserved.

set -e

function resolve_link() {
    local path="$1"

    # resolve symlinks
    while [ -h $path ]; do
        # 1) cd to directory of the symlink
        # 2) cd to the directory of where the symlink points
        # 3) get the pwd
        # 4) append the basename
        local dir=$(dirname -- "$path")
        local sym=$(readlink $path)
        path=$(cd $dir && cd $(dirname -- "$sym") && pwd)/$(basename -- "$sym")
    done

    echo "$path"
}

SOURCE=`resolve_link "${BASH_SOURCE[0]}"`
PROJECT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

DEFAULT_WEBRTC_URL="https://chromium.googlesource.com/external/webrtc"
DEFAULT_POD_URL="https://s3.amazonaws.com/libjingle"
WEBRTC="$PROJECT_DIR/webrtc"
DEPOT_TOOLS="$PROJECT_DIR/depot_tools"
BUILD="$WEBRTC/libWebRTC_builds"
WEBRTC_TARGET="rtc_sdk_objc"
MAC_SDK="10.11"
SHOULD_PULL_TOOLS=true
OUT_LIB_REL_PATH="obj/sdk/lib$WEBRTC_TARGET.a"

function create_directory_if_not_found() {
    if [ ! -d "$1" ];
    then
        mkdir -v "$1"
    fi
}

function exec_strip() {
  echo "Running strip"
  strip -S -X "$@"
}

function exec_ninja() {
  echo "Generating target"

  gn gen "$1" --args="$GN_ARGS"

  echo "Running ninja"

  ninja -C $1 -t clean
  ninja -C $1 $WEBRTC_TARGET
}

create_directory_if_not_found "$PROJECT_DIR"
create_directory_if_not_found "$WEBRTC"

# Update/Get/Ensure the Gclient Depot Tools
function pull_depot_tools() {
    if [[ $SHOULD_PULL_TOOLS = true ]]; then
        SHOULD_PULL_TOOLS=false

        echo Get the current working directory so we can change directories back when done
        WORKING_DIR=`pwd`

        echo If no directory where depot tools should be...
        if [ ! -d "$DEPOT_TOOLS" ]
        then
            echo Make directory for gclient called Depot Tools
            mkdir -p "$DEPOT_TOOLS"

            echo Pull the depot tools project from chromium source into the depot tools directory
            git clone "https://chromium.googlesource.com/chromium/tools/depot_tools.git" "$DEPOT_TOOLS"

        else

            echo Change directory into the depot tools
            cd "$DEPOT_TOOLS"

            echo Pull the depot tools down to the latest
            git pull
        fi
        PATH="$PATH:$DEPOT_TOOLS"
        echo "Go back to working directory"
        cd "$WORKING_DIR"
    fi
}

function choose_code_signing() {
    if [ "$WEBRTC_TARGET" == "AppRTCDemo" ]; then
        echo "AppRTCDemo target requires code signing since we are building an *.ipa"
        if [[ -z $IDENTITY ]]
        then
            COUNT=$(security find-identity -v | grep -c "iPhone Developer")
            if [[ $COUNT -gt 1 ]]
            then
              security find-identity -v
              echo "Please select your code signing identity index from the above list:"
              read INDEX
              IDENTITY=$(security find-identity -v | awk -v i=$INDEX -F "\\\) |\"" '{if (i==$1) {print $3}}')
            else
              IDENTITY=$(security find-identity -v | grep "iPhone Developer" | awk -F "\) |\"" '{print $3}')
            fi
            echo Using code signing identity $IDENTITY
        fi
        sed -i -e "s/\'CODE_SIGN_IDENTITY\[sdk=iphoneos\*\]\': \'iPhone Developer\',/\'CODE_SIGN_IDENTITY[sdk=iphoneos*]\': \'$IDENTITY\',/" $WEBRTC/src/build/common.gypi
    fi
}

function wrbase() {
    local is_debug

    if [[ $$WEBRTC_DEBUG = true ]]; then
        is_debug=true
    else
        is_debug=false
    fi

	export GN_ARGS="$GLOBAL_GN_ARGS is_component_build=false is_debug=$is_debug"
}

function wrbase_ios() {
    wrbase

    export GN_ARGS="$GN_ARGS target_os=\"ios\""
}

# Add the iOS Device specific defines on top of the base
function wrios_armv7() {
    wrbase_ios

    export GN_ARGS="$GN_ARGS target_cpu=\"arm\""
}

# Add the iOS ARM 64 Device specific defines on top of the base
function wrios_armv8() {
    wrbase_ios

    export GN_ARGS="$GN_ARGS target_cpu=\"arm64\""
}

# Add the iOS Simulator X86 specific defines on top of the base
function wrX86() {
    wrbase_ios

    export GN_ARGS="$GN_ARGS target_cpu=\"x86\""
}

# Add the iOS Simulator X64 specific defines on top of the base
function wrX86_64() {
    wrbase_ios

    export GN_ARGS="$GN_ARGS target_cpu=\"x64\""

    if [[ $WEBRTC_DEBUG = false ]]; then
        export GN_ARGS="$GN_ARGS is_msan=true"
    fi
}

# Add the Mac 64 bit intel defines
function wrMac64() {
    wrbase

    export GN_ARGS="$GN_ARGS target_os=\"mac\" target_cpu=\"x64\" mac_sdk_version=\"$MAC_SDK\""
}

# Gets the revision number of the current WebRTC svn repo on the filesystem
function get_revision_number() {
    DIR=`pwd`
    cd "$WEBRTC/src"

    REVISION_NUMBER=`git log -1 | grep "Cr-Commit-Position: refs/branch-heads/$BRANCH@{#" | grep -v '>' | egrep -o "[0-9]+" | awk 'NR%2{printf $0"-";next;}1'`

    if [ -z "$REVISION_NUMBER" ]
    then
        REVISION_NUMBER=`git log -1 | grep "Cr-Commit-Position: refs/heads/master@{#" | grep -v '>' | egrep -o "[0-9]+}" | tr -d '}'`
    fi

    if [ -z "$REVISION_NUMBER" ]
    then
        REVISION_NUMBER=`git log -1 | grep 'Cr-Commit-Position: refs/branch-heads/' | grep -v '>' | egrep -o "[0-9]+" | awk 'NR%2{printf $0"-";next;}1'`
    fi

    if [ -z "$REVISION_NUMBER" ]
    then
        REVISION_NUMBER=`git describe --tags | sed 's/\([0-9]*\)-.*/\1/'`
    fi

    if [ -z "$REVISION_NUMBER" ]
    then
        echo "Error grabbing revision number"
        exit 1
    fi

    echo $REVISION_NUMBER
    cd "$DIR"
}

# This function allows you to pull the latest changes from WebRTC without doing an entire clone, much faster to build and try changes
# Pass in a revision number as an argument to pull that specific revision ex: update2Revision 6798
function update2Revision() {
    # Ensure that we have gclient added to our environment, so this function can run standalone
    pull_depot_tools
    cd "$WEBRTC"

    # Setup gclient config
    echo Configuring gclient for iOS build
    if [ -z $USER_WEBRTC_URL ]
    then
        echo "User has not specified a different webrtc url. Using default"
        gclient config --unmanaged --name=src "$DEFAULT_WEBRTC_URL"
    else
        echo "User has specified their own webrtc url $USER_WEBRTC_URL"
        gclient config  --unmanaged --name=src "$USER_WEBRTC_URL"
    fi

    # # Make sure that the target os is set to JUST MAC at first by adding that to the .gclient file that gclient config command created
    # # Note this is a workaround until one of the depot_tools/ios bugs has been fixed
    # echo "target_os = ['mac']" >> .gclient
    # if [ -z $1 ]
    # then
    #     sync
    # else
    #     sync "$1"
    # fi

    # # Delete the last line saying we will only build for mac
    # sed -i "" '$d' .gclient

    # Write mac and ios to the target os in the gclient file generated by gclient config
    echo "target_os = ['ios', 'mac']" >> .gclient

    if [ -z $1 ]
    then
        sync
    else
        sync "$1"
    fi

    echo "-- webrtc has been successfully updated"
}

# This function cleans out your webrtc directory and does a fresh clone -- slower than a pull
# Pass in a revision number as an argument to clone that specific revision ex: clone 6798
function clone() {
    DIR=`pwd`

    rm -rf "$WEBRTC"
    mkdir -v "$WEBRTC"

    update2Revision "$1"
}

# Fire the sync command. Accepts an argument as the revision number that you want to sync to
function sync() {
    pull_depot_tools
    cd "$WEBRTC"
    choose_code_signing

    local buggy_third_party="$WEBRTC/src/third_party/gflags"

    if [ -d "$buggy_third_party" ]; then
        rm -rf "$buggy_third_party"
    fi

    cd "$WEBRTC/src"

    if [ -d '.git' ]; then
        gclient revert
    fi

    gclient sync --with_branch_heads

    git fetch origin "refs/branch-heads/$1"
    git checkout FETCH_HEAD

    gclient sync --jobs 16

    cd -

    if [ "$WEBRTC_TARGET" == "rtc_sdk_objc" ] ; then
        patch_files
    fi
}

function patch_files () {
    echo "Patching files"

    if [[ $WEBRTC_USE_OPENSSL = true ]]; then
        cd "$WEBRTC/src"

        git apply "$PATCH_PATH"

        cd -

        patch_configs
    fi
}

function patch_configs() {
    perl -0777 -pi -e "s/(deps\s*=\s*\[\s*\"\/\/third_party\/boringssl\",?\s*\])//sg" "$WEBRTC/src/third_party/usrsctp/BUILD.gn"
    perl -0777 -pi -e "s/(include_dirs\s*=\s*\[)/\1\nrtc_ssl_root,/sg" "$WEBRTC/src/third_party/usrsctp/BUILD.gn"
    perl -0777 -pi -e "s/(include_dirs\s*=\s*\[)/import(\"\/\/webrtc.gni\")\n\n\1/sg" "$WEBRTC/src/third_party/usrsctp/BUILD.gn"
    
    perl -0777 -pi -e "s/\"\/\/third_party\/boringssl\:boringssl\",?//sg" "$WEBRTC/src/third_party/libsrtp/BUILD.gn"
    perl -0777 -pi -e "s/(include_dirs\s*=\s*\[[^]]+\])/\1\ninclude_dirs += [ rtc_ssl_root ]/sg" "$WEBRTC/src/third_party/libsrtp/BUILD.gn"
    perl -0777 -pi -e "s/(declare_args\(\))/import(\"\/\/webrtc.gni\")\n\n\1/sg" "$WEBRTC/src/third_party/libsrtp/BUILD.gn"
}

# Convenience function to copy the headers by creating a symbolic link to the headers directory deep within webrtc src
function copy_headers() {
    create_directory_if_not_found "$BUILD"

    if [ ! -h "$WEBRTC/headers" ]; then
        ln -s "$WEBRTC/src/sdk/objc/Framework/Headers" "$WEBRTC/headers" || true
    fi
}

function build_webrtc_mac() {
    if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX$MAC_SDK.sdk" ]
      then
      echo "Found $MAC_SDK sdk"
      cd "$WEBRTC/src"

      wrMac64
      export MACOSX_DEPLOYMENT_TARGET="$MAC_SDK"

      choose_code_signing

      copy_headers

      WEBRTC_REVISION=`get_revision_number`
      if [ "$WEBRTC_DEBUG" = true ] ; then
          exec_ninja "out_mac_x86_64/Debug/"
          cp -f "$WEBRTC/src/out_mac_x86_64/Debug/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-mac-x86_64-Debug.a"
      fi

      if [ "$WEBRTC_RELEASE" = true ] ; then
          exec_ninja "out_mac_x86_64/Release/"
          cp -f "$WEBRTC/src/out_mac_x86_64/Release/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-mac-x86_64-Release.a"
          exec_strip "$BUILD/libWebRTC-$WEBRTC_REVISION-mac-x86_64-Release.a"
      fi
    else
      echo "Change the OSX Target by changing the MAC_SDK environment variable to 10.9. There is a bug with building mac target 10.10 (it assumes its 10.1 and lower than 10.8)"
      echo "---------- OR ----------"
      echo "Please download Xcode 5.1.1 (http://adcdownload.apple.com/Developer_Tools/xcode_5.1.1/xcode_5.1.1.dmg) and open"
      echo "Copy the MacOSX10.8.sdk from the DMG to the current Xcode SDK"
      echo "sudo cp -a /Volumes/Xcode/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.8.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs"
      exit 1
    fi
}

function prepare_for_ios_build() {
    choose_code_signing
    copy_headers

    WEBRTC_REVISION=`get_revision_number`
}

# Build AppRTC Demo for the simulator (ia32 architecture)
function build_apprtc_sim() {
    cd "$WEBRTC/src"

    wrX86
    prepare_for_ios_build

    if [ "$WEBRTC_DEBUG" = true ] ; then
        exec_ninja "out_ios_x86/Debug-iphonesimulator/"
        cp -f "$WEBRTC/src/out_ios_x86/Debug-iphonesimulator/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86-Debug.a"
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        exec_ninja "out_ios_x86/Profile-iphonesimulator/"
        cp -f "$WEBRTC/src/out_ios_x86/Profile-iphonesimulator/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86-Profile.a"
    fi

    if [ "$WEBRTC_RELEASE" = true ] ; then
        exec_ninja "out_ios_x86/Release-iphonesimulator/"
        cp -f "$WEBRTC/src/out_ios_x86/Release-iphonesimulator/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86-Release.a"
        exec_strip "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86-Release.a"
    fi
}

# Build AppRTC Demo for the 64 bit simulator (x86_64 architecture)
function build_apprtc_sim64() {
    cd "$WEBRTC/src"

    wrX86_64
    prepare_for_ios_build

    if [ "$WEBRTC_DEBUG" = true ] ; then
        exec_ninja "out_ios_x86_64/Debug-iphonesimulator/"
        cp -f "$WEBRTC/src/out_ios_x86_64/Debug-iphonesimulator/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86_64-Debug.a"
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        exec_ninja "out_ios_x86_64/Profile-iphonesimulator/"
        cp -f "$WEBRTC/src/out_ios_x86_64/Profile-iphonesimulator/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86_64-Profile.a"
    fi

    if [ "$WEBRTC_RELEASE" = true ] ; then
        exec_ninja "out_ios_x86_64/Release-iphonesimulator/"
        cp -f "$WEBRTC/src/out_ios_x86_64/Release-iphonesimulator/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86_64-Release.a"
        exec_strip "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86_64-Release.a"
    fi
}

# Build AppRTC Demo for a real device
function build_apprtc() {
    cd "$WEBRTC/src"

    wrios_armv7
    prepare_for_ios_build

    if [ "$WEBRTC_DEBUG" = true ] ; then
        exec_ninja "out_ios_armeabi_v7a/Debug-iphoneos/"
        cp -f "$WEBRTC/src/out_ios_armeabi_v7a/Debug-iphoneos/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-armeabi_v7a-Debug.a"
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        exec_ninja "out_ios_armeabi_v7a/Profile-iphoneos/"
        cp -f "$WEBRTC/src/out_ios_armeabi_v7a/Profile-iphoneos/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-armeabi_v7a-Profile.a"
    fi

    if [ "$WEBRTC_RELEASE" = true ] ; then
        exec_ninja "out_ios_armeabi_v7a/Release-iphoneos/"
        cp -f "$WEBRTC/src/out_ios_armeabi_v7a/Release-iphoneos/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-armeabi_v7a-Release.a"
        exec_strip "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-armeabi_v7a-Release.a"
    fi
}


# Build AppRTC Demo for an armv7 real device
function build_apprtc_arm64() {
    cd "$WEBRTC/src"

    wrios_armv8
    prepare_for_ios_build

    if [ "$WEBRTC_DEBUG" = true ] ; then
        exec_ninja "out_ios_arm64_v8a/Debug-iphoneos/"
        cp -f "$WEBRTC/src/out_ios_arm64_v8a/Debug-iphoneos/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-arm64_v8a-Debug.a"
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        exec_ninja "out_ios_arm64_v8a/Profile-iphoneos/"
        cp -f "$WEBRTC/src/out_ios_arm64_v8a/Profile-iphoneos/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-arm64_v8a-Profile.a"
    fi

    if [ "$WEBRTC_RELEASE" = true ] ; then
        exec_ninja "out_ios_arm64_v8a/Release-iphoneos/"
        cp -f "$WEBRTC/src/out_ios_arm64_v8a/Release-iphoneos/$OUT_LIB_REL_PATH" "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-arm64_v8a-Release.a"
        exec_strip "$BUILD/libWebRTC-$WEBRTC_REVISION-ios-arm64_v8a-Release.a"
    fi
}

# This function is used to put together the intel (simulator), armv7 and arm64 builds (device) into one static library so its easy to deal with in Xcode
# Outputs the file into the build directory with the revision number
function lipo_intel_and_arm() {
    if [ "$WEBRTC_DEBUG" = true ] ; then
        lipo_for_configuration "Debug"
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        lipo_for_configuration "Profile"
    fi

    if [ "$WEBRTC_RELEASE" = true ] ; then
        lipo_for_configuration "Release"
    fi
}

function lipo_for_configuration() {
    CONFIGURATION=$1
    WEBRTC_REVISION=`get_revision_number`

    # Directories to use for lipo, armv7 and ia32 as default
    LIPO_DIRS="$BUILD/libWebRTC-$WEBRTC_REVISION-ios-armeabi_v7a-$CONFIGURATION.a"
    # Add ARM64
    LIPO_DIRS="$LIPO_DIRS $BUILD/libWebRTC-$WEBRTC_REVISION-ios-arm64_v8a-$CONFIGURATION.a"
    # Add x86
    LIPO_DIRS="$LIPO_DIRS $BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86-$CONFIGURATION.a"
    # and add x86_64
    LIPO_DIRS="$LIPO_DIRS $BUILD/libWebRTC-$WEBRTC_REVISION-ios-x86_64-$CONFIGURATION.a"

    # Lipo the simulator build with the ios build into a universal library
    lipo -create -output "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a" $LIPO_DIRS 

    # Delete the latest symbolic link just in case :)
    if [ -a "$WEBRTC/libWebRTC-LATEST-Universal-$CONFIGURATION.a" ]
    then
        rm "$WEBRTC/libWebRTC-LATEST-Universal-$CONFIGURATION.a"
    fi

    # Create a symbolic link pointing to the exact revision that is the latest. This way I don't have to change the xcode project file every time we update the revision number, while still keeping it easy to track which revision you are on
    ln -sf "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a" "$WEBRTC/libWebRTC-LATEST-Universal-$CONFIGURATION.a"

    # Make it clear which revision you are using .... You don't want to get in the state where you don't know which revision you were using... trust me
    echo "The libWebRTC-LATEST-Universal-$CONFIGURATION.a in this same directory, is revision " > "$WEBRTC/libWebRTC-LATEST-Universal-$CONFIGURATION.a.version.txt"

    # Also write to a file for funzies
    echo $WEBRTC_REVISION >> "$WEBRTC/libWebRTC-LATEST-Universal-$CONFIGURATION.a.version.txt"

    # Write the version down to a file
    echo "Architectures Built" >> "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a.version.txt"
    echo "ia32 - Intel x86" >> "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a.version.txt"
    echo "ia64 - Intel x86_64" >> "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a.version.txt"
    echo "armv7 - Arm x86" >> "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a.version.txt"
    echo "arm64_v8a - Arm 64 (armv8)" >> "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-$CONFIGURATION.a.version.txt"
}

# Convenience method to just "get webrtc" -- a clone
# Pass in an argument if you want to get a specific webrtc revision
function get_webrtc() {
    pull_depot_tools
    update2Revision "$1"
}

# Build webrtc for an ios device and simulator, then create a universal library
function build_webrtc() {
    pull_depot_tools
    build_apprtc
    build_apprtc_arm64
    build_apprtc_sim
    build_apprtc_sim64
    lipo_intel_and_arm
}

# Create the static library, requires an argument specifiying Debug or Release
function create_archive_of_static_libraries() {
    echo Get the current working directory so we can change directories back when done
    WORKING_DIR=`pwd`
    VERSION_BUILD=0
    WEBRTC_REVISION=`get_revision_number`

    echo "Creating Static Library"
    create_directory_if_not_found "$BUILD/archives"
    rm -rf "$BUILD/archives/$WEBRTC_REVISION/$1"
    create_directory_if_not_found "$BUILD/archives/$WEBRTC_REVISION"
    create_directory_if_not_found "$BUILD/archives/$WEBRTC_REVISION/$1"
    
    create_directory_if_not_found "$BUILD/archives/LATEST/"
	ln -sfv "$BUILD/archives/$WEBRTC_REVISION/$1" "$BUILD/archives/LATEST/"

    cd "$BUILD/archives/$WEBRTC_REVISION/$1"

    create_directory_if_not_found libjingle_peerconnection/
    
    # Copy podspec with ios and mac
    cp -v "$PROJECT_DIR/libjingle_peerconnection.podspec" "libjingle_peerconnection.podspec"

    # inject pod url
    if [ -z $USER_POD_URL ]
    then
        echo "User has not specified a different pod url. Using default"
        sed -ic "s|{POD_URL}|"$DEFAULT_POD_URL"|g" libjingle_peerconnection.podspec
    else
        echo "User has specified their own pod url $USER_POD_URL"
        sed -ic "s|{POD_URL}|"$USER_POD_URL"|g" libjingle_peerconnection.podspec
    fi
    
    # inject revision number
    sed -ic "s/{WEBRTC_REVISION}/$WEBRTC_REVISION/g" libjingle_peerconnection.podspec
    # inject build type string
    sed -ic "s/{BUILD_TYPE_STRING}/$1/g" libjingle_peerconnection.podspec
    
    if [ $1 = "Debug" ] 
    then
        VERSION_BUILD=`get_version_build "$WEBRTC_REVISION" 0`
        cp -fv "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-Debug.a" "libjingle_peerconnection/libWebRTC.a"
        cp -fv "$BUILD/libWebRTC-$WEBRTC_REVISION-mac-x86_64-Debug.a" "libjingle_peerconnection/libWebRTC-osx.a"
        sed -ic "s/{BUILD_TYPE}/0/g" libjingle_peerconnection.podspec
        sed -ic "s/{VERSION_BUILD}/$VERSION_BUILD/g" libjingle_peerconnection.podspec
    fi
    if [ $1 = "Release" ] 
    then
        VERSION_BUILD=`get_version_build "$WEBRTC_REVISION" 2`
        cp -fv "$BUILD/libWebRTC-$WEBRTC_REVISION-arm-intel-Release.a" "libjingle_peerconnection/libWebRTC.a"
        cp -fv "$BUILD/libWebRTC-$WEBRTC_REVISION-mac-x86_64-Release.a" "libjingle_peerconnection/libWebRTC-osx.a"
        sed -ic "s/{BUILD_TYPE}/2/g" libjingle_peerconnection.podspec
        sed -ic "s/{VERSION_BUILD}/$VERSION_BUILD/g" libjingle_peerconnection.podspec
    fi

    # write the revision and build type into a file
    echo "revision $WEBRTC_REVISION $1 build" > "libjingle_peerconnection/libjingle_peerconnection_revision_build.txt"
    
    # add headers
    cp -fvR "$WEBRTC/src/talk/app/webrtc/objc/public/" "libjingle_peerconnection/Headers"

    # Compress artifact
    tar --use-compress-prog=pbzip2 -cvLf "libWebRTC.tar.bz2" *

    echo Go back to working directory
    cd "$WORKING_DIR"
}

# Grabs the current version build based on what is
function get_version_build() {
    # Set version build
    VERSION_BUILD=0

    # Create temp output file to parse
    pod search libjingle_peerconnection > /tmp/libjingle_search.log

    if [ -z $USER_POD_URL ]
    then
        VERSION_BUILD=`egrep -o 'Versions: .*\[master repo\]' /tmp/libjingle_search.log | egrep -o '\d+\.\d\.\d+' | awk -v REVISION_NUM="$1" -v BUILD_TYPE="$2" -F '.' 'BEGIN{ VERSION_COUNT = 0 }; { if ($1 == REVISION_NUM && $2 == BUILD_TYPE) VERSION_COUNT += 1 }; END{ print VERSION_COUNT };'`
    else
        VERSION_BUILD=`egrep -o '\[master repo\].*' /tmp/libjingle_search.log | egrep -o '\d+\.\d\.\d+' | awk -v REVISION_NUM="$1" -v BUILD_TYPE="$2" -F '.' 'BEGIN{ VERSION_COUNT = 0 }; { if ($1 == REVISION_NUM && $2 == BUILD_TYPE) VERSION_COUNT += 1 }; END{ print VERSION_COUNT };'`
    fi

    echo "$VERSION_BUILD"
}

# Create an iOS "framework" for distribution sans CocoaPods
function create_ios_framework() {
    if [ "$WEBRTC_DEBUG" = true ] ; then
        create_ios_framework_for_configuration "Debug"
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        create_ios_framework_for_configuration "Profile"
    fi

    if [ "$WEBRTC_RELEASE" = true ] ; then
        create_ios_framework_for_configuration "Release"
    fi
}

function create_ios_framework_for_configuration () {
    CONFIGURATION=$1

    local headers_path=`resolve_link "$WEBRTC/headers"`
    local binary_path=`resolve_link "$WEBRTC/libWebRTC-LATEST-Universal-$CONFIGURATION.a"`

    rm -rf "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework"
    mkdir -p "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework/Versions/A/Headers"
    cp -p $(find "$headers_path" -name "*.h") "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework/Versions/A/Headers"
    cp "$binary_path" "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework/Versions/A/WebRTC"

    WEBRTC_REVISION=`get_revision_number`
    echo $WEBRTC_REVISION >> "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework/Version.txt"

    pushd "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework/Versions"
    ln -sfh A Current
    popd
    pushd "$WEBRTC/Framework/$CONFIGURATION/WebRTC.framework"
    ln -sfh Versions/Current/Headers Headers
    ln -sfh Versions/Current/WebRTC WebRTC
    popd
}

# Get webrtc then build webrtc
function dance() {
    # These next if statement trickery is so that if you run from the command line and don't set anything to build, it will default to the debug profile.
    BUILD_DEBUG=true

    if [ "$WEBRTC_RELEASE" = true ] ; then
        BUILD_DEBUG=false
    fi

    if [ "$WEBRTC_PROFILE" = true ] ; then
        BUILD_DEBUG=false
    fi

    if [ "$BUILD_DEBUG" = true ] ; then
        WEBRTC_DEBUG=true
    fi

    GLOBAL_GN_ARGS=$GN_ARGS

    if [[ $WEBRTC_USE_OPENSSL = true ]]; then
        GLOBAL_GN_ARGS="$GLOBAL_GN_ARGS rtc_build_ssl=false rtc_ssl_root=\"$WEBRTC_OPENSSL_ROOT\""
    fi

    BRANCH=$@

    if [ -z $BRANCH ]; then
        echo 'Branch is not specified' >&2 
        exit -1
    fi

    PATCH_PATH="$PROJECT_DIR/patches/branch_$BRANCH.patch"

    get_webrtc $@
    build_webrtc
    echo "Finished Dancing!"
}

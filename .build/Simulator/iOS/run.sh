#!/bin/sh
set -e
cd "`dirname "$0"`"

case $1 in
debug)
    echo "Opening '`pwd -P`/pract.xcodeproj' ..."
    open "pract.xcodeproj"
	exit $?
	;;
esac

"/usr/local/share/uno/Packages/UnoCore/0.19.6/Targets/CPlusPlus/Prebuilt/iOS/bin/ios-deploy" --justlaunch --debug --bundle "build/Release-iphoneos/pract.app" "$@"

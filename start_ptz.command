#!/bin/bash
cd "$(dirname "$0")"

if [ ! -f ./uvc_ctrl ]; then
    echo "Compiling uvc_ctrl…"
    clang -o uvc_ctrl uvc_ctrl.m \
        -framework IOKit -framework CoreFoundation \
        -framework AVFoundation -framework CoreMedia \
        -fobjc-arc -Wno-deprecated-declarations
    if [ $? -ne 0 ]; then
        echo "❌ Compilation failed. Make sure Xcode Command Line Tools are installed:"
        echo "   xcode-select --install"
        read -p "Press Enter to close…"
        exit 1
    fi
fi

echo "Starting PTZ server…"
echo "Toggle PTZ on in the web page to connect."
echo "Press Ctrl+C to stop."
echo ""
./uvc_ctrl

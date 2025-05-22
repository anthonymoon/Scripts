#!/bin/bash

# Script to remove Gatekeeper quarantine flags from all applications in /Applications
# This will bypass the "app is from an unidentified developer" security warnings

echo "Starting to remove quarantine flags from applications in /Applications..."

# Find all .app bundles in /Applications, including subdirectories
find /Applications -type d -name "*.app" | while read app; do
    echo "Processing: $app"
    
    # Check if the app has the quarantine flag
    if xattr "$app" | grep -q "com.apple.quarantine"; then
        echo "  Removing quarantine flag from: $app"
        xattr -d com.apple.quarantine "$app"
        
        if [ $? -eq 0 ]; then
            echo "  ✅ Successfully removed quarantine flag"
        else
            echo "  ❌ Failed to remove quarantine flag (may require sudo)"
        fi
    else
        echo "  ✓ No quarantine flag found"
    fi
done

echo "Operation complete!"
echo "Note: Some applications may require admin privileges to modify. If needed, run this script with sudo."

#!/bin/bash

# Start a2gent backend for Whisper transcription
# This script should be run before using the Scribe app

BACKEND_DIR="$HOME/git/a2gent/aagent"

if [ ! -d "$BACKEND_DIR" ]; then
    echo "❌ Error: a2gent backend not found at $BACKEND_DIR"
    echo "Please clone the a2gent repository first"
    exit 1
fi

echo "🚀 Starting a2gent backend..."
cd "$BACKEND_DIR"

if [ ! -f "Makefile" ]; then
    echo "❌ Error: Makefile not found in $BACKEND_DIR"
    exit 1
fi

# Check if already running
if curl -s http://localhost:3000/health > /dev/null 2>&1; then
    echo "✅ Backend already running on http://localhost:3000"
    exit 0
fi

# Start the backend
make run

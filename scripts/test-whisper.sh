#!/bin/bash

# Test Whisper endpoint with a sample audio file

ENDPOINT="http://localhost:3000/speech/transcribe"

echo "🧪 Testing Whisper endpoint..."

# Check if backend is running
if ! curl -s http://localhost:3000/health > /dev/null 2>&1; then
    echo "❌ Backend not running on http://localhost:3000"
    echo "Please run: ./scripts/start-backend.sh"
    exit 1
fi

echo "✅ Backend is running"

# Create a test audio file (1 second of silence)
TEST_FILE="/tmp/test_audio.wav"
ffmpeg -f lavfi -i anullsrc=r=44100:cl=mono -t 1 -acodec pcm_s16le "$TEST_FILE" -y > /dev/null 2>&1

if [ ! -f "$TEST_FILE" ]; then
    echo "❌ Failed to create test audio file"
    echo "Please install ffmpeg: brew install ffmpeg"
    exit 1
fi

echo "📤 Sending test audio to $ENDPOINT"

# Send test request
RESPONSE=$(curl -s -X POST "$ENDPOINT" \
    -F "audio=@$TEST_FILE" \
    -F "language=en")

echo "📥 Response:"
echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

# Cleanup
rm -f "$TEST_FILE"

echo ""
echo "✅ Test complete"

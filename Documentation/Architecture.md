# How Duo works

We capture the Mac display with ScreenCaptureKit, encode H.264 with VideoToolbox and send it over TLS 1.3. The client renders it with AVSampleBufferDisplayLayer and sends input over the same connection.

## Video and audio

Video targets 60 fps. Picture quality limits pixels and the maximum bitrate; workspace size controls how much fits. The client acknowledges each frame once it is queued for display. The host keeps enough frames in flight to cover the round trip and drops captured frames beyond that, so a slow connection doesn't build a queue of old frames. Acknowledgement delay above the path's base delay means queueing: the host lowers the encoder bitrate toward the measured delivery rate, then probes upward while the content uses it. If acknowledgements stop for 4 seconds, the host resets and sends a keyframe. Peers without acknowledgements keep one encoded frame awaiting transmission.

When sound is enabled, ScreenCaptureKit captures Mac audio. The host converts it to 48 kHz stereo AAC at 128 kbps. The client plays it through AVAudioEngine and uses the video timestamps to discard audio that has fallen behind. A new capture stream resets the decoder.

If capture fails, the host can restart it on the same connection and display. Input pauses during recovery. Two attempts are allowed per 60 seconds; further failures stop sharing. Stopping the host or removing capture permission also stops sharing.

## Displays and input

Control Mac captures the main display at its existing resolution. If macOS reports no main display, the host attempts to create a virtual one. This fallback still needs testing on a headless Mac.

Use as Display creates a temporary monitor through the private `CGVirtualDisplay` API. Automatic sizing follows the available video area. Fixed shapes keep their chosen desktop size. Resizing changes the existing display; disconnecting removes it.

Trackpad and Touch modes send pointer positions, clicks, scrolls and key events. The host posts them through CGEvent with Accessibility permission. In Use as Display, keyboard input targets the app under the last remote click.

Native touch sends individual finger contacts to a CoreHID virtual touchscreen attached to the captured display. [Native touch on macOS](NativeTouch.md) explains the reports and display binding.

Each fold region measures its own space and keyboard coverage. Camera and fold regions come from the system. One native text field keeps keyboard focus and text composition while the controls move between layouts.

## Pairing and shared data

Each installation has a P-256 identity. The client checks the saved Mac fingerprint, and the host checks device approval before sending video or accepting input. [Security](Security.md) covers pairing and revocation.

Clipboard operations are explicit requests with matching response IDs. Only a requested read can replace the client's clipboard. Text is limited to 16 KB; the app doesn't poll the clipboard.

Files use a separate TLS connection with the same identity as the active workspace. After the receiver accepts, the sender transfers acknowledged 64 KB chunks. File I/O runs outside the UI actor. The receiver checks the byte count and SHA-256 digest before publishing the file. Cancellation removes partial data, and existing files aren't overwritten.

The peers exchange supported features during authorization, so older versions don't receive unsupported messages. An address override retains the saved Mac identity.

The host needs a logged-in session. An active stream prevents idle system sleep, but doesn't override lid closure or explicit sleep.

## Microphone

The iPhone captures audio through AVAudioEngine and converts it to 48 kHz mono, 16-bit PCM. Bounded packets use the workspace's existing TLS connection. Only an approved device with control access can enable the stream.

The host feeds PCM to the Duo Microphone Core Audio plug-in through a custom device property. The plug-in publishes an input-only device, so Mac apps can select it as a microphone. Readers share a clock-indexed sample buffer. Missing audio becomes silence; stopping or disconnecting clears the buffer. The iPhone shares one audio session between microphone capture and Mac-audio playback.

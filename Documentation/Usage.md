# Using Duo Workspace

## Workspaces

Control Mac shows the desktop and windows already open on your Mac. Use as Display creates a temporary desktop for extra windows. Disconnecting removes it.

The Mac must be logged in. Allow screen recording to see it, and Accessibility access to control it.

## Pointer and keyboard

Choose the pointer mode in Session:

| Mode | What your fingers do |
| --- | --- |
| Trackpad | Slide to move the pointer, tap to click, or hold to drag. |
| Touch | Tap the Mac image to click there. Slide to point and hold to drag. |
| Native touch | Send up to five finger contacts to macOS. See the [native-touch guide](NativeTouch.md) for setup and behavior. |

In Trackpad and Touch, use two fingers to scroll. Pinch to zoom the Mac picture on your iPhone, and move the pinch to pan; nothing is sent to the Mac. Double-tap with two fingers to return to fit. Drag holds the mouse button until you choose Drop; Scroll lets you scroll with one finger. The More menu has Right-click and Double-click actions at the pointer's position.

Touch ignores taps in black margins. Double-tap right-clicks by default; change Settings → Input → Double-tap to Double-click if you prefer. A two-finger tap also right-clicks. The lower tabletop trackpad stays a trackpad in all modes.

Choose Keyboard to type. Modifiers apply to the next key, click or scroll, and stay held while dragging. Copy and Paste use the Mac's clipboard.

Open Mac keys → F1–F12, or F1–F12 in the keyboard row, for function keys. Tap Fn before another key to hold the Mac's Function modifier. Fn-Delete sends forward delete; Fn with an arrow sends Home, End, Page Up or Page Down. Fn-Return sends keypad Enter. You can combine Fn with other modifiers. Update Duo Workspace Host if Fn is disabled.

In tabletop, the desktop sits above the fold and the controls sit below it. The key row moves above the software keyboard and yields space to text-composition candidates. Hiding the keyboard restores the trackpad when space allows. A vertical fold keeps one canvas.

Open Session in the lower toolbar or keyboard row for settings, sharing and connection controls. Hide controls removes the toolbar and keyboard. Swipe inward at either side mark to restore them, or use the Show controls accessibility action.

Connected workspaces use game-style Home gestures: the Home indicator dims, and the first upward swipe at the bottom stays in Duo. Swipe up again to go Home.

The Mac desktop is video, so its controls aren't exposed to iPhone screen readers. VoiceOver actions can move the pointer, click, drag and scroll. Accessibility text sizes, VoiceOver, Switch Control and composing or non-English keyboards keep the key row attached to the native keyboard.

## Connection address

Pairing uses the address in the invitation. Choose Use a different address for another hostname or IP; the port is under Advanced. It still verifies the same Mac.

For Tailscale, run it on both devices and use the Mac's Tailscale IP or MagicDNS name. Your tailnet must allow port 47991. Duo uses that connection directly and doesn't provide a relay.

## Sharing without a click on the Mac

In Duo Workspace Host, open Settings and turn on **Start sharing when opened**. Paired devices can then connect as soon as the host opens. With **Open at login** as well, the Mac is reachable after a restart once you log in. A locked Mac still streams its lock screen. Pairing a new device still needs approval on the Mac.

## Desktop shape and size

Use as Display can resize the desktop. Automatic follows the available video area. A fixed shape keeps its chosen size through rotation, folding and keyboard changes. Landscape stays landscape, and the desktop stays centered.

| Orientation | Shapes |
| --- | --- |
| Landscape | 16:10, 16:9, 4:3, 21:9 |
| Portrait | 3:4, 10:16, 9:16 |
| Square | 1:1 |

Control Mac keeps the physical display's dimensions.

Workspace size controls how much fits:

| Setting | What changes |
| --- | --- |
| Comfortable | Default, with larger Mac text. |
| More space | More desktop space and smaller text. |
| Match display | Uses the device's native pixels for a HiDPI workspace. Fixed shapes keep their saved match. |
| Update display match | Updates a fixed shape to match the current display. |

Picture quality applies when you reconnect. Balanced is the default. Efficient lowers pixel and bitrate limits; Sharp raises them. Maximum detail allows six million pixels, a 3840-pixel axis limit and 20 Mbps. All modes target 60 fps; the bitrate adapts to the connection up to that limit. A higher setting can't add detail missing from the source display.

Session details show the workspace, backing and stream dimensions. [View display settings](Images/display-settings.png).

## Clipboard

In Session, Paste under Clipboard sends this device's text to the Mac clipboard. Get Mac clipboard copies text in the other direction. Both need control access and accept up to 16 KB of text. Paste on Mac inserts that text into the focused Mac app.

## Sound

Turn on Play Mac audio in Session and adjust Volume. Sound starts off.

Mute Mac while listening here silences the Mac's output while the stream keeps playing. When audio stops or you disconnect, Duo restores the mute state it changed. A Mac that was already muted stays muted. If you manually unmute the Mac, Duo stops managing it. Outputs without a software mute control need the Mac's own controls.

## iPhone microphone

In Session, turn on **Send iPhone microphone** and allow Microphone access. Choose **Duo Microphone** as the input in your Mac app.

Install the input device once from **Duo Workspace Host → Install microphone device**. macOS asks for administrator approval and briefly restarts audio. Sharing starts off and stops when you disconnect or the phone app goes into the background.

## Files

In Session → Files, Send file to Mac opens Files on this device. The Mac saves received files in `Downloads/Duo Workspace`, adding a number if the filename exists.

Get file from Mac opens a picker on the streamed desktop. Select a file and choose Send. Back in Duo, tap Receive file, then Save or share file to keep it.

Transfers need control access. Send one regular file at a time, up to 2 GB. Cancel transfer removes unfinished data. A disconnect ends the transfer; start it again to retry. Completed downloads remain available in Files during the app session.

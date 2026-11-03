# TabScreen

Turns your Galaxy Tab S10 FE into a real extended display for this Mac.
macOS sees it as a normal second monitor ("Galaxy Tab" in System Settings → Displays): drag windows onto it,
arrange it, change its resolution. The tablet shows it in Chrome, so there's no app to install on the tablet.

## 1. Build and start (on the Mac)
Double-click **Build and Run.command** in this folder.
- If it says the developer tools are missing, run `xcode-select --install` in Terminal, then try again.
- A tablet icon appears in the menu bar. That's TabScreen.

## 2. Allow Screen Recording (first time, and after every rebuild)
TabScreen needs it to send the extra display to the tablet. Turn on **TabScreen** in
System Settings → Privacy & Security → Screen & System Audio Recording,
then choose **Restart TabScreen** from the menu bar icon.

## 3. Connect the tablet with USB (recommended: fastest)
One-time setup on the tablet:
1. Settings → About tablet → Software information → tap **Build number** 7 times.
2. Settings → Developer options → turn on **USB debugging**.
3. If Samsung **Auto Blocker** is on (Settings → Security and privacy), turn it off. It blocks USB commands.

On the Mac: menu bar icon → **Set up USB connection…** (downloads Google's adb tool, about 15 MB).

Plug the tablet into the Mac with a USB-C cable that carries data, and tap **Allow** when the tablet asks about
USB debugging. Chrome opens on the tablet with your extra screen. Tap once for full screen.

## Wi-Fi instead of USB (optional)
Menu bar icon → **Allow Wi-Fi connection** shows an address like `http://192.168.1.23:7171/?k=abc123`.
Chrome only allows the video decoder on secure addresses, so do this once on the tablet:
open `chrome://flags`, find **Insecure origins treated as secure**, add `http://192.168.1.23:7171`
(your address, without the `?k=…` part), enable it and relaunch Chrome. Then open the full address.
The `k=` key stops other people on the same Wi-Fi from viewing your screen.

## Arrange and size
- Menu bar icon → **Arrange displays…** and drag the Galaxy Tab to where it sits on your desk.
- Menu bar icon → **Screen size** to trade bigger text for more space.

## If something doesn't work
TabScreen writes `TabScreen.log` in this folder, and the build writes `build.log`.

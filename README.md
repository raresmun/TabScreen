# TabScreen

Turns your Galaxy Tab S10 FE into a real extended display for this Mac.
macOS sees it as a normal second monitor ("Galaxy Tab" in System Settings → Displays): drag windows onto it,
arrange it, change its resolution. On the tablet, the TabScreen app shows it full screen.

## 1. Build and start (on the Mac)
Double-click **Build and Run.command** in this folder.
- If it says the developer tools are missing, run `xcode-select --install` in Terminal, then try again.
- A tablet icon appears in the menu bar. That's TabScreen.

## 2. Allow Screen Recording (first time only)
TabScreen needs it to send the extra display to the tablet. Turn on **TabScreen** in
System Settings → Privacy & Security → Screen & System Audio Recording,
then choose **Restart TabScreen** from the menu bar icon.
Builds are signed with TabScreen's own local certificate, so the permission stays on after rebuilds.

## 3. Connect the tablet with USB (fastest)
One-time setup on the tablet:
1. Settings → About tablet → Software information → tap **Build number** 7 times.
2. Settings → Developer options → turn on **USB debugging**.
3. If Samsung **Auto Blocker** is on (Settings → Security and privacy), turn it off. It blocks USB commands.

On the Mac: menu bar icon → **Set up USB connection…** (downloads Google's adb tool, about 15 MB).

Plug the tablet into the Mac with a USB-C cable that carries data, and tap **Allow** when the tablet asks about
USB debugging. TabScreen installs the **TabScreen app** on the tablet (the first time, and after updates) and opens
it: your extra screen appears full screen. After that, just plug in the tablet.

## Wi-Fi instead of USB (optional)
Menu bar icon → **Allow Wi-Fi connection**. If the tablet has been plugged in over USB once, the TabScreen app already
knows the Mac's address and key: open the app and it connects. Otherwise tap **Wi-Fi settings** in the app and type
the address and key shown in the menu. The key stops other people on the same Wi-Fi from viewing your screen.
Wi-Fi is switched off again every time TabScreen starts.

The browser viewer still works as a fallback: open the **Browser** address from the menu in Chrome.

## Arrange and size
- Menu bar icon → **Arrange displays…** and drag the Galaxy Tab to where it sits on your desk.
- Menu bar icon → **Screen size** to trade bigger text for more space.

## The tablet app
`Android/` holds its source. `Android/TabScreen.apk` is built on Linux with `Android/build-apk.sh`
(no Android Studio needed). Keep `Android/signing/`: updates must be signed with the same key to install over the app.

## If something doesn't work
TabScreen writes `TabScreen.log` in this folder (the tablet app adds notes there too), and the build writes `build.log`.

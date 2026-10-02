# Notch browser extension

Hands the files you download in your browser over to Notch. Notch saves them to your
download folder and shows the progress in the island. When it's done you can drag the file
out, AirDrop it or share it from the Downloads tab.

You pick which file types Notch takes (documents and PDFs, images, archives, apps and disk
images, video and audio, everything else). The browser keeps the rest. If Notch isn't running
or can't fetch a file, the browser downloads it as usual, so nothing gets lost.

## Install

1. In Notch, open **Settings › Activities › Browser downloads**, turn on **Take over downloads
   from your browser**, and click **Show Extension Folder**.
2. Load that folder in your browser:
   - **Chrome, Edge, Brave, Arc, Vivaldi:** open `chrome://extensions`, turn on **Developer
     mode**, click **Load unpacked**, and choose the folder.
   - **Firefox:** open `about:debugging#/runtime/this-firefox`, click **Load Temporary
     Add-on…**, and choose `manifest.json` in the folder. Firefox removes temporary add-ons when
     it quits.
3. Download something. It shows up in the notch instead of the browser's download list.

Safari isn't supported yet, because it needs a signed Safari App Extension.

## Using it

- Click the toolbar button to turn the hand-off on or off. The badge shows **OFF** when it's
  off, and **!** when Notch can't be reached.
- Downloads from private/incognito windows always stay in the browser.
- Notch receives the file's link, name, referrer and your cookies for that site, so downloads
  that need you to be signed in still work. Everything goes to `127.0.0.1` (your own Mac). The
  cookies are kept in memory only and never saved.

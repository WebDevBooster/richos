# Native call-capture host

On Windows, install Node, retain the RichOS source tree at a stable location and load the unpacked extension. Copy its ID from `chrome://extensions` then run from PowerShell using your Node executable:

```powershell
& 'C:\path\to\node.exe' 'C:\path\to\richos\richos\tools\richos-service\host\install-host-windows.mjs' 'YOUR_32_CHARACTER_EXTENSION_ID' 'C:\RichOS\Calls'
```

The optional final argument chooses the drop zone. If omitted, the service uses its configured corpus location. Installation writes a resolved `.cmd` launcher and JSON manifest under `%LOCALAPPDATA%\RichOS\native-host`, registers `com.richos.host` under the current user's Chrome NativeMessagingHosts registry key and permits only that extension ID. No elevation or network listener is needed. Node and the source tree must remain at those paths. Run with `--uninstall` to remove the registry registration; recording files remain.

Chrome starts the host on the extension's next connection. In the RichOS popup verify that the saving location is the local service. Captured audio reaches files continuously through native messaging, regardless of Chrome's download ask-where setting. If the host is missing or stops acknowledging writes, the extension retains its durable browser copy for an explicit single-ZIP export after the call. Do not delete the profile or extension storage before exporting a pending recording.

Node supplies capture transport, not transcription tools. Local transcription additionally requires the service's supported ffmpeg, whisper runtime and model configuration. A successful recording is distinct from successful downstream transcription. Native host errors or suspect session health must not be presented as a clean recording.

For macOS and Linux use `install-host.sh <extension-id>`. The older Windows launcher template is not an installation: use the Node installer above.

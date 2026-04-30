# Jira Helper Server

This project now includes a tiny local PowerShell server so you can fetch Jira XML without exporting and pasting it by hand.

## First-time setup

1. Copy `jira-proxy.config.example.json` to `jira-proxy.config.json`
2. Leave the Jira URL as `https://jira.wsgc.com` unless you need a different Jira host
3. Open PowerShell in this folder

## Start the server

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\jira-proxy.ps1
```

It will ask you for your Jira personal access token if `JIRA_PAT` is not already set.

Or just double-click:

- `Start Jira Helper.bat`

## Test it

Open these in your browser:

```text
http://localhost:8765/health
http://localhost:8765/ticket-xml?key=PKECOM-41673
```

If the second URL works, you should see Jira XML in the browser.

## Optional: avoid pasting the token every time

The easiest way is to double-click:

- `Save Jira Token.bat`

That saves your Jira personal access token as `JIRA_PAT` for your Windows user account.

If you ever want to remove it, double-click:

- `Clear Jira Token.bat`

You can also still set it only for the current PowerShell session with:

```powershell
$env:JIRA_PAT = "your-token-here"
```

Then start the server again with:

```powershell
powershell -ExecutionPolicy Bypass -File .\jira-proxy.ps1
```

## Stop the server

The easiest way is to double-click:

- `Stop Jira Helper.bat`

You can also still stop it manually.

If you started it from PowerShell or from `Start Jira Helper.bat`:

1. Click the helper window
2. Press `Ctrl+C`
3. Type `Y` and press Enter if PowerShell asks

## Next step

Once this works, the HTML app can be updated to call:

```text
http://localhost:8765/ticket-xml?key=PKECOM-41673
```

and import the returned XML automatically.

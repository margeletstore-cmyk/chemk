# CHEMK STRIKE online setup

The game now uses Supabase Realtime for room presence and live player updates. School computers only need a browser and internet access; they do not run a local server. `START CHEMK STRIKE.bat` now opens the game directly from the folder.

## Supabase configuration

`code/supabase-config.js` contains the project's URL and **publishable** key. The URL must be the project root (for example, `https://project-id.supabase.co`), not the `/rest/v1/` API path. The browser key is public by design. Never put a `service_role` or secret key in this file.

The online mode uses public Realtime channels and does not require a database table or SQL migration.

## Publish the game

1. Keep the folder structure unchanged: `code`, `img`, `maps`, `models`, and `sounds` must be beside `index.html`.
2. Upload the complete game folder to a static HTTPS host, for example Cloudflare Pages Direct Upload.
3. Open the published site URL. Players choose **Играть → Онлайн**, then create a room or enter its six-character code.

The game can also connect to Supabase when opened from local files, but every computer must have the complete game folder. A published HTTPS link is easier to share and update. The old launcher referenced a missing PowerShell server script; it no longer starts a local server.

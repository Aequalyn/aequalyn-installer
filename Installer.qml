import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

Scope {
    id: root

    // ---- colours: the Aequalyn palette, dark; while the desktop wears a light theme
    // (Aequalyn Day, or any theme whose theme.json says "variant": "light"), Aequalyn
    // Day's. Read from the desktop user's theme.conf (see themeProbe) ----------------
    property bool light: false
    readonly property color bgBase: light ? "#f0f6f7" : "#121515"
    readonly property color bgCard: light ? "#e6eff2" : "#1a1f1f"
    readonly property color bgSurface: light ? "#e6eff2" : "#1a1f1f"
    readonly property color bgHover: light ? "#dce9ec" : "#202727"
    readonly property color bgSelected: light ? "#c8dfe4" : "#26383a"
    readonly property color border: light ? "#c6d8dd" : "#2f3a3a"
    readonly property color textPrimary: light ? "#1d2027" : "#dde5e3"
    readonly property color textSecondary: light ? "#4d5156" : "#b2bfbc"
    readonly property color textMuted: light ? "#81868a" : "#6c7a78"
    readonly property color accent: light ? "#2a766b" : "#4fc1b0"
    readonly property color ok: light ? "#3c7d4c" : "#8bc79a"
    readonly property color warn: light ? "#c8323e" : "#e06c6c"

    // The desktop's theme: the installer runs as root (sudo -E), so the theme is the
    // one of the user who started it. Asked again every few seconds, so switching
    // themes while the installer is open turns it light or dark too.
    readonly property string desktopHome: Quickshell.env("SUDO_USER") ? "/home/" + Quickshell.env("SUDO_USER") : Quickshell.env("HOME")
    Process {
        id: themeProbe
        command: ["sh", "-c",
            'c=$(cat "$1/.config/quickshell/theme.conf" 2>/dev/null); id=${c#theme:}; '
            + '[ "$id" = "$c" ] && { echo dark; exit 0; }; '
            + 'for d in "$1/.config/aequalyn/themes" "$1/.local/share/aequalyn/themes" /usr/share/aequalyn/themes; do '
            + 'f="$d/$id/theme.json"; [ -f "$f" ] || continue; '
            + 'grep -q \'"variant"[[:space:]]*:[[:space:]]*"light"\' "$f" && echo light || echo dark; exit 0; done; echo dark',
            "sh", root.desktopHome]
        running: true
        stdout: StdioCollector { onStreamFinished: root.light = text.trim() === "light" }
    }
    Timer { interval: 3000; repeat: true; running: true; onTriggered: if (!themeProbe.running) themeProbe.running = true }

    // ---- what the installer opens on: install, repair or read the manual --------
    // "" is the start page; "install" is the wizard below; the other two have a page each
    property string page: ""
    readonly property string manualPath: root.installerDir + "/../README.md"
    // the bar widgets' names as the installer shows them
    function widgetName(id) {
        return ({ settingsbutton: "settings-button", screenrecorder: "screen-recorder", appsmenu: "apps-menu" })[id] || id;
    }

    property string installerDir: Quickshell.env("AEQUALYN_INSTALLER_DIR") || "/opt/aequalyn/installer"
    property string detectScript: root.installerDir + "/aequalyn-detect"
    property string applyScript: root.installerDir + "/lib/apply.sh"
    property bool isRoot: Quickshell.env("USER") === "root"
    property string configPath: root.isRoot ? "/root/install.toml" : (Quickshell.env("HOME") + "/install.toml")
    property string logFile: root.isRoot ? "/root/aequalyn-install_qml.log" : (Quickshell.env("HOME") + "/aequalyn-install_qml.log")

    property int step: 0
    readonly property var stepNames: ["Welcome", "Identity", "Disk", "Packages", "Aequalyn", "Review", "Finish"]
    readonly property var stepDescriptions: [
        "Hardware proposal and overview",
        "Hostname, user, timezone, password",
        "Target disk, mode, encryption",
        "Profiles, browser, sources",
        "Theme and GTK apps",
        "Review install.toml and apply",
        "Apply progress and log"
    ]
    property var detect: ({})
    property var disks: []
    property bool detecting: false

    property string hostname: "aequalyn"
    property string username: "user"
    property string timezone: "UTC"
    property string keymap: "us"
    property string password: ""
    property string passwordConfirm: ""

    property string selectedDisk: ""
    property string mode: "fullwipe"
    property bool encrypt: false
    property bool chainloadWindows: false
    property int efiSizeMb: 2048
    onModeChanged: { if (root.mode !== "dualboot") root.chainloadWindows = false; }

    property bool profCasual: false
    property bool profDev: false
    property bool profCreative: false
    property bool profGaming: false
    property bool profStudent: false
    property bool profWork: false
    property bool profAi: false

    // On top of the base system (the minimal list), which every install has. Any of them
    // together: what two share is installed once.
    readonly property var profileDefs: [
        { key: "profCasual", id: "casual", title: "Casual", sub: "Discord, Telegram, VLC, photos, torrents, calculator, clocks, weather" },
        { key: "profDev", id: "dev", title: "Developer", sub: "Neovim, Helix, Git, Node, Rust, Go, Python, Docker" },
        { key: "profCreative", id: "creative", title: "Creator", sub: "GIMP, Inkscape, Krita, Blender, Kdenlive, OBS, Audacity" },
        { key: "profGaming", id: "gaming", title: "Gamer", sub: "Steam, Lutris, Wine, GameMode, MangoHud, Discord" },
        { key: "profStudent", id: "student", title: "Student", sub: "LibreOffice, Calibre, Xournal++, OBS" },
        { key: "profWork", id: "work", title: "Work", sub: "LibreOffice, Thunderbird, Bitwarden, Signal, Tailscale, Syncthing" },
        { key: "profAi", id: "ai", title: "AI", sub: "Ollama, llama.cpp and PyTorch" }
    ]

    property string browser: "chromium"
    property bool flatpak: false
    property bool seedWebapps: true
    property bool installLockscreens: false
    property string source: "auto"
    property string editor: "nano"

    property string themeMode: "wallpaper"
    property bool themeApps: true
    // Top bar layout (widget ids per region, left -> right). These are the
    // reference positions shipped on the ISO; leaving them editable in
    // install.toml lets a reinstall restore a customised bar exactly.
    // every widget, as config/aequalyn/settings.json has them
    property var barLeft: ["appsmenu", "workspaces", "layouts", "network", "atelier"]
    property var barCenter: ["clock", "calendar", "media", "title", "battery", "volume"]
    property var barRight: ["brightness", "cpu", "bluetooth", "temperature", "caffeine", "tray", "screenrecorder", "screenshot", "power", "clipscape", "settingsbutton", "plume", "altscape"]

    property bool dryRun: false
    property bool writing: false
    property bool applying: false
    property bool locked: false
    property var timezones: []
    property var filteredTimezones: []
    // A finished or failed install legitimately parks the wizard on the
    // Finish page even though the step bar is unlocked again for a retry;
    // the clamp must never yank the user off it.
    onStepChanged: {
        if (root.step === 6 && (root.installFinished || root.installFailed)) return;
        if (root.step > root.maxAllowedStep) root.step = root.maxAllowedStep;
    }
    onMaxAllowedStepChanged: {
        if (root.step === 6 && (root.installFinished || root.installFailed)) return;
        if (root.step > root.maxAllowedStep) root.step = root.maxAllowedStep;
    }
    property string geomPath: Quickshell.env("HOME") + "/.config/aequalyn/installer-geometry.conf"
    property bool imported: false
    readonly property bool step0Valid: true
    readonly property bool step1Valid: root.hostname.trim() !== "" && root.username.trim() !== "" && root.timezone.trim() !== "" && root.password !== "" && root.password === root.passwordConfirm
    readonly property bool step2Valid: root.selectedDisk !== ""
    readonly property bool step4Valid: true
    readonly property int maxAllowedStep: root.locked ? 6 : (root.imported ? 5 :
        (!root.step0Valid ? 0 :
        (!root.step1Valid ? 1 :
        (!root.step2Valid ? 2 :
        (!root.step4Valid ? 4 : 5)))))

    // One line in the footer saying what is still missing on the current page,
    // so a disabled Next never reads as a dead button.
    readonly property string stepHint: {
        if (root.locked || root.step < 1 || root.step > 4) return "";
        if (root.step === 1 && !root.step1Valid)
            return "Hostname, username, timezone and a matching password are required to continue.";
        if (root.step === 2 && !root.step2Valid)
            return "Select a target disk to continue.";
        return "";
    }
    property string statusText: ""
    property bool installFinished: false
    property bool rebooting: false

    // ---- install flow state -------------------------------------------------
    // Once Install is pressed the wizard is committed: the title bar's Close
    // stays blocked while the apply runs (quitting would kill it halfway) and
    // is re-activated by the outcome; the Finish page switches between
    // running / succeeded / failed.
    property bool installStarted: false       // Install was pressed at least once
    property bool installFailed: false         // apply exited non-zero
    property bool finishAcknowledged: false    // Finish clicked -> Reboot Now / Debug / Retry
    property bool showSplash: false            // "Enjoy Your Distro!" right before the reboot
    property bool online: false                // connectivity probe result
    property bool netChecking: true            // probe in flight
    // The help invite shown on failure, next to its QR code (assets/discord-qr.png).
    readonly property string discordInvite: "https://discord.gg/VwfceB5JbZ"

    // Log is kept as a ListModel instead of one growing string: appending to a
    // huge TextArea forces a full re-layout per line, which is what made the UI
    // freeze while mkinitcpio -P produced a burst of output. A ListView also
    // virtualises rendering, so the log stays cheap no matter how long it gets.
    property var logQueue: []
    readonly property int logMaxLines: 20000
    property bool logFollow: true
    ListModel { id: logModel }
    Timer {
        id: logFlushTimer
        interval: 100
        repeat: false
        onTriggered: root.flushLog()
    }

    function selectedProfiles() {
        return ["minimal"].concat(root.profileDefs.filter(p => root[p.key]).map(p => p.id));
    }

    function applyImport(d) {
        const sys = d.system || {};
        if (sys.hostname) root.hostname = sys.hostname;
        if (sys.username) root.username = sys.username;
        if (sys.timezone) root.timezone = sys.timezone;
        if (sys.keymap) root.keymap = sys.keymap;
        const disk = d.disk || {};
        if (disk.device) root.selectedDisk = disk.device;
        if (disk.mode) root.mode = disk.mode;
        root.encrypt = disk.encrypt === true;
        const boot = d.boot || {};
        root.chainloadWindows = boot.chainload_windows === true;
        // A full wipe installs Aequalyn as the only OS on this disk; another
        // disk's Windows ESP must never be injected into its menu.
        if (root.mode !== "dualboot") root.chainloadWindows = false;
        if (typeof disk.efi_size_mb === "number" && disk.efi_size_mb >= 256)
            root.efiSizeMb = disk.efi_size_mb;
        const pkgs = d.packages || {};
        if (pkgs.source) root.source = pkgs.source;
        for (const p of root.profileDefs) root[p.key] = false;
        if (Array.isArray(pkgs.profiles)) {
            for (const pr of pkgs.profiles) {
                const def = root.profileDefs.find(p => p.id === pr);
                if (def) root[def.key] = true;
            }
        }
        if (pkgs && pkgs.browser) root.browser = pkgs.browser;
        if (pkgs) root.flatpak = pkgs.flatpak === true;
        if (pkgs && pkgs.seedWebapps !== undefined) root.seedWebapps = (pkgs.seedWebapps === true);
        if (pkgs && pkgs.editor) root.editor = pkgs.editor;
        const ae = d.aequalyn || {};
        if (ae.theme_mode) root.themeMode = ae.theme_mode;
        root.themeApps = ae.theme_apps !== false;
        root.imported = true;
        root.step = 5;
    }

    function windowsOnTarget() {
        if (root.mode !== "dualboot" || !root.chainloadWindows) return false;
        const w = root.detect && root.detect.win_efi ? String(root.detect.win_efi) : "";
        return w !== "" && root.selectedDisk !== "" && w.indexOf(root.selectedDisk) === 0;
    }

    function generateToml() {
        const profiles = root.selectedProfiles();
        const profileStr = "[" + profiles.map(p => '"' + p + '"').join(", ") + "]";
        const arrStr = a => "[" + (a || []).map(x => '"' + x + '"').join(", ") + "]";
        const enc = root.encrypt ? "true" : "false";
        const flat = root.flatpak ? "true" : "false";
        const apps = root.themeApps ? "true" : "false";
        const chain = root.windowsOnTarget() ? "true" : "false";
        return "# Aequalyn install.toml -- reviewed by the user, applied by aequalyn-install\n" +
            "version = 1\n\n" +
            "[system]\n" +
            'hostname = "' + root.hostname + '"\n' +
            'username = "' + root.username + '"\n' +
            'locale = "en_US.UTF-8"\n' +
            'keymap = "' + root.keymap + '"\n' +
            'timezone = "' + root.timezone + '"\n' +
            "password_set = true\n\n" +
            "[disk]\n" +
            'device = "' + root.selectedDisk + '"\n' +
            'mode = "' + root.mode + '"\n' +
            'filesystem = "btrfs"\n' +
            "encrypt = " + enc + "\n" +
            "efi_size_mb = " + root.efiSizeMb + "\n" +
            'free_start = ""\n' +
            'free_end = ""\n\n' +
            "[boot]\n" +
            'bootloader = "limine"\n' +
            "chainload_windows = " + chain + "\n" +
            'kernels = ["linux"]\n\n' +
            "[packages]\n" +
            'source = "' + root.source + '"\n' +
            "profiles = " + profileStr + "\n" +
            'browser = "' + root.browser + '"\n' +
            "flatpak = " + flat + "\n" +
            "seed_webapps = " + (root.seedWebapps ? "true" : "false") + "\n" +
            "extra = []\n" +
            "aur = false\n" +
            'editor = "' + root.editor + '"\n\n' +
            "[agent]\n" +
            "level = 1\n" +
            "cloud_proposal = false\n" +
            "snapshot_before = true\n\n" +
            "[aequalyn]\n" +
            'theme_mode = "' + root.themeMode + '"\n' +
            "theme_apps = " + apps + "\n" +
            "bar_height = 32\n" +
            "bar_opacity = 100\n" +
            "bar_left = " + arrStr(root.barLeft) + "\n" +
            "bar_center = " + arrStr(root.barCenter) + "\n" +
            "bar_right = " + arrStr(root.barRight) + "\n" +
            'profile = "default"\n';
    }

    // ---- log buffering ------------------------------------------------------
    // Lines are queued and flushed in batches (100 ms) instead of touching the
    // view once per line, so a burst of mkinitcpio output cannot block the GUI.
    function appendLog(line) {
        if (line === undefined || line === null) return;
        // apply.sh colours its labels for a terminal: drop the escape codes, and say
        // OK with a tick
        const s = String(line).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r/g, "")
            .replace(/^\s*OK\s+/, "\u2705 ");
        if (s.trim().length === 0) return;
        root.logQueue.push({ line: s });
        if (!logFlushTimer.running) logFlushTimer.start();
    }

    function flushLog() {
        if (root.logQueue.length === 0) return;
        const batch = root.logQueue;
        root.logQueue = [];
        const overflow = logModel.count + batch.length - root.logMaxLines;
        if (overflow > 0 && logModel.count > 0)
            logModel.remove(0, Math.min(overflow, logModel.count));
        logModel.append(batch);
    }

    function clearLog() {
        root.logQueue = [];
        logModel.clear();
        root.logFollow = true;
    }

    function startApply() {
        if (root.locked) return;
        if (root.password === "" || root.password !== root.passwordConfirm) {
            root.statusText = "Passwords empty or do not match.";
            return;
        }
        if (root.selectedDisk === "") {
            root.statusText = "No disk selected.";
            return;
        }
        root.locked = true;
        root.clearLog();
        root.installStarted = true;
        root.installFinished = false;
        root.installFailed = false;
        root.finishAcknowledged = false;
        root.statusText = "Writing configuration...";
        root.writing = true;
        root.step = 6;
        // writeProc closes its own stdin after writing (that is how tee gets
        // EOF and exits), but that imperative "stdinEnabled = false" destroys
        // the declared binding: re-arm it here or a Retry would start tee
        // with no stdin at all and hang the wizard on "Writing..." forever.
        writeProc.stdinEnabled = true;
        writeProc.running = true;
    }

    // ---- processes ----
    Process {
        id: detectProc
        running: false
        command: ["bash", root.detectScript, "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.detect = JSON.parse(text || "{}");
                    // Detection may finish after the user imported a config;
                    // never overwrite their reviewed choices in that case.
                    if (!root.imported) {
                        root.mode = root.detect.mode || "fullwipe";
                        root.encrypt = root.detect.encrypt === true;
                        root.selectedDisk = root.detect.first_disk || "";
                        root.chainloadWindows = root.mode === "dualboot" &&
                            root.detect.win_efi !== undefined && root.detect.win_efi !== "";
                        const profs = root.detect.profiles || ["minimal"];
                        for (const p of root.profileDefs) root[p.key] = profs.indexOf(p.id) >= 0;
                        if (root.detect.browser) root.browser = root.detect.browser;
                        root.flatpak = root.detect.flatpak === true;
                    }
                } catch (e) {
                    root.statusText = "Detection failed: " + e;
                }
            }
        }
        onExited: (code) => {
            root.detecting = false;
            if (code !== 0) root.statusText = "Detection exited " + code;
            else root.statusText = "";
        }
    }

    Process {
        id: lsblkProc
        running: false
        // only disks: not the DVD drive (rom), nor the RAM ones (zram swap, loop images)
        command: ["lsblk", "-dpno", "NAME,TYPE,SIZE,MODEL"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = (text || "").trim().split("\n");
                const out = [];
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i].trim();
                    if (!line) continue;
                    const parts = line.split(/\s+/);
                    const name = parts[0];
                    if (name === root.detect.boot_disk) continue;
                    if (parts[1] !== "disk" || /^\/dev\/(zram|loop)/.test(name)) continue;
                    out.push({ name: name, size: parts[2] || "", model: parts.slice(3).join(" "), label: name + "  " + (parts[2] || "") + "  " + parts.slice(3).join(" ") });
                }
                root.disks = out;
                if (!root.selectedDisk && out.length > 0) root.selectedDisk = out[0].name;
            }
        }
    }

    Process {
        id: tzListProc
        running: false
        command: ["timedatectl", "list-timezones"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = (text || "").trim().split("\n").filter(x => x.trim() !== "");
                root.timezones = list;
                root.filteredTimezones = list;
            }
        }
    }

    Process {
        id: tzProc
        running: false
        command: ["timedatectl", "show", "-p", "Timezone", "--value"]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = (text || "").trim();
                if (v) { root.timezone = v; }
            }
        }
    }

    // Connectivity probe, the same check lib/apply.sh uses before picking the
    // package source. Without internet the proposal defaults to the bundled
    // offline repository, and a failed install shows the apology page instead
    // of the AI debug session (which needs the network anyway).
    Process {
        id: netProc
        running: false
        command: ["ping", "-c", "1", "-W", "2", "archlinux.org"]
        onExited: (code) => {
            root.netChecking = false;
            root.online = code === 0;
            // Only shape the *proposal*: never fight an imported config, a
            // manual choice or an install that already ran.
            if (!root.online && !root.imported && !root.installStarted && root.source === "auto")
                root.source = "offline";
        }
    }

    Process {
        id: importProc
        running: false
        property string path: ""
        command: ["python3", "-c", "import tomllib,json,sys; print(json.dumps(tomllib.load(open(sys.argv[1],'rb'))))", importProc.path]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text || "{}");
                    root.applyImport(d);
                    root.statusText = "Imported " + importProc.path;
                } catch (e) {
                    root.statusText = "Import failed: " + e;
                }
            }
        }
        stderr: StdioCollector { onStreamFinished: { if (text) root.statusText = "Import failed: " + text; } }
        onExited: (code) => { console.log("importProc exited", code, importProc.path); }
    }

    Process {
        id: zenityProc
        running: false
        command: ["zenity", "--file-selection", "--title=Import install.toml", "--file-filter=*.toml *.TOML"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = (text || "").trim();
                if (p) {
                    importPathField.text = p;
                    importProc.path = p;
                    importProc.running = true;
                }
            }
        }
    }

    Process {
        id: writeProc
        running: false
        stdinEnabled: true
        command: ["tee", root.configPath]
        onStarted: { write(root.generateToml()); stdinEnabled = false; }
        stdout: StdioCollector { onStreamFinished: {} }
        stderr: StdioCollector {
            onStreamFinished: {
                const ls = (text || "").replace(/\n$/, "").split("\n");
                for (let i = 0; i < ls.length; i++) root.appendLog(ls[i]);
            }
        }
        onExited: (code) => {
            root.writing = false;
            if (code !== 0) {
                root.statusText = "Failed to write config (exit " + code + ").";
                // Recoverable: let the user go back and try again.
                root.locked = false;
                return;
            }
            if (root.dryRun) {
                // A dry run is a review aid, not an install: unlock, land back
                // on the Review page and let the real Install be one click away.
                root.statusText = "Dry run complete. Config written to " + root.configPath;
                root.locked = false;
                root.step = 5;
                return;
            }
            root.statusText = "Applying configuration...";
            root.applying = true;
            applyProc.running = true;
        }
    }

    Process {
        id: applyProc
        running: false
        command: ["bash", root.applyScript, root.configPath, root.password, root.logFile]
        environment: ({ "ASSUME_YES": "1", "AEQUALYN_NO_REBOOT": "1", "AEQUALYN_TEE_LOG": "1", "AEQUALYN_INSTALL_LOCKSCREENS": root.installLockscreens ? "1" : "0" })
        stdout: SplitParser { onRead: (line) => { root.appendLog(line); } }
        stderr: SplitParser { onRead: (line) => { root.appendLog(line); } }
        onExited: (code) => {
            root.applying = false;
            root.flushLog();
            if (code === 0) {
                root.installFinished = true;
                root.statusText = "Installation complete. Log: " + root.logFile;
            } else {
                root.installFailed = true;
                // A failed install is recoverable: unlock the wizard so Back,
                // the step bar and a retry all work, and re-probe the network
                // to pick between the AI debug session and the offline page.
                root.locked = false;
                root.statusText = "Apply failed (exit " + code + "). See log: " + root.logFile;
                root.netChecking = true;
                netProc.running = true;
            }
        }
    }

    Process {
        id: rebootProc
        running: false
        command: root.isRoot ? ["systemctl", "reboot"] : ["pkexec", "systemctl", "reboot"]
        onExited: (code) => {
            root.rebooting = false;
            // if systemctl could not reboot, lift the splash again so the
            // error is visible in the installer window
            root.showSplash = false;
            root.statusText = "Reboot failed (exit " + code + "). Reboot manually.";
        }
    }

    Component.onCompleted: {
        root.detecting = true;
        detectProc.running = true;
        tzListProc.running = true;
        tzProc.running = true;
        lsblkProc.running = true;
        netProc.running = true;
    }

    // ---- AI debug session (failure path, online only) -----------------------
    // The Debug button writes this skill where opencode discovers it, then
    // opens foot running `opencode --auto` with a prompt that loads the skill.
    // Everything the agent needs -- the ISO and session details, the script,
    // config and log locations, and the job itself -- is in the body, filled
    // in from the real paths at click time.
    function debugSkillMd() {
        return "---\n" +
            "name: Aequalyn Install Debug\n" +
            "description: Fix a failed Aequalyn installation from the live ISO -- read the install log, repair and finish the install, or explain how to restart it.\n" +
            "---\n\n" +
            "# Aequalyn install debug\n\n" +
            "You are running as root inside the Aequalyn live ISO, in a foot terminal, after the guided installer reported a FAILED installation. The person watching this terminal just clicked Debug in the installer UI.\n\n" +
            "## The environment\n\n" +
            "- Live ISO: Aequalyn -- an Arch Linux base with the Aequalyn desktop (a Quickshell shell on Hyprland/Wayland) on top.\n" +
            "- You run as root. The live desktop user is `live` (password `live`, passwordless sudo).\n" +
            "- The distribution being installed: Arch Linux with Btrfs subvolumes + snapper, the Limine boot loader, LUKS2 when encryption was enabled, and the Aequalyn desktop -- configured end to end by install.toml.\n\n" +
            "## Where everything is\n\n" +
            "- Config under review: `" + root.configPath + "`\n" +
            "- Install log -- read this first: `" + root.logFile + "`\n" +
            "- Apply script that does the real work: `" + root.applyScript + "`\n" +
            "- Installer scripts: `" + root.installerDir + "` (aequalyn-detect, aequalyn-install-cli, aequalyn-repair, lib/apply.sh)\n" +
            "- Aequalyn source tree on the ISO: /opt/aequalyn\n" +
            "- Bundled offline package repo (works with no internet): /var/cache/offline-repo\n\n" +
            "## Your job\n\n" +
            "1. Read the end of the log first: `tail -n 150 " + root.logFile + "`.\n" +
            "2. Name the failing step in one line (partitioning, LUKS, pacstrap/pacman, boot loader, Aequalyn branding) and what went wrong.\n" +
            "3. Then try to FIX the installation and get it to the last step yourself. Prefer fixing forward: repair the failed step and continue from where it died. Re-running the whole apply (`ASSUME_YES=1 AEQUALYN_TEE_LOG=1 bash " + root.applyScript + " " + root.configPath + " <password> " + root.logFile + "`) is allowed only with the user's OK -- it re-partitions the disk named in install.toml, and it needs the account password, so ASK the user for it and never guess. Before anything destructive, confirm the disk in install.toml is really the one they want installed.\n" +
            "4. If fixing forward is not possible, provide clear instructions to restart the installation: go back to the installer (Retry install, or `aequalyn-install` from the dock), adjust whatever the log says went wrong, and click Install. The reviewed config is kept at `" + root.configPath + "` and can be re-imported (Load in the wizard, or `aequalyn-install --config " + root.configPath + "` in a terminal).\n" +
            "5. When you are done, tell the user exactly what state the system is in and what to do next: reboot into the new system, or restart the install.\n\n" +
            "For human help, the user can join " + root.discordInvite + " -- the installer shows a QR code for it next to the Debug button.\n";
    }

    function startDebug() {
        root.statusText = "Preparing the AI debug session...";
        // same re-arm as in startApply(): debugSkillProc closes its own stdin
        // after writing, so a second Debug click needs it enabled again
        debugSkillProc.stdinEnabled = true;
        debugSkillProc.running = true;
    }

    Process {
        id: debugSkillProc
        running: false
        stdinEnabled: true
        // Global opencode skills dir: discovered regardless of the project cwd.
        property string skillPath: Quickshell.env("HOME") + "/.config/opencode/skills/aequalyn-debug/SKILL.md"
        command: ["bash", "-c", "mkdir -p \"$(dirname " + JSON.stringify(skillPath) + ")\" && tee " + JSON.stringify(skillPath)]
        onStarted: { write(root.debugSkillMd()); stdinEnabled = false; }
        onExited: (code) => {
            if (code !== 0) {
                root.statusText = "Could not write the debug skill (exit " + code + ").";
                return;
            }
            root.statusText = "AI debug session opening in foot...";
            Quickshell.execDetached(["foot", "sh", "-lc",
                "cd " + JSON.stringify(Quickshell.env("HOME")) + " && opencode --auto --prompt " +
                JSON.stringify("The Aequalyn installation on this machine just failed. Load the @aequalyn-debug skill and follow it: read the install log, diagnose the failure, fix the installation and get it to the last step yourself. If you cannot fix it, explain exactly what went wrong and give me clear instructions to restart the installer and finish the install. For human help there is " + root.discordInvite + ".")]);
        }
    }

    // ---- UI parts: the control center's, drawn here ------------------------
    // A group of settings: a short title, a hint, then its rows in one rounded box with
    // a hairline between them (`boxed: false` for content that brings its own frame).
    component Group: ColumnLayout {
        id: g
        property string title: ""
        property string hint: ""
        property bool boxed: true
        property bool fill: false
        default property alias body: inner.data
        spacing: 6
        Layout.fillWidth: true
        Layout.fillHeight: g.fill
        Text {
            visible: g.title !== ""
            text: g.title
            color: root.textSecondary
            font.pixelSize: 13
            font.weight: Font.DemiBold
            Layout.leftMargin: 2
        }
        Text {
            visible: g.hint !== ""
            text: g.hint
            color: root.textMuted
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            Layout.leftMargin: 2
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: g.fill
            implicitHeight: inner.implicitHeight + (g.boxed ? 8 : 0)
            radius: 12
            color: g.boxed ? root.bgSurface : "transparent"
            border.width: g.boxed ? 1 : 0
            border.color: root.border
            ColumnLayout {
                id: inner
                x: g.boxed ? 4 : 0
                y: g.boxed ? 4 : 0
                width: parent.width - (g.boxed ? 8 : 0)
                height: g.fill ? parent.height - (g.boxed ? 8 : 0) : implicitHeight
                spacing: 0
            }
        }
    }

    // the hairline over every row but a group's first
    component Divider: Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        height: 1
        color: root.border
    }

    // a fact: its name on the left, its value on the right
    component InfoRow: Item {
        id: ir
        property string label: ""
        property string value: ""
        property bool first: false
        property color valueColor: root.textPrimary
        // long values wrap onto more lines instead of being shortened in the middle
        property bool wrap: false
        Layout.fillWidth: true
        implicitHeight: ir.wrap ? Math.max(34, irValue.implicitHeight + 16) : 34
        Divider { visible: !ir.first }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 128
            text: ir.label
            color: root.textMuted
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 148
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            id: irValue
            text: ir.value
            color: ir.valueColor
            font.pixelSize: 13
            wrapMode: ir.wrap ? Text.WordWrap : Text.NoWrap
            elide: ir.wrap ? Text.ElideNone : Text.ElideMiddle
        }
    }

    // a line to type in, framed as the control center's fields are
    component Field: Rectangle {
        id: fd
        property alias text: input.text
        property alias echoMode: input.echoMode
        property alias validator: input.validator
        property alias input: input
        property string placeholder: ""
        property bool mono: false
        signal edited(string text)
        Layout.fillWidth: true
        implicitHeight: 34
        radius: 8
        color: root.bgBase
        border.width: 1
        border.color: input.activeFocus ? root.accent : root.border
        opacity: enabled ? 1 : 0.5
        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            color: root.textPrimary
            selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
            font.pixelSize: 13
            font.family: fd.mono ? "monospace" : Qt.application.font.family
            clip: true
            enabled: !root.locked
            onTextEdited: fd.edited(text)
            Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: input.text === "" && !input.activeFocus
                text: fd.placeholder
                color: root.textMuted
                font: input.font
            }
        }
    }

    // a field in a row: its name on the left, the field on the right
    component FieldRow: Item {
        id: fr
        property string label: ""
        property bool first: false
        default property alias field: slot.data
        Layout.fillWidth: true
        implicitHeight: 46
        Divider { visible: !fr.first }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 128
            text: fr.label
            color: root.textSecondary
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        RowLayout {
            id: slot
            anchors.left: parent.left
            anchors.leftMargin: 148
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
        }
    }

    // the control center's switch
    component Switch: Rectangle {
        id: sw
        property bool checked: false
        signal toggled(bool value)
        implicitWidth: 44
        implicitHeight: 26
        radius: 13
        color: checked ? root.accent : root.bgSelected
        opacity: enabled ? 1 : 0.4
        Behavior on color { ColorAnimation { duration: 140 } }
        Rectangle {
            width: 18; height: 18; radius: 9
            y: 4
            x: sw.checked ? sw.width - width - 4 : 4
            color: sw.checked ? root.bgBase : root.textMuted
            Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
        MouseArea {
            anchors.fill: parent
            enabled: sw.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: sw.toggled(!sw.checked)
        }
    }

    // something on or off: a title, what it does, and a switch
    component ToggleRow: Item {
        id: tr
        property string title: ""
        property string sub: ""
        property bool checked: false
        property bool first: false
        signal toggled(bool value)
        Layout.fillWidth: true
        implicitHeight: tr.sub !== "" ? 52 : 40
        Divider { visible: !tr.first }
        ColumnLayout {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: trSwitch.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text { text: tr.title; color: root.textPrimary; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
            Text { visible: tr.sub !== ""; text: tr.sub; color: root.textMuted; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
        }
        Switch {
            id: trSwitch
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            checked: tr.checked
            enabled: !root.locked
            onToggled: v => tr.toggled(v)
        }
        MouseArea {
            anchors.fill: parent
            anchors.rightMargin: 64
            enabled: !root.locked
            cursorShape: Qt.PointingHandCursor
            onClicked: tr.toggled(!tr.checked)
        }
    }

    // one of a few: chips, as the control center's choices
    component Chips: Flow {
        id: ch
        property var options: []          // [{ key, label }]
        property string current: ""
        signal chosen(string key)
        Layout.fillWidth: true
        spacing: 6
        Repeater {
            model: ch.options
            delegate: Rectangle {
                id: chip
                required property var modelData
                readonly property bool on: ch.current === modelData.key
                width: chipText.implicitWidth + 24
                height: 32
                radius: 8
                color: on ? root.bgSelected : chipArea.containsMouse ? root.bgHover : root.bgSurface
                border.width: 1
                border.color: on ? root.accent : root.border
                opacity: root.locked ? 0.5 : 1
                Text {
                    id: chipText
                    anchors.centerIn: parent
                    text: chip.modelData.label
                    color: chip.on ? root.accent : root.textSecondary
                    font.pixelSize: 12
                    font.weight: chip.on ? Font.DemiBold : Font.Normal
                }
                MouseArea {
                    id: chipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !root.locked
                    cursorShape: Qt.PointingHandCursor
                    onClicked: ch.chosen(chip.modelData.key)
                }
            }
        }
    }

    // a button: the main one filled with the accent, the others quiet
    component Btn: Rectangle {
        id: bt
        property string text: ""
        property bool primary: false
        signal clicked()
        implicitWidth: btText.implicitWidth + 28
        implicitHeight: 34
        radius: 8
        color: !enabled ? root.bgHover : bt.primary ? (btArea.containsMouse ? Qt.lighter(root.accent, 1.1) : root.accent)
             : btArea.containsMouse ? root.bgHover : root.bgSurface
        border.width: bt.primary ? 0 : 1
        border.color: root.border
        opacity: enabled ? 1 : 0.6
        Text {
            id: btText
            anchors.centerIn: parent
            text: bt.text
            color: bt.primary && bt.enabled ? root.bgBase : root.textPrimary
            font.pixelSize: 13
            font.weight: bt.primary ? Font.DemiBold : Font.Normal
        }
        MouseArea {
            id: btArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: bt.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: bt.clicked()
        }
    }

    // Auto-following, virtualised log view. Used by the Finish page.
    component LogView: Rectangle {
        color: root.bgSurface
        radius: 12
        border.color: root.border
        border.width: 1
        clip: true

        ListView {
            id: logView
            anchors.fill: parent
            anchors.margins: 10
            clip: true
            model: logModel
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Text {
                required property string line
                width: logView.width
                text: line
                color: root.textSecondary
                font.family: "monospace"
                font.pixelSize: 11
                wrapMode: Text.WrapAnywhere
            }
            function followEnd() {
                if (root.logFollow) Qt.callLater(() => logView.positionViewAtEnd());
            }
            onCountChanged: followEnd()
            onHeightChanged: followEnd()
            onVisibleChanged: if (visible) followEnd()
            onMovementStarted: root.logFollow = false
            onMovementEnded: root.logFollow = atYEnd
            onAtYEndChanged: if (atYEnd) root.logFollow = true
        }
    }

    // ways of installing, in words
    readonly property var modeOptions: [
        { key: "fullwipe", label: "Whole disk", about: "Erases the disk you chose and installs Aequalyn as its only system." },
        { key: "dualboot", label: "Next to Windows", about: "Keeps Windows and installs Aequalyn in the free space beside it." },
        { key: "manual", label: "Manual", about: "Uses the partitions you prepared yourself; nothing else is changed." }
    ]
    function modeLabel(m) { const o = root.modeOptions.find(x => x.key === m); return o ? o.label : m; }
    function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1); }


    // Every action in the wizard: 52 px tall, 16 pt demi-bold, with its own
    // hover and press states. `primary` picks the accent-filled variant used
    // for the one main action of a screen; everything else is bordered.
    component BigButton: Button {
        id: btn
        property bool primary: false
        hoverEnabled: true
        implicitHeight: 52
        leftPadding: 24
        rightPadding: 24
        topPadding: 0
        bottomPadding: 0
        scale: pressed ? 0.97 : 1
        Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
        background: Rectangle {
            radius: 14
            color: !btn.enabled ? root.bgHover
                 : btn.primary ? (btn.pressed ? Qt.darker(root.accent, 1.15)
                    : btn.hovered ? Qt.lighter(root.accent, 1.08) : root.accent)
                 : btn.pressed ? root.bgSelected
                 : btn.hovered ? root.bgHover : root.bgSurface
            border.width: btn.primary ? 0 : 1
            border.color: btn.primary ? "transparent"
                 : (btn.hovered && btn.enabled) ? root.accent : root.border
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        contentItem: Text {
            text: btn.text
            color: !btn.enabled ? root.textMuted : btn.primary ? root.bgBase : root.textPrimary
            font.pixelSize: 16
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // ---- import dialog ----
    FileDialog {
        id: importDialog
        title: "Import install.toml"
        nameFilters: ["TOML files (*.toml)", "All files (*)"]
        onAccepted: {
            console.log("import accepted:", importDialog.selectedFile);
            const path = importDialog.selectedFile.toString().replace("file://", "");
            importProc.path = path;
            importProc.running = true;
        }
    }

    // ---- window geometry persistence ----
    function saveGeom() {
        saveGeomProc.running = true;
    }

    Process {
        id: saveGeomProc
        running: false
        stdinEnabled: true
        command: ["bash", "-c", "mkdir -p \"$(dirname " + JSON.stringify(root.geomPath) + ")\" && tee " + JSON.stringify(root.geomPath)]
        onStarted: {
            // Only the size is remembered. Wayland never lets a window place
            // itself -- the compositor decides where it opens -- and this
            // Quickshell's FloatingWindow has no x/y to read or write anyway.
            write("width=" + win.width + "\nheight=" + win.height + "\n");
        }
    }

    FileView {
        id: geomView
        path: root.geomPath
        preload: true
        onLoaded: {
            const lines = (geomView.text() || "").trim().split("\n");
            for (let i = 0; i < lines.length; i++) {
                const kv = lines[i].split("=");
                if (kv.length < 2) continue;
                const k = kv[0].trim();
                const v = parseInt(kv[1].trim());
                if (isNaN(v)) continue;
                // x/y lines from older configs are ignored on purpose.
                if (k === "width") win.implicitWidth = v;
                if (k === "height") win.implicitHeight = v;
            }
        }
    }

    // ---- UI ----
    FloatingWindow {
        id: win
        title: "Aequalyn Installer"
        visible: true
        Component.onDestruction: root.saveGeom()
        // Closed from outside (Super+Q, the titlebar's close button): Quickshell
        // keeps running without a window, so the next launch would say "already
        // open". Quit the same as the ✕ does; mid-install, bring the window back.
        onClosed: {
            if (root.writing || root.applying) Qt.callLater(() => { win.visible = true });
            else Qt.quit();
        }
        color: root.bgBase
        implicitWidth: 1280
        implicitHeight: 760
        maximumSize: Qt.size(10000, 10000)
        minimumSize: Qt.size(400, 300)

        Rectangle {
            id: frame
            anchors.fill: parent
            color: root.bgBase
            radius: 20
            border.color: root.border
            border.width: 1
            clip: true

            // The whole installer is laid out for a 1336 x 728 window (a 1366 x 768 screen)
            // and scaled as one to fill whatever window it gets: larger on a larger screen,
            // a little smaller on a smaller one, the same proportions everywhere.
            Item {
                id: scaler
                readonly property real s: Math.max(0.7, Math.min(3, Math.min(frame.width / 1336, frame.height / 728)))
                width: frame.width / s
                height: frame.height / s
                scale: s
                transformOrigin: Item.TopLeft

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 0
                spacing: 0

                // ---- the title bar: the name, then the step --------------------------
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 64
                    color: "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 22
                        anchors.rightMargin: 18
                        spacing: 14
                        Image {
                            source: Qt.resolvedUrl(root.light ? "assets/aequalyn-wordmark-dark.svg" : "assets/aequalyn-wordmark.svg")
                            // drawn at the size it is shown, so it stays sharp when scaled up
                            sourceSize.height: Math.round(30 * scaler.s)
                            fillMode: Image.PreserveAspectFit
                            // its box kept to the wordmark's own proportions (728 x 179), not
                            // to the size it is drawn at, so the gap after it stays the same
                            Layout.preferredHeight: 30
                            Layout.preferredWidth: Math.round(30 * 728 / 179)
                            Layout.alignment: Qt.AlignVCenter
                            Accessible.name: "Aequalyn"
                        }
                        Text {
                            text: "Installer"
                            color: root.accent
                            font.pixelSize: 16
                            font.weight: Font.DemiBold
                            Layout.alignment: Qt.AlignVCenter
                            Layout.topMargin: 3
                        }
                        Rectangle { implicitWidth: 1; implicitHeight: 30; color: root.border; Layout.leftMargin: 6; Layout.rightMargin: 6 }
                        ColumnLayout {
                            spacing: 1
                            Layout.fillWidth: true
                            Text {
                                text: root.page === "install" ? root.stepNames[root.step]
                                    : root.page === "repair" ? "Repair" : root.page === "manual" ? "Manual" : "Welcome"
                                color: root.textPrimary
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: root.page === "install" ? root.stepDescriptions[root.step]
                                    : root.page === "repair" ? "Fix an installed Aequalyn from the live system"
                                    : root.page === "manual" ? "Aequalyn's README, as it ships on this ISO"
                                    : "Install, repair, or read the manual first"
                                color: root.textMuted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                        Text {
                            visible: root.page === "install"
                            text: (root.step + 1) + " / " + root.stepNames.length
                            color: root.textMuted
                            font.pixelSize: 12
                        }
                        Rectangle {
                            implicitWidth: 30; implicitHeight: 30; radius: 8
                            color: closeArea.containsMouse ? root.bgHover : "transparent"
                            // dimmed like the step bar while an install is in flight
                            opacity: closeArea.enabled ? 1.0 : 0.4
                            Text { anchors.centerIn: parent; text: "✕"; color: root.textSecondary; font.pixelSize: 14 }
                            MouseArea {
                                id: closeArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                // quitting mid-install would kill the apply halfway
                                // through the disk; success or failure re-activate it
                                enabled: !(root.writing || root.applying)
                                // belt and braces: never quit while a process runs
                                onClicked: if (!(root.writing || root.applying)) Qt.quit()
                            }
                        }
                    }
                    Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.border }
                }

                // ---- the panel: everything of a step, side by side; it scrolls only where the
                // window is too low for the step (small screens, large text) -------------
                Flickable {
                    id: stepFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 20
                    // the panel takes the room between the title bar and the steps, never
                    // more: the steps and the buttons under it stay where they are
                    Layout.minimumHeight: 0
                    Layout.preferredHeight: 0
                    implicitHeight: 0
                    clip: true
                    visible: root.page === "install"
                    contentWidth: width
                    contentHeight: stepStack.height
                    interactive: contentHeight > height
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: stepFlick.interactive ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }
                    Connections {
                        target: root
                        function onStepChanged() { stepFlick.contentY = 0 }
                    }
                StackLayout {
                    id: stepStack
                    readonly property Item page: stepStack.children[stepStack.currentIndex] || null
                    width: stepFlick.width - (stepFlick.interactive ? 12 : 0)
                    height: Math.max(stepFlick.height, stepStack.page ? stepStack.page.implicitHeight : 0)
                    currentIndex: root.step

                    // 0 Welcome
                    RowLayout {
                        spacing: 20
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 14
                            Group {
                                title: "Your computer"
                                hint: root.detecting ? "Looking at your hardware…" : "What the installer found. Everything it proposes can be changed in the next steps."
                                InfoRow { first: true; label: "Firmware"; value: String(root.detect.firmware || "—").toUpperCase() }
                                InfoRow { label: "Processor"; value: ({ GenuineIntel: "Intel", AuthenticAMD: "AMD" })[root.detect.cpu_vendor] || root.detect.cpu_vendor || "—"; }
                                InfoRow { label: "Graphics"; value: String(root.detect.gpu_vendors || "—").split(",").map(root.cap).join(", ") }
                                InfoRow { label: "Memory"; value: (root.detect.mem_gb || "?") + " GiB" }
                                InfoRow { label: "Battery"; value: root.detect.battery === "yes" ? "Yes, a laptop" : (root.detect.battery || "—") }
                                InfoRow { label: "Disks"; value: (root.detect.disk_count || 0) + "  ·  first " + (root.detect.first_disk || "none") + (root.detect.free_gb !== undefined ? "  ·  " + root.detect.free_gb + " GB unpartitioned" : "") }
                                InfoRow { label: "Windows"; value: root.detect.win_efi ? "Found on " + root.detect.win_efi : "Not found" }
                                InfoRow {
                                    label: "Internet"
                                    value: root.netChecking ? "Checking…" : (root.online ? "Connected: online installs available" : "Not connected: the offline install is proposed")
                                    valueColor: !root.netChecking && !root.online ? root.warn : root.textPrimary
                                }
                            }
                            RowLayout {
                                spacing: 10
                                Btn {
                                    text: root.detecting ? "Looking…" : "Look again"
                                    enabled: !root.locked && !root.detecting
                                    onClicked: {
                                        root.detecting = true;
                                        detectProc.running = true;
                                        lsblkProc.running = true;
                                        root.netChecking = true;
                                        netProc.running = true;
                                    }
                                }
                                Text {
                                    text: root.statusText
                                    visible: root.statusText !== ""
                                    color: root.warn
                                    font.pixelSize: 12
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                            }
                            Text {
                                text: "No internet connection: the bundled offline repository is proposed, and Online as a package source could not download anything."
                                color: root.warn
                                visible: !root.netChecking && !root.online
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                                Layout.leftMargin: 2
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 14
                            Group {
                                title: "What it proposes"
                                InfoRow { first: true; label: "Profiles"; value: (root.detect.profiles || ["minimal"]).map(root.cap).join(", ") }
                                InfoRow { label: "Install"; value: root.modeLabel(root.detect.mode || "fullwipe") }
                                InfoRow { label: "Encryption"; value: root.detect.encrypt === true ? "On (LUKS2)" : "Off" }
                            }
                            Group {
                                title: "Your choices, in one file"
                                hint: "Every step writes into install.toml. You see it on Review, and nothing is installed until you approve it there."
                                InfoRow { first: true; label: "Written to"; value: root.configPath; valueColor: root.accent }
                            }
                            Group {
                                title: "Or start from a saved install.toml"
                                hint: "A file from an earlier install fills in every step: you review it and type a password."
                                FieldRow {
                                    first: true
                                    label: "File"
                                    Field {
                                        id: importPathField
                                        mono: true
                                        placeholder: "/path/to/install.toml"
                                    }
                                    Btn {
                                        text: "Load"
                                        enabled: !root.locked
                                        onClicked: {
                                            if (importPathField.text.trim() === "") { root.statusText = "Enter a path to install.toml"; return; }
                                            importProc.path = importPathField.text.trim();
                                            importProc.running = true;
                                        }
                                    }
                                    Btn {
                                        text: "Browse"
                                        primary: true
                                        enabled: !root.locked
                                        onClicked: zenityProc.running = true
                                    }
                                }
                            }
                            Text {
                                visible: root.imported
                                text: "Imported config loaded. Review and apply."
                                color: root.ok
                                font.pixelSize: 12
                            }
                        }
                    }

                    // 1 Identity
                    RowLayout {
                        spacing: 20
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 14
                            Group {
                                title: "This computer, and you"
                                hint: "Its name on the network, your account, and the keyboard layout of the text console."
                                FieldRow { first: true; label: "Computer name"; Field { text: root.hostname; placeholder: "aequalyn"; onEdited: t => root.hostname = t } }
                                FieldRow { label: "Your username"; Field { text: root.username; placeholder: "user"; onEdited: t => root.username = t } }
                                FieldRow { label: "Console keymap"; Field { text: root.keymap; mono: true; placeholder: "us, uk, de…"; onEdited: t => root.keymap = t } }
                            }
                            Group {
                                title: "Password"
                                hint: "For your account and for root; it unlocks the disk too when encryption is on."
                                FieldRow { first: true; label: "Password"; Field { echoMode: TextInput.Password; text: root.password; onEdited: t => root.password = t } }
                                FieldRow { label: "Again"; Field { echoMode: TextInput.Password; text: root.passwordConfirm; onEdited: t => root.passwordConfirm = t } }
                            }
                            Text {
                                text: root.password === "" ? "The password can't be empty." :
                                      (root.password !== root.passwordConfirm ? "The two passwords don't match." : "✓  The passwords match.")
                                color: (root.password === "" || root.password !== root.passwordConfirm) ? root.warn : root.ok
                                font.pixelSize: 12
                                Layout.leftMargin: 2
                            }
                        }
                        Group {
                            title: "Time zone"
                            hint: "Drag to turn it, Ctrl + scroll to zoom, click a location to take its time zone."
                            fill: true
                            Layout.preferredWidth: 1
                            TimezoneGlobe {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                // as tall as the panel leaves it, never taller
                                Layout.preferredHeight: 160
                                Layout.minimumHeight: 120
                                Layout.margins: 4
                                selectedTimezone: root.timezone
                                onTimezoneSelected: (tz) => root.timezone = tz
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.margins: 8
                                spacing: 10
                                Text { text: root.timezone; color: root.accent; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                Btn { text: "Use this computer's"; enabled: !root.locked; onClicked: tzProc.running = true }
                            }
                        }
                    }

                    // 2 Disk
                    RowLayout {
                        spacing: 20
                        Group {
                            title: "Install on"
                            hint: "The disk Aequalyn goes on. The live USB you started from isn't listed."
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            Repeater {
                                model: root.disks
                                delegate: Rectangle {
                                    id: diskRow
                                    required property var modelData
                                    required property int index
                                    readonly property bool on: root.selectedDisk === modelData.name
                                    Layout.fillWidth: true
                                    implicitHeight: 56
                                    radius: 8
                                    color: on ? root.bgSelected : diskArea.containsMouse ? root.bgHover : "transparent"
                                    border.width: on ? 1 : 0
                                    border.color: root.accent
                                    Divider { visible: diskRow.index > 0 && !diskRow.on }
                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        spacing: 12
                                        Rectangle {
                                            implicitWidth: 18; implicitHeight: 18; radius: 9
                                            color: "transparent"
                                            border.width: 2
                                            border.color: diskRow.on ? root.accent : root.textMuted
                                            Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: 4; color: root.accent; visible: diskRow.on }
                                        }
                                        ColumnLayout {
                                            spacing: 1
                                            Layout.fillWidth: true
                                            Text { text: diskRow.modelData.model || "Disk"; color: root.textPrimary; font.pixelSize: 13; font.weight: diskRow.on ? Font.DemiBold : Font.Normal; elide: Text.ElideRight; Layout.fillWidth: true }
                                            Text { text: diskRow.modelData.name; color: root.textMuted; font.pixelSize: 11; font.family: "monospace" }
                                        }
                                        Text { text: diskRow.modelData.size; color: diskRow.on ? root.accent : root.textSecondary; font.pixelSize: 14; font.weight: Font.DemiBold }
                                    }
                                    MouseArea {
                                        id: diskArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        enabled: !root.locked
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.selectedDisk = diskRow.modelData.name
                                    }
                                }
                            }
                            Text {
                                visible: root.disks.length === 0
                                text: "No disk found to install on."
                                color: root.warn
                                font.pixelSize: 13
                                Layout.margins: 12
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 14
                            Group {
                                title: "How"
                                hint: (root.modeOptions.find(x => x.key === root.mode) || {}).about || ""
                                boxed: false
                                Chips {
                                    options: root.modeOptions
                                    current: root.mode
                                    onChosen: key => root.mode = key
                                }
                            }
                            Group {
                                title: "Encryption and boot"
                                ToggleRow {
                                    first: true
                                    title: "Encrypt the system (LUKS2)"
                                    sub: "Your password unlocks it at every start."
                                    checked: root.encrypt
                                    onToggled: v => root.encrypt = v
                                }
                                FieldRow {
                                    label: "EFI partition"
                                    Field {
                                        mono: true
                                        text: root.efiSizeMb
                                        validator: IntValidator { bottom: 300; top: 8192 }
                                        onEdited: t => { const v = parseInt(t, 10); if (!isNaN(v) && v >= 300 && v <= 8192) root.efiSizeMb = v; }
                                    }
                                    Text { text: "MB"; color: root.textMuted; font.pixelSize: 12 }
                                }
                            }
                            Text {
                                text: "2048 MB is recommended: the EFI partition holds the kernel, the initramfs and the boot menu, with room for snapshots and firmware updates."
                                color: root.textMuted
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                                Layout.leftMargin: 2
                            }
                        }
                    }

                    // 3 Packages
                    RowLayout {
                        spacing: 20
                        Group {
                            title: "Profiles"
                            hint: "The base system is always there: Chromium, Files, a terminal. Minimal leaves it at that; the others add to it, any of them together."
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            ToggleRow {
                                first: true
                                title: "Minimal"
                                sub: "The base system and nothing more"
                                checked: root.selectedProfiles().length === 1
                                onToggled: v => { if (v) for (const p of root.profileDefs) root[p.key] = false; }
                            }
                            Repeater {
                                model: root.profileDefs
                                delegate: ToggleRow {
                                    required property var modelData
                                    title: modelData.title
                                    sub: modelData.sub
                                    checked: root[modelData.key]
                                    onToggled: v => root[modelData.key] = v
                                }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 12
                            Group {
                                title: "Browser"
                                boxed: false
                                Chips {
                                    options: [{ key: "chromium", label: "Chromium" }, { key: "firefox", label: "Firefox" }, { key: "zen", label: "Zen" }]
                                    current: root.browser
                                    onChosen: key => root.browser = key
                                }
                            }
                            RowLayout {
                                spacing: 20
                                Group {
                                    title: "Packages from"
                                    boxed: false
                                    Layout.preferredWidth: 1
                                    Chips {
                                        options: [{ key: "auto", label: "Auto" }, { key: "offline", label: "Offline" }, { key: "online", label: "Online" }]
                                        current: root.source
                                        onChosen: key => root.source = key
                                    }
                                }
                                Group {
                                    title: "Terminal editor"
                                    boxed: false
                                    Layout.preferredWidth: 1
                                    Chips {
                                        options: [{ key: "nano", label: "Nano" }, { key: "vim", label: "Vim" }]
                                        current: root.editor
                                        onChosen: key => root.editor = key
                                    }
                                }
                            }
                            Text {
                                text: "The ISO bundles the base system only: what these profiles add is downloaded, at the first start with internet."
                                color: root.warn
                                visible: root.selectedProfiles().length > 1
                                    && (root.source === "offline" || (!root.netChecking && !root.online))
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                                Layout.leftMargin: 2
                            }
                            Text {
                                text: "No internet connection: the bundled offline repository is proposed, and an Online source would fail to download packages."
                                color: root.warn
                                visible: !root.netChecking && !root.online
                                font.pixelSize: 12
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                                Layout.leftMargin: 2
                            }
                            Group {
                                title: "Extras"
                                ToggleRow {
                                    first: true
                                    title: "Web apps"
                                    sub: "Reddit, ChatGPT, YouTube, YouTube Music, WhatsApp, Gmail, GitHub"
                                    checked: root.seedWebapps
                                    onToggled: v => root.seedWebapps = v
                                }
                                ToggleRow {
                                    title: "Flatpak"
                                    sub: "Apps from Flathub, beside the Arch packages"
                                    checked: root.flatpak
                                    onToggled: v => root.flatpak = v
                                }
                                ToggleRow {
                                    title: "Login screen themes"
                                    sub: "Echo, pixie, qylock… about 400 MB to download, 600 MB on disk"
                                    checked: root.installLockscreens
                                    onToggled: v => root.installLockscreens = v
                                }
                            }
                        }
                    }

                    // 4 Aequalyn
                    RowLayout {
                        spacing: 20
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            spacing: 14
                            Group {
                                title: "Colours come from"
                                hint: root.themeMode === "wallpaper" ? "Every wallpaper paints the desktop, the apps and the terminal in its own colours."
                                    : root.themeMode === "theme" ? "A theme's own colours, the same whatever the wallpaper."
                                    : "Light colours, made from the wallpaper."
                                boxed: false
                                Chips {
                                    options: [{ key: "wallpaper", label: "The wallpaper" }, { key: "theme", label: "A theme" }, { key: "light", label: "Light" }]
                                    current: root.themeMode
                                    onChosen: key => root.themeMode = key
                                }
                            }
                            Group {
                                ToggleRow {
                                    first: true
                                    title: "GTK apps follow the colours"
                                    sub: "Third-party GTK apps take the desktop's colours too"
                                    checked: root.themeApps
                                    onToggled: v => root.themeApps = v
                                }
                                ToggleRow {
                                    title: "Dry run"
                                    sub: "Writes install.toml and installs nothing"
                                    checked: root.dryRun
                                    onToggled: v => root.dryRun = v
                                }
                            }
                        }
                        Group {
                            title: "The top bar, at first start"
                            hint: "Its widgets from left to right; move them later on the Bar page of Settings."
                            Layout.preferredWidth: 1
                            Layout.alignment: Qt.AlignTop
                            InfoRow { first: true; wrap: true; label: "Left"; value: root.barLeft.map(root.widgetName).join(", ") }
                            InfoRow { wrap: true; label: "Middle"; value: root.barCenter.map(root.widgetName).join(", ") }
                            InfoRow { wrap: true; label: "Right"; value: root.barRight.map(root.widgetName).join(", ") }
                        }
                    }

                    // 5 Review
                    RowLayout {
                        spacing: 20
                        // the summary takes a little over a third; the file the rest, so its
                        // lines wrap less and all of it shows
                        ColumnLayout {
                            Layout.fillWidth: false
                            Layout.preferredWidth: Math.round((scaler.width - 40) * 0.36)
                            Layout.alignment: Qt.AlignTop
                            spacing: 12
                            Group {
                                title: "Summary"
                                InfoRow { first: true; label: "Computer"; value: root.hostname }
                                InfoRow { label: "User"; value: root.username }
                                InfoRow { label: "Time zone"; value: root.timezone + "  ·  keymap " + root.keymap }
                                InfoRow { label: "Disk"; value: root.selectedDisk + "  ·  " + root.modeLabel(root.mode) }
                                InfoRow { label: "Encryption"; value: root.encrypt ? "On (LUKS2)" : "Off" }
                                InfoRow { label: "Profiles"; value: root.selectedProfiles().map(root.cap).join(", ") }
                                InfoRow { label: "Apps"; value: root.cap(root.browser) + "  ·  " + root.cap(root.editor) + (root.flatpak ? "  ·  Flatpak" : "") }
                                InfoRow { label: "Colours"; value: "From " + (root.themeMode === "theme" ? "a theme" : root.themeMode === "light" ? "the wallpaper, light" : "the wallpaper") }
                            }
                            Group {
                                visible: root.imported
                                hint: "Imported configs don't store passwords: type one before installing."
                                FieldRow { first: true; label: "Password"; Field { echoMode: TextInput.Password; text: root.password; onEdited: t => root.password = t } }
                                FieldRow { label: "Again"; Field { echoMode: TextInput.Password; text: root.passwordConfirm; onEdited: t => root.passwordConfirm = t } }
                            }
                            Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            BigButton {
                                Layout.fillWidth: true
                                primary: true
                                enabled: !(root.writing || root.applying) && !root.locked
                                text: root.writing ? "Writing…" : (root.applying ? "Applying…" : (root.dryRun ? "Write install.toml (dry run)" : "Install Aequalyn"))
                                onClicked: root.startApply()
                            }
                        }
                        Group {
                            id: tomlGroup
                            title: "install.toml"
                            hint: "Nothing is written to disk until you press Install."
                            fill: true
                            readonly property var parts: {
                                const t = root.generateToml();
                                const i = t.indexOf("\n[packages]");
                                return i < 0 ? [t, ""] : [t.slice(0, i), t.slice(i + 1)];
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.margins: 10
                                spacing: 16
                                Repeater {
                                    model: 2
                                    delegate: Text {
                                        required property int index
                                        Layout.fillWidth: true
                                        Layout.preferredWidth: 1
                                        Layout.fillHeight: true
                                        text: tomlGroup.parts[index]
                                        color: root.textSecondary
                                        font.family: "monospace"
                                        font.pixelSize: 10
                                        lineHeight: 0.95
                                        wrapMode: Text.WrapAnywhere
                                        verticalAlignment: Text.AlignTop
                                    }
                                }
                            }
                        }
                    }

                    // 6 Finish: progress while installing, then a staged end -- Finish
                    // acknowledges the outcome, and Reboot Now (success) or Debug /
                    // Retry (failure) follow it. The Close ✕ is blocked only while
                    // the apply runs -- quitting mid-install would kill it -- and
                    // comes back with the outcome, when there is nothing left to
                    // decide but reboot, retry or debug.
                    // After a failure the help sits beside the log, so nothing scrolls.
                    ColumnLayout {
                        spacing: 12
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 16
                            Text {
                                text: (root.writing || root.applying) ? "Installing Aequalyn…"
                                     : root.installFinished ? "Installation complete"
                                     : root.installFailed ? "Installation failed"
                                     : "Finish"
                                color: root.installFailed ? root.warn : (root.installFinished ? root.ok : root.textPrimary)
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: root.statusText
                                visible: root.statusText !== ""
                                color: root.installFailed ? root.warn : root.textSecondary
                                font.pixelSize: 12
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }
                        }
                        ProgressBar {
                            id: progress
                            Layout.fillWidth: true
                            implicitHeight: 6
                            indeterminate: root.writing || root.applying
                            value: (root.writing || root.applying) ? 0 : 1
                            background: Rectangle { implicitHeight: 6; radius: 3; color: root.bgSelected }
                            contentItem: Item {
                                implicitHeight: 6
                                clip: true
                                Rectangle {
                                    id: bar
                                    height: parent.height
                                    radius: 3
                                    color: root.installFailed ? root.warn : root.installFinished ? root.ok : root.accent
                                    width: progress.indeterminate ? parent.width * 0.3 : parent.width * progress.visualPosition
                                    x: 0
                                    SequentialAnimation on x {
                                        running: progress.indeterminate
                                        loops: Animation.Infinite
                                        NumberAnimation { from: -bar.width; to: progress.width; duration: 1400; easing.type: Easing.InOutQuad }
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 16
                            LogView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.minimumHeight: 80
                            }
                            // after a failure: what went wrong, and where to get help
                            ColumnLayout {
                                visible: root.installFailed
                                Layout.preferredWidth: 380
                                Layout.maximumWidth: 380
                                Layout.fillHeight: true
                                spacing: 12
                                // offline: no AI debug session without the network, so
                                // say sorry and point at the log
                                Group {
                                    visible: !root.online
                                    title: "We're sorry"
                                    Text {
                                        text: "Your installation failed. Please look at the log, then retry."
                                        color: root.textSecondary
                                        font.pixelSize: 12
                                        wrapMode: Text.WordWrap
                                        Layout.fillWidth: true
                                        Layout.margins: 12
                                        Layout.bottomMargin: 2
                                    }
                                    // the whole path: it is what this box is for
                                    Text {
                                        text: root.logFile
                                        color: root.accent
                                        font.family: "monospace"
                                        font.pixelSize: 12
                                        wrapMode: Text.WrapAnywhere
                                        Layout.fillWidth: true
                                        Layout.margins: 12
                                        Layout.topMargin: 0
                                    }
                                }
                                // any failure: human help, one scan away
                                Group {
                                    title: "Need a hand?"
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Layout.margins: 10
                                        spacing: 12
                                        // white card: a QR scans best dark on light
                                        Rectangle {
                                            Layout.preferredWidth: 112
                                            Layout.preferredHeight: 112
                                            radius: 10
                                            color: "#ffffff"
                                            Image {
                                                anchors.centerIn: parent
                                                source: Qt.resolvedUrl("assets/discord-qr.png")
                                                asynchronous: true
                                                width: 98
                                                height: 98
                                                fillMode: Image.PreserveAspectFit
                                                smooth: false
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 4
                                            Text { text: "Join us at"; color: root.textSecondary; font.pixelSize: 12 }
                                            Text { text: root.discordInvite; color: root.accent; font.pixelSize: 12; wrapMode: Text.WrapAnywhere; Layout.fillWidth: true }
                                            Text { text: "Scan the code with your phone to get to us for help."; color: root.textMuted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                            Text {
                                                text: "Debug opens an AI repair session in a terminal; the first run may ask you to sign in."
                                                color: root.textMuted
                                                visible: root.finishAcknowledged && root.online
                                                font.pixelSize: 11
                                                wrapMode: Text.WordWrap
                                                Layout.fillWidth: true
                                            }
                                        }
                                    }
                                }
                                Item { Layout.fillHeight: true }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            BigButton {
                                primary: true
                                Layout.preferredWidth: 240
                                text: "Finish"
                                visible: !root.finishAcknowledged && (root.installFinished || root.installFailed)
                                onClicked: root.finishAcknowledged = true
                            }
                            BigButton {
                                primary: true
                                Layout.preferredWidth: 240
                                text: root.rebooting ? "Rebooting…" : "Reboot Now"
                                visible: root.finishAcknowledged && root.installFinished && !root.installFailed
                                enabled: !root.rebooting
                                onClicked: {
                                    root.saveGeom();
                                    root.rebooting = true;
                                    root.statusText = "Rebooting...";
                                    // the goodbye splash covers the screen first; the timer
                                    // fires the reboot
                                    root.showSplash = true;
                                    splashTimer.start();
                                }
                            }
                            BigButton {
                                primary: true
                                Layout.preferredWidth: 240
                                text: "Debug"
                                visible: root.finishAcknowledged && root.installFailed && root.online
                                onClicked: root.startDebug()
                            }
                            BigButton {
                                primary: !root.online
                                Layout.preferredWidth: 200
                                text: "Retry install"
                                visible: root.finishAcknowledged && root.installFailed
                                onClicked: {
                                    root.finishAcknowledged = false;
                                    root.step = 5;
                                }
                            }
                            Item { Layout.fillWidth: true }
                            Text { text: "Log: " + root.logFile; color: root.textMuted; font.pixelSize: 11; font.family: "monospace"; elide: Text.ElideLeft; Layout.maximumWidth: 520 }
                        }
                    }
                }
                }

                // ---- the start page: install, repair or read the manual -----------------
                Item {
                    visible: root.page === ""
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 20
                    Layout.minimumHeight: 0
                    Layout.preferredHeight: 0

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, 1040)
                        spacing: 26

                        Text {
                            text: "What would you like to do?"
                            color: root.textPrimary
                            font.pixelSize: 26
                            font.weight: Font.DemiBold
                            Layout.alignment: Qt.AlignHCenter
                        }
                        RowLayout {
                            spacing: 20
                            Layout.fillWidth: true
                            Repeater {
                                model: [
                                    { key: "install", glyph: "\u{F02CA}", title: "Install Aequalyn",
                                      about: "Put Aequalyn on this computer: choose a disk, your account and your apps, review everything, then install." },
                                    { key: "repair", glyph: "\u{F05B7}", title: "Repair an installation",
                                      about: "Fix an Aequalyn already on a disk: refresh its keyring, reinstall its kernel or bootloader, or open a shell in it." },
                                    { key: "manual", glyph: "\u{F0219}", title: "Read the manual",
                                      about: "Aequalyn's README from this ISO: what it is, its desktop, its keys and its tools." }
                                ]
                                delegate: Rectangle {
                                    id: card
                                    required property var modelData
                                    readonly property bool primary: modelData.key === "install"
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    implicitHeight: 230
                                    radius: 18
                                    color: cardArea.containsMouse ? root.bgHover : root.bgCard
                                    border.width: 1
                                    border.color: cardArea.containsMouse || card.primary ? root.accent : root.border
                                    scale: cardArea.pressed ? 0.98 : 1
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    Behavior on scale { NumberAnimation { duration: 80 } }
                                    Accessible.role: Accessible.Button
                                    Accessible.name: card.modelData.title

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 22
                                        spacing: 10
                                        Rectangle {
                                            implicitWidth: 52; implicitHeight: 52; radius: 14
                                            color: card.primary ? root.accent : root.bgSelected
                                            Text {
                                                anchors.centerIn: parent
                                                text: card.modelData.glyph
                                                font.family: "JetBrainsMono Nerd Font"
                                                font.pixelSize: 26
                                                color: card.primary ? root.bgBase : root.accent
                                            }
                                        }
                                        Text {
                                            text: card.modelData.title
                                            color: root.textPrimary
                                            font.pixelSize: 18
                                            font.weight: Font.DemiBold
                                            Layout.topMargin: 6
                                        }
                                        Text {
                                            text: card.modelData.about
                                            color: root.textSecondary
                                            font.pixelSize: 13
                                            wrapMode: Text.WordWrap
                                            Layout.fillWidth: true
                                        }
                                        Item { Layout.fillHeight: true }
                                    }
                                    MouseArea {
                                        id: cardArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.page = card.modelData.key
                                    }
                                }
                            }
                        }
                        Text {
                            text: root.isRoot ? "" : "Not running as root: installing and repairing need it (start with sudo aequalyn-install)."
                            visible: text !== ""
                            color: root.warn
                            font.pixelSize: 12
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                // ---- repair: four ways, each run by aequalyn-repair in a terminal ---------
                Item {
                    visible: root.page === "repair"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 20
                    Layout.minimumHeight: 0
                    Layout.preferredHeight: 0
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 16

                    Text {
                        text: "Every repair first asks for the disk Aequalyn is on and its system partition, unlocks it if it is encrypted, and mounts it. Then it does one of these:"
                        color: root.textSecondary
                        font.pixelSize: 13
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    GridLayout {
                        columns: 2
                        rowSpacing: 14
                        columnSpacing: 14
                        Layout.fillWidth: true
                        Repeater {
                            model: [
                                { key: "keyring", glyph: "\u{F0306}", title: "Refresh the Arch Linux keyring",
                                  about: "For updates that fail with \"invalid or corrupted package (PGP signature)\": sets up pacman's keys again and, online, installs the newest keyring." },
                                { key: "kernel", glyph: "\u{F033D}", title: "Reinstall the kernel",
                                  about: "For a system that stops while starting: reinstalls its kernels and rebuilds the boot files. Without internet it uses the kernel on this ISO." },
                                { key: "bootloader", glyph: "\u{F0425}", title: "Reinstall the bootloader",
                                  about: "For a computer that no longer shows Aequalyn when it starts: puts Limine back, with the firmware's boot entry and the menu's entries." },
                                { key: "manual", glyph: "\u{F018D}", title: "Manual",
                                  about: "A root shell inside the installed system (arch-chroot), to fix it yourself. Type exit when you are done." }
                            ]
                            delegate: Rectangle {
                                id: rcard
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                implicitHeight: 128
                                radius: 16
                                color: rArea.containsMouse && root.isRoot ? root.bgHover : root.bgCard
                                border.width: 1
                                border.color: rArea.containsMouse && root.isRoot ? root.accent : root.border
                                opacity: root.isRoot ? 1 : 0.6
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Accessible.role: Accessible.Button
                                Accessible.name: rcard.modelData.title
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 18
                                    spacing: 16
                                    Rectangle {
                                        Layout.alignment: Qt.AlignTop
                                        implicitWidth: 46; implicitHeight: 46; radius: 12
                                        color: root.bgSelected
                                        Text {
                                            anchors.centerIn: parent
                                            text: rcard.modelData.glyph
                                            font.family: "JetBrainsMono Nerd Font"
                                            font.pixelSize: 23
                                            color: root.accent
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignTop
                                        spacing: 6
                                        Text { text: rcard.modelData.title; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                        Text { text: rcard.modelData.about; color: root.textSecondary; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    }
                                }
                                MouseArea {
                                    id: rArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: root.isRoot
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Quickshell.execDetached(["foot", "-T", "Aequalyn repair: " + rcard.modelData.title,
                                            "bash", root.installerDir + "/aequalyn-repair", "--mode", rcard.modelData.key]);
                                        root.statusText = rcard.modelData.title + " opened in a terminal.";
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        text: root.isRoot ? root.statusText : "Repair needs root: start the installer with sudo aequalyn-install."
                        visible: text !== ""
                        color: root.isRoot ? root.textMuted : root.warn
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                    Item { Layout.fillHeight: true }
                }
                }

                // ---- the manual: the README that ships on the ISO --------------------------
                Rectangle {
                    id: manualPage
                    visible: root.page === "manual"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: 20
                    Layout.minimumHeight: 0
                    Layout.preferredHeight: 0
                    radius: 14
                    color: root.bgCard
                    border.width: 1
                    border.color: root.border
                    clip: true

                    // read when the page is first shown, then cut into blocks of a few paragraphs:
                    // the whole README as one text is more than Qt's renderer can draw in one go,
                    // and it crashed as soon as the page was scrolled
                    property string markdown: ""
                    readonly property var blocks: {
                        const out = [];
                        let cur = "", fence = false;
                        // paragraphs; a long list (no blank lines between its items) item by item
                        const parts = [];
                        for (const para of manualPage.markdown.split(/\n\s*\n/)) {
                            if (para.length > 900 && !/^```/m.test(para)) parts.push(...para.split(/\n(?=\s{0,3}(?:[-*+]|\d+\.) )/));
                            else parts.push(para);
                        }
                        for (const para of parts) {
                            // a code block with blank lines in it stays in one piece
                            const ticks = (para.match(/^```/gm) || []).length;
                            cur += (cur === "" ? "" : "\n\n") + para;
                            if (ticks % 2 === 1) fence = !fence;
                            if (!fence && cur.length > 900) { out.push(cur); cur = ""; }
                        }
                        if (cur.trim() !== "") out.push(cur);
                        return out;
                    }
                    FileView {
                        id: manualFile
                        path: root.page === "manual" || manualPage.markdown !== "" ? root.manualPath : ""
                        printErrors: false
                        // pictures are left out (drawn at their own size, wider than the page), and links
                        // show as their words: Qt's Markdown draws links in a fixed dark blue
                        onLoaded: manualPage.markdown = text().replace(/!\[[^\]]*\]\([^)]*\)/g, "")
                            .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
                        onLoadFailed: manualPage.markdown = "The manual (README.md) is not on this system."
                    }
                    ListView {
                        id: manualView
                        anchors.fill: parent
                        anchors.margins: 22
                        clip: true
                        spacing: 10
                        boundsBehavior: Flickable.StopAtBounds
                        model: manualPage.blocks
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                        delegate: Text {
                            required property var modelData
                            width: manualView.width - 14
                            text: modelData
                            textFormat: Text.MarkdownText
                            wrapMode: Text.WordWrap
                            color: root.textPrimary
                            linkColor: root.accent
                            font.pixelSize: 14
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }
                    }
                }

                // ---- the steps, as they were ------------------------------------------------
                Rectangle {
                    visible: root.page === "install"
                    Layout.fillWidth: true
                    height: 116
                    color: root.bgCard
                    Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.border }
                    RowLayout {
                        id: stepRow
                        anchors.fill: parent
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        // as before, but closer together when seven don't fit
                        spacing: Math.max(6, Math.min(48, (width - 7 * 150 - 60) / 7))
                        Repeater {
                            model: root.stepNames
                            delegate: Rectangle {
                                required property int index
                                required property var modelData
                                visible: !(root.imported && index > 0 && index < 5)
                                Layout.preferredWidth: visible ? 150 : 0
                                height: 52
                                radius: 12
                                color: index === root.step ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16) : "transparent"
                                border.color: index === root.step ? root.accent : "transparent"
                                border.width: 1
                                opacity: (!root.locked && (index <= root.maxAllowedStep
                                    // a failed install unlocks the wizard for a retry; the
                                    // Finish page stays reachable for Debug / Retry / Discord
                                    || (index === 6 && root.installFailed))) ? 1.0 : 0.4
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 8
                                    spacing: 8
                                    Rectangle {
                                        width: 20; height: 20; radius: 12
                                        color: index <= root.step ? root.accent : root.bgSurface
                                        border.color: root.border
                                        Text {
                                            anchors.centerIn: parent
                                            text: index < root.step ? "✓" : (index + 1)
                                            color: index <= root.step ? root.bgBase : root.textMuted
                                            font.pixelSize: 10
                                            font.bold: true
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        Text {
                                            text: modelData
                                            color: index === root.step ? root.textPrimary : root.textMuted
                                            font.pixelSize: 12
                                            font.weight: index === root.step ? Font.DemiBold : Font.Normal
                                        }
                                        Text {
                                            text: root.stepDescriptions[index]
                                            color: root.textMuted
                                            font.pixelSize: 9
                                            wrapMode: Text.WordWrap
                                            Layout.fillWidth: true
                                        }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: !root.locked && (index <= root.maxAllowedStep
                                        || (index === 6 && root.installFailed))
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.step = index
                                }
                            }
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: root.isRoot ? "root" : "not root"
                            color: root.isRoot ? root.ok : root.warn
                            font.pixelSize: 10
                        }
                    }
                }

                // footer
                Rectangle {
                    visible: root.page !== ""
                    Layout.fillWidth: true
                    height: 64
                    color: "transparent"
                    Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.border }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 20
                        anchors.rightMargin: 20
                        spacing: 12
                        BigButton {
                            text: "Back"
                            visible: root.page !== ""
                            enabled: !root.locked
                            onClicked: {
                                if (root.page === "install" && root.step > 0) { root.step--; return; }
                                root.statusText = "";
                                root.page = "";
                            }
                        }
                        Text {
                            // why Next is unavailable, said in one line
                            text: root.stepHint
                            visible: root.page === "install" && root.stepHint !== ""
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            color: root.warn
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                        Item { Layout.fillWidth: true; visible: root.page !== "install" || root.stepHint === "" }
                        BigButton {
                            primary: true
                            Layout.preferredWidth: 170
                            text: "Next"
                            visible: root.page === "install" && root.step < 6
                            // a page with missing details can be entered, never passed:
                            // the wizard stops right where the next required input is
                            enabled: root.step < 6 && !root.locked && root.step < root.maxAllowedStep
                            onClicked: { if (root.imported && root.step === 0) root.step = 5; else root.step++; }
                        }
                    }
                }
            }
            }
        }
    }

    // ---- the goodbye splash -------------------------------------------------
    // Reboot Now shows this first: the whole screen says goodbye, then the
    // timer fires the actual reboot. If systemctl cannot reboot, the splash
    // lifts again so the error stays visible in the installer window.
    PanelWindow {
        id: splashWin
        visible: root.showSplash
        // wherever the installer window itself lives
        screen: win.screen
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        aboveWindows: true
        focusable: false

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.bgBase }
                GradientStop { position: 1.0; color: root.bgCard }
            }

            ColumnLayout {
                anchors.centerIn: parent
                // a little above the middle
                anchors.verticalCenterOffset: -Math.round(parent.height * 0.06)
                // sizes from the screen's height, so it looks the same on any screen
                readonly property real unit: parent.height / 1080
                spacing: Math.round(14 * unit)
                opacity: root.showSplash ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }

                // the æ mark alone, large (its shape is 320 x 200)
                Image {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: Math.round(416 * parent.unit)
                    Layout.preferredHeight: Math.round(260 * parent.unit)
                    // room between the mark and the words, which sit lower
                    Layout.bottomMargin: Math.round(72 * parent.unit)
                    source: Qt.resolvedUrl(root.light ? "assets/ae-mark-dark.svg" : "assets/ae-mark.svg")
                    sourceSize.width: Math.round(416 * parent.unit)
                    sourceSize.height: Math.round(260 * parent.unit)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                    Accessible.name: "Aequalyn"

                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Enjoy Your Distro!"
                    color: root.textPrimary
                    font.pixelSize: Math.round(66 * parent.unit)
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Rebooting into your new system..."
                    color: root.textMuted
                    font.pixelSize: Math.round(21 * parent.unit)
                }
            }
        }
    }

    Timer {
        id: splashTimer
        interval: 3500
        repeat: false
        onTriggered: rebootProc.running = true
    }
}

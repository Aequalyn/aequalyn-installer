import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

Scope {
    id: root

    // ---- theme (Aequalyn control-center palette) ----------------------------
    readonly property color bgBase: "#1a1b26"
    readonly property color bgCard: "#24283b"
    readonly property color bgSurface: "#24283b"
    readonly property color bgHover: "#1e2235"
    readonly property color bgSelected: "#283457"
    readonly property color border: "#32364a"
    readonly property color textPrimary: "#c0caf5"
    readonly property color textSecondary: "#a9b1d6"
    readonly property color textMuted: "#565f89"
    readonly property color accent: "#7aa2f7"
    readonly property color ok: "#9ece6a"
    readonly property color warn: "#f7768e"

    property string installerDir: Quickshell.env("AEQUALYN_INSTALLER_DIR") || "/opt/aequalyn/installer"
    property string detectScript: root.installerDir + "/aequalyn-detect"
    property string applyScript: root.installerDir + "/lib/apply.sh"
    property bool isRoot: Quickshell.env("USER") === "root"
    // sudo resets HOME to /root, which the live user's file manager cannot open,
    // so the config always lives in the live user's home.
    property string liveHome: Quickshell.env("AEQUALYN_LIVE_HOME") || "/home/live"
    property string configPath: root.liveHome + "/install.toml"
    // Copy the applier reads. Only synced from configPath right before install.
    property string rootConfigPath: "/root/install.toml"
    property string logFile: root.isRoot ? "/root/aequalyn-install_qml.log" : (Quickshell.env("HOME") + "/aequalyn-install_qml.log")

    // page: 0 splash, 1 install/repair choice, 2..8 install steps (step + 2).
    property int page: 0
    property string flow: "install"
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
    onModeChanged: { if (root.mode !== "dualboot") root.chainloadWindows = false; root.refreshPlan(); }
    onSelectedDiskChanged: root.refreshPlan()
    onEncryptChanged: root.refreshPlan()
    onEfiSizeMbChanged: root.refreshPlan()

    // Preview of what the install does to the disk (lib/plan.sh, read-only).
    property string planScript: root.installerDir + "/lib/plan.sh"
    property var planCur: []
    property var planNotes: []
    property bool planBlocked: false
    property bool planPending: false

    // Typed confirmation: the user must type the target disk's name before any install mode runs.
    property string confirmText: ""
    readonly property string diskShort: root.selectedDisk.replace("/dev/", "")
    readonly property bool confirmed: root.diskShort !== "" && root.confirmText === root.diskShort
    readonly property bool targetHasWindows: !!(root.planCur.some(p => p.fs === "ntfs") ||
        (root.detect.win_efi && root.selectedDisk !== "" && String(root.detect.win_efi).indexOf(root.selectedDisk) === 0))
    readonly property string confirmHeadline: root.mode === "fullwipe" ? "Everything on " + root.selectedDisk + " will be erased." :
        (root.mode === "dualboot" ? "Existing partitions on " + root.selectedDisk + " are kept." :
        "The partitions named in install.toml on " + root.selectedDisk + " will be used.")
    readonly property string confirmDetail: root.mode === "fullwipe" ?
        (root.targetHasWindows ? "Windows is on this disk and will be erased with everything else." : "No Windows partitions were found on this disk.") :
        (root.mode === "dualboot" ?
            "Only the unallocated space is partitioned. Shrink Windows in Disk Management first if there is no free space. " + (root.targetHasWindows ? "Windows was found on this disk." : "No Windows partitions were found on this disk.") :
            "The partitions may be formatted. Check efi_device and root_device in install.toml.")

    property bool profMinimal: true
    property bool profStudent: false
    property bool profDev: false
    property bool profGaming: false
    property bool profCreative: false

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
    property var barLeft: ["appsmenu", "workspaces", "layouts", "network", "atelier"]
    property var barCenter: ["clock", "media", "title", "battery", "volume"]
    property var barRight: ["brightness", "cpu", "bluetooth", "temperature", "caffeine", "tray", "screenrecorder", "screenshot", "power", "settingsbutton", "plume", "altscape"]

    property bool dryRun: false
    property bool writing: false
    property bool applying: false
    property bool locked: false
    property var timezones: []
    property var filteredTimezones: []
    onMaxAllowedStepChanged: { if (root.page >= 2 && root.step > root.maxAllowedStep) root.gotoStep(root.maxAllowedStep); }
    property string geomPath: Quickshell.env("HOME") + "/.config/aequalyn/installer-geometry.conf"
    property bool imported: false
    // configState: -1 unknown, 0 no install.toml at startup, 1 loaded from it,
    // 2 proposal written to it.
    property int configState: -1
    property bool configLoaded: false
    property bool detectDone: false
    readonly property bool busy: root.writing || root.applying || root.repairProbing || root.repairMounting || root.repairRunning || root.repairUnmounting
    readonly property var repairTitles: ["Select disk", "Mount & unlock", "Choose repairs", "Running"]
    readonly property string pageTitle: root.page === 0 ? "Welcome" : (root.page === 1 ? "Get started" : (root.page >= 9 ? "Repair · " + root.repairTitles[root.page - 9] : root.stepNames[root.step]))

    // ---- repair flow state ----
    property string repairScript: root.installerDir + "/lib/repair.sh"
    property string repairDisk: ""
    property string repairRoot: ""
    property string repairEsp: ""
    property bool repairEncrypted: false
    property string repairPass: ""
    property bool repairProbing: false
    property bool repairMounting: false
    property bool repairMounted: false
    property bool repairKeyring: true
    property bool repairKernel: true
    property bool repairBootloader: false
    property var repairPlan: []
    property var repairStates: ({})
    property var repairQueue: []
    property string repairCurrent: ""
    property bool repairRunning: false
    property bool repairUnmounting: false
    property string repairAfter: "quit"
    readonly property bool step0Valid: true
    readonly property bool step1Valid: root.hostname.trim() !== "" && root.username.trim() !== "" && root.timezone.trim() !== "" && root.password !== "" && root.password === root.passwordConfirm
    readonly property bool step2Valid: root.selectedDisk !== "" && !root.planBlocked
    readonly property bool step3Valid: root.profMinimal || root.profStudent || root.profDev || root.profGaming || root.profCreative
    readonly property bool step4Valid: true
    readonly property int maxAllowedStep: root.locked ? 6 : (root.imported ? 5 :
        (!root.step0Valid ? 0 :
        (!root.step1Valid ? 1 :
        (!root.step2Valid ? 2 :
        (!root.step3Valid ? 3 :
        (!root.step4Valid ? 4 : 5))))))
    property string statusText: ""
    property bool installFinished: false
    property bool rebooting: false

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
        const out = [];
        if (root.profMinimal) out.push("minimal");
        if (root.profStudent) out.push("student");
        if (root.profDev) out.push("dev");
        if (root.profGaming) out.push("gaming");
        if (root.profCreative) out.push("creative");
        if (out.length === 0) out.push("minimal");
        return out;
    }

    function applyImport(d, jump) {
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
        root.profMinimal = false; root.profStudent = false; root.profDev = false;
        root.profGaming = false; root.profCreative = false;
        if (Array.isArray(pkgs.profiles)) {
            for (let i = 0; i < pkgs.profiles.length; i++) {
                const pr = pkgs.profiles[i];
                if (pr === "minimal") root.profMinimal = true;
                if (pr === "student") root.profStudent = true;
                if (pr === "dev") root.profDev = true;
                if (pr === "gaming") root.profGaming = true;
                if (pr === "creative") root.profCreative = true;
            }
        }
        if (pkgs && pkgs.browser) root.browser = pkgs.browser;
        if (pkgs) root.flatpak = pkgs.flatpak === true;
        if (pkgs && pkgs.seedWebapps !== undefined) root.seedWebapps = (pkgs.seedWebapps === true);
        if (pkgs && pkgs.editor) root.editor = pkgs.editor;
        const ae = d.aequalyn || {};
        if (ae.theme_mode) root.themeMode = ae.theme_mode;
        root.themeApps = ae.theme_apps !== false;
        root.configLoaded = true;
        if (jump) {
            // Set directly, not through gotoStep: the loaded file is copied
            // verbatim and must not be rewritten from state at the same time.
            root.imported = true;
            root.step = 5;
            root.page = 7;
        }
    }

    function gotoPage(p) {
        root.page = p;
    }

    // Moving between install steps saves the current choices, so install.toml
    // always reflects what the user has reviewed.
    function gotoStep(n) {
        root.step = Math.max(0, Math.min(n, root.maxAllowedStep));
        root.page = 2 + root.step;
        root.saveConfig("save");
    }

    function proceedFromMode() {
        if (root.flow === "install") root.gotoStep(0);
        else root.gotoRepair(9);
    }

    function gotoRepair(p) {
        root.page = p;
    }

    function startProbe() {
        root.repairProbing = true;
        root.repairRoot = "";
        root.repairEsp = "";
        root.repairEncrypted = false;
        root.repairMounted = false;
        root.repairPass = "";
        root.statusText = "";
        repairProbeProc.command = ["bash", root.repairScript, "probe", root.repairDisk];
        repairProbeProc.running = true;
    }

    function startMount() {
        root.statusText = "";
        root.clearLog();
        root.repairMounting = true;
        repairMountProc.command = ["bash", root.repairScript, "mount", root.repairDisk];
        repairMountProc.running = true;
    }

    function startRepairs() {
        const plan = [];
        if (root.repairKeyring) plan.push({ id: "KEYRING", label: "Reinitialize archlinux-keyring" });
        if (root.repairKernel) plan.push({ id: "KERNEL", label: "Reinstall linux kernel" });
        if (root.repairBootloader) plan.push({ id: "BOOTLOADER", label: "Reinstall bootloader", disk: root.repairDisk });
        if (plan.length === 0) { root.statusText = "Select at least one repair."; return; }
        root.statusText = "";
        root.clearLog();
        root.repairPlan = plan;
        root.repairStates = {};
        root.repairQueue = plan.slice();
        root.repairRunning = true;
        root.gotoRepair(12);
        root.repairNextStep();
    }

    function repairNextStep() {
        if (root.repairQueue.length === 0) {
            root.repairRunning = false;
            root.statusText = "Repairs finished. Unmount and reboot when you are ready.";
            return;
        }
        const q = root.repairQueue.slice();
        const item = q.shift();
        root.repairQueue = q;
        root.repairCurrent = item.id;
        const st = Object.assign({}, root.repairStates);
        st[item.id] = "running";
        root.repairStates = st;
        repairRunProc.command = ["bash", root.repairScript, "run", item.id].concat(item.disk ? [item.disk] : []);
        repairRunProc.running = true;
    }

    // Unmounts /mnt, then quits or reboots (repairAfter).
    function quitRepair(after) {
        root.repairAfter = after;
        root.repairUnmounting = true;
        repairUnmountProc.running = true;
    }

    function finishRepairExit() {
        if (root.repairAfter === "reboot") {
            root.rebooting = true;
            root.statusText = "Rebooting...";
            rebootProc.running = true;
        } else {
            Qt.quit();
        }
    }

    function maybeSaveProposal() {
        if (root.configState === 0 && root.detectDone) {
            root.configState = 2;
            root.saveConfig("save");
        }
    }

    function refreshPlan() {
        if (root.selectedDisk === "") { root.planCur = []; root.planNotes = []; root.planBlocked = false; return; }
        if (planProc.running) { root.planPending = true; return; }
        planProc.command = ["bash", root.planScript, root.selectedDisk, root.mode, String(root.efiSizeMb), root.encrypt ? "1" : "0"];
        planProc.running = true;
    }

    function abortApply(msg) {
        root.locked = false;
        root.writing = false;
        root.applying = false;
        root.step = 5;
        root.page = 7;
        root.statusText = msg;
    }

    function saveConfig(reason) {
        if (writeProc.running) return false;
        writeProc.reason = reason;
        writeProc.command = ["bash", "-c", "printf '%s' \"$1\" > \"$2\"", "bash", root.generateToml(), root.configPath];
        root.writing = reason === "apply";
        writeProc.running = true;
        return true;
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
        const s = String(line);
        if (s.length === 0) return;
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
        if (!root.confirmed) {
            root.statusText = "Type " + root.diskShort + " to confirm.";
            return;
        }
        if (writeProc.running) {
            root.statusText = "Still saving install.toml, try again.";
            return;
        }
        root.locked = true;
        root.clearLog();
        root.installFinished = false;
        root.statusText = "Writing configuration...";
        root.step = 6;
        root.page = 8;
        root.saveConfig("apply");
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
                    // Detection may finish after install.toml was loaded;
                    // never overwrite the saved choices in that case.
                    if (!root.configLoaded) {
                        root.mode = root.detect.mode || "fullwipe";
                        root.encrypt = root.detect.encrypt === true;
                        root.selectedDisk = root.detect.first_disk || "";
                        root.chainloadWindows = root.mode === "dualboot" &&
                            root.detect.win_efi !== undefined && root.detect.win_efi !== "";
                        const profs = root.detect.profiles || ["minimal"];
                        root.profMinimal = profs.indexOf("minimal") >= 0;
                        root.profStudent = profs.indexOf("student") >= 0;
                        root.profDev = profs.indexOf("dev") >= 0;
                        root.profGaming = profs.indexOf("gaming") >= 0;
                        root.profCreative = profs.indexOf("creative") >= 0;
                        if (root.detect.browser) root.browser = root.detect.browser;
                        root.flatpak = root.detect.flatpak === true;
                    }
                } catch (e) {
                    root.statusText = "Detection failed: " + e;
                }
                root.detectDone = true;
                root.maybeSaveProposal();
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
        command: ["lsblk", "-dpno", "NAME,SIZE,MODEL"]
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
                    out.push({ name: name, size: parts[1] || "", model: parts.slice(2).join(" "), label: name + "  " + (parts[1] || "") + "  " + parts.slice(2).join(" ") });
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

    // Reads a TOML file into the wizard state. jump=true is the Load button
    // (skip to Review); jump=false is the startup load of install.toml.
    Process {
        id: importProc
        running: false
        property string path: ""
        property bool jump: true
        command: ["python3", "-c", "import tomllib,json,sys; print(json.dumps(tomllib.load(open(sys.argv[1],'rb'))))", importProc.path]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(text || "{}");
                    root.applyImport(d, importProc.jump);
                    root.statusText = importProc.jump ? "Imported " + importProc.path : "";
                    if (importProc.jump && importProc.path !== root.configPath) {
                        copyProc.command = ["cp", "-f", importProc.path, root.configPath];
                        copyProc.running = true;
                    }
                } catch (e) {
                    root.statusText = "Import failed: " + e;
                }
            }
        }
        stderr: StdioCollector { onStreamFinished: { if (text) root.statusText = "Import failed: " + text; } }
        onExited: (code) => { console.log("importProc exited", code, importProc.path); }
    }

    // Startup check: does install.toml already exist in the live home?
    Process {
        id: bootstrapProc
        running: false
        command: ["test", "-f", root.configPath]
        onExited: (code) => {
            if (code === 0) {
                root.configState = 1;
                importProc.jump = false;
                importProc.path = root.configPath;
                importProc.running = true;
            } else {
                root.configState = 0;
                root.maybeSaveProposal();
            }
        }
    }

    Process {
        id: copyProc
        running: false
        command: ["true"]
        stderr: StdioCollector { onStreamFinished: { if (text) root.statusText = "Copy failed: " + text; } }
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
                    importProc.jump = true;
                    importProc.running = true;
                }
            }
        }
    }

    // Writes the current choices to install.toml. reason "save" runs on every
    // wizard navigation; reason "apply" is the Install button and continues
    // into the applier when the write succeeds.
    Process {
        id: writeProc
        running: false
        property string reason: "save"
        // The content is passed as an argument, not on stdin: a tee fed through
        // stdin kept running after the write and blocked every later save.
        command: ["bash", "-c", "printf '%s' \"$1\" > \"$2\"", "bash", "", root.configPath]
        stdout: StdioCollector { onStreamFinished: {} }
        stderr: StdioCollector {
            onStreamFinished: {
                const ls = (text || "").replace(/\n$/, "").split("\n");
                for (let i = 0; i < ls.length; i++) if (ls[i] !== "") root.appendLog(ls[i]);
            }
        }
        onExited: (code) => {
            root.writing = false;
            if (code !== 0) {
                const msg = "Failed to write " + root.configPath + " (exit " + code + ").";
                if (writeProc.reason === "apply") root.abortApply(msg);
                else root.statusText = msg;
                return;
            }
            if (writeProc.reason !== "apply") return;
            root.statusText = "Copying install.toml to " + root.rootConfigPath + "...";
            syncProc.running = true;
        }
    }

    // /home/live/install.toml is the only copy the wizard edits. Right before
    // the applier runs, it is copied over the root copy the applier reads.
    Process {
        id: syncProc
        running: false
        command: ["cp", "-f", root.configPath, root.rootConfigPath]
        stderr: StdioCollector { onStreamFinished: { if (text) root.appendLog(text.trim()); } }
        onExited: (code) => {
            if (code !== 0) {
                root.abortApply("Could not copy install.toml to " + root.rootConfigPath + " (exit " + code + "). The installer must run as root.");
                return;
            }
            if (root.dryRun) {
                root.statusText = "Dry run complete. Config written to " + root.rootConfigPath;
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
        command: ["bash", root.applyScript, root.rootConfigPath, root.password, root.logFile]
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
                root.statusText = "Apply failed (exit " + code + "). See log.";
            }
            logCopyProc.running = true;
        }
    }

    // The install log is copied to the live home after every apply, success or
    // failure, and made world-readable so the live user can open it.
    Process {
        id: logCopyProc
        running: false
        command: ["bash", "-c", "cp -f \"$1\" \"$2\" && chmod 644 \"$2\"", "bash", root.logFile, root.liveHome + "/" + root.logFile.split("/").pop()]
        stderr: StdioCollector { onStreamFinished: { if (text) root.appendLog(text.trim()); } }
        onExited: (code) => {
            const dest = root.liveHome + "/" + root.logFile.split("/").pop();
            root.statusText += code === 0 ? " Copied to " + dest + "." : " Could not copy the log to " + dest + " (exit " + code + ").";
        }
    }

    Process {
        id: planProc
        running: false
        command: ["true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const cur = [];
                const notes = [];
                for (const line of (text || "").split("\n")) {
                    const f = line.split("\t");
                    if (f[0] === "cur") cur.push({ name: f[1], size: f[2], fs: f[3], label: f[4] });
                    else if (f[0] === "plan" || f[0] === "warn" || f[0] === "block") notes.push({ kind: f[0], text: f.slice(1).join("\t") });
                }
                root.planCur = cur;
                root.planNotes = notes;
                root.planBlocked = notes.some(n => n.kind === "block");
            }
        }
        stderr: StdioCollector { onStreamFinished: { if (text) console.log("plan.sh:", text.trim()); } }
        onExited: (code) => {
            if (code !== 0) { root.planBlocked = true; root.planNotes = [{ kind: "block", text: "Could not read the disk layout (exit " + code + ")." }]; }
            if (root.planPending) { root.planPending = false; root.refreshPlan(); }
        }
    }

    // ---- repair flow processes (lib/repair.sh) ----
    Process {
        id: repairProbeProc
        running: false
        command: ["true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text || "";
                root.repairEncrypted = /^ENCRYPTED=1$/m.test(t);
                const r = t.match(/^ROOT=(.*)$/m);
                const e = t.match(/^ESP=(.*)$/m);
                root.repairRoot = r ? r[1].trim() : "";
                root.repairEsp = e ? e[1].trim() : "";
            }
        }
        stderr: StdioCollector { onStreamFinished: { if (text) root.statusText = text.trim(); } }
        onExited: (code) => {
            root.repairProbing = false;
            if (code !== 0 && root.statusText === "") root.statusText = "Could not read " + root.repairDisk + " (exit " + code + ").";
        }
    }

    Process {
        id: repairMountProc
        running: false
        stdinEnabled: true
        command: ["true"]
        // The passphrase travels on stdin, never on the command line.
        onStarted: { write(root.repairPass + "\n"); stdinEnabled = false; root.repairPass = ""; repairPassField.text = ""; }
        stdout: SplitParser { onRead: (line) => root.appendLog(line) }
        stderr: SplitParser { onRead: (line) => root.appendLog(line) }
        onExited: (code) => {
            root.flushLog();
            root.repairMounting = false;
            root.repairMounted = code === 0;
            root.statusText = code === 0 ? "Mounted on /mnt." : "Mount failed (exit " + code + "). See the log.";
        }
    }

    Process {
        id: repairRunProc
        running: false
        command: ["true"]
        stdout: SplitParser { onRead: (line) => root.appendLog(line) }
        stderr: SplitParser { onRead: (line) => root.appendLog(line) }
        onExited: (code) => {
            root.flushLog();
            const st = Object.assign({}, root.repairStates);
            st[root.repairCurrent] = code === 0 ? "done" : "failed";
            root.repairStates = st;
            if (code !== 0) {
                root.repairQueue = [];
                root.repairRunning = false;
                root.statusText = "Step failed (exit " + code + "). See the log; Quit or Unmount & reboot when ready.";
                return;
            }
            root.repairNextStep();
        }
    }

    Process {
        id: repairUnmountProc
        running: false
        command: ["bash", root.repairScript, "unmount"]
        stdout: SplitParser { onRead: (line) => root.appendLog(line) }
        stderr: SplitParser { onRead: (line) => root.appendLog(line) }
        onExited: (code) => {
            root.flushLog();
            root.repairUnmounting = false;
            root.repairMounted = false;
            root.finishRepairExit();
        }
    }

    Process {
        id: rebootProc
        running: false
        command: root.isRoot ? ["systemctl", "reboot"] : ["pkexec", "systemctl", "reboot"]
        onExited: (code) => {
            root.rebooting = false;
            root.statusText = "Reboot failed (exit " + code + "). Reboot manually.";
        }
    }

    Component.onCompleted: {
        root.detecting = true;
        bootstrapProc.running = true;
        detectProc.running = true;
        tzListProc.running = true;
        tzProc.running = true;
        lsblkProc.running = true;
    }

    // ---- UI helpers ---------------------------------------------------------
    component FieldLabel: Text {
        color: root.textMuted
        font.pixelSize: 13
        font.weight: Font.DemiBold
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
            anchors.margins: 8
            clip: true
            model: logModel
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            delegate: Text {
                required property string line
                width: logView.width
                text: line
                color: root.textMuted
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

    component AccentButton: Button {
        implicitHeight: 40
        leftPadding: 18
        rightPadding: 18
        background: Rectangle { color: parent.enabled ? root.accent : root.bgHover; radius: 12 }
        contentItem: Text {
            text: parent.text
            color: parent.enabled ? root.bgBase : root.textMuted
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component GhostButton: Button {
        implicitHeight: 40
        leftPadding: 18
        rightPadding: 18
        background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
        contentItem: Text {
            text: parent.text
            color: parent.enabled ? root.textPrimary : root.textMuted
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Selectable repair option with a checkbox look.
    component RepairCard: Rectangle {
        id: card
        property string title: ""
        property string detail: ""
        property bool checked: false
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: cardCol.implicitHeight + 28
        radius: 12
        color: card.checked ? root.bgSelected : root.bgSurface
        border.color: card.checked ? root.accent : root.border
        border.width: card.checked ? 2 : 1
        opacity: enabled ? 1.0 : 0.5
        RowLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 12
            Rectangle {
                Layout.alignment: Qt.AlignTop
                width: 20; height: 20; radius: 4
                color: card.checked ? root.accent : "transparent"
                border.color: root.accent
                border.width: 2
                Text { anchors.centerIn: parent; visible: card.checked; text: "✓"; color: root.bgBase; font.pixelSize: 13; font.bold: true }
            }
            ColumnLayout {
                id: cardCol
                Layout.fillWidth: true
                spacing: 4
                Text { text: card.title; color: root.textPrimary; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                Text { text: card.detail; color: root.textSecondary; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            }
        }
        MouseArea {
            anchors.fill: parent
            enabled: card.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: card.toggled()
        }
    }

    component TextFieldStyled: TextField {
        enabled: !root.locked
        color: root.textPrimary
        font.pixelSize: 16
        implicitHeight: 44
        Layout.maximumWidth: 560
        background: Rectangle {
            color: root.bgSurface
            radius: 12
            border.color: parent.activeFocus ? root.accent : root.border
            border.width: parent.activeFocus ? 2 : 1
        }
    }

    component ComboBoxStyled: ComboBox {
        enabled: !root.locked
        implicitHeight: 44
        Layout.maximumWidth: 560
        background: Rectangle {
            color: root.bgSurface
            radius: 12
            border.color: parent.activeFocus ? root.accent : root.border
            border.width: 1
        }
        contentItem: Text {
            text: parent.displayText
            color: root.textPrimary
            font.pixelSize: 16
            verticalAlignment: Text.AlignVCenter
            leftPadding: 12
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
            importProc.jump = true;
            importProc.running = true;
        }
    }

    // ---- window geometry persistence ----
    function saveGeom() {
        const geom = "x=" + win.x + "\ny=" + win.y + "\nwidth=" + win.width + "\nheight=" + win.height + "\n";
        saveGeomProc.command = ["bash", "-c", "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\"", "bash", root.geomPath, geom];
        saveGeomProc.running = true;
    }

    Process {
        id: saveGeomProc
        running: false
        command: ["true"]
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
                if (k === "x" && !isNaN(v)) win.x = v;
                if (k === "y" && !isNaN(v)) win.y = v;
                if (k === "width") win.width = v;
                if (k === "height") win.height = v;
            }
        }
    }

    // ---- UI ----
    FloatingWindow {
        id: win
        title: "Aequalyn Installer"
        visible: true
        Component.onDestruction: root.saveGeom()
        color: root.bgBase
        implicitWidth: 800
        implicitHeight: 700
        maximumSize: Qt.size(10000, 10000)
        minimumSize: Qt.size(400, 300)

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#1a1b26" }
                GradientStop { position: 1.0; color: "#24283b" }
            }
            radius: 20
            border.color: root.border
            border.width: 1
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 0
                spacing: 0

                // main
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0

                    // title bar
                    Rectangle {
                        Layout.fillWidth: true
                        height: 68
                        color: "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 20
                            anchors.rightMargin: 18
                            spacing: 8
                            Rectangle {
                                width: 30; height: 30; radius: 9
                                color: root.accent
                                Text { anchors.centerIn: parent; text: "æ"; color: root.bgBase; font.pixelSize: 16; font.bold: true }
                            }
                            ColumnLayout {
                                spacing: 0
                                Text { text: "Aequalyn"; color: root.textPrimary; font.pixelSize: 15; font.weight: Font.DemiBold }
                                Text { text: "Installer"; color: root.textMuted; font.pixelSize: 10 }
                            }
                            Rectangle { width: 1; height: 28; color: root.border }
                            Text {
                                text: root.pageTitle
                                color: root.textPrimary
                                font.pixelSize: 20
                                font.weight: Font.DemiBold
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                visible: root.page >= 2 && root.page <= 8
                                text: (root.step + 1) + " / " + root.stepNames.length
                                color: root.textMuted
                                font.pixelSize: 12
                            }
                            Rectangle {
                                width: 30; height: 30; radius: 9
                                opacity: root.busy ? 0.4 : 1.0
                                color: closeArea.containsMouse && !root.busy ? root.bgHover : "transparent"
                                Text { anchors.centerIn: parent; text: "✕"; color: root.textSecondary; font.pixelSize: 14 }
                                MouseArea {
                                    id: closeArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: root.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    onClicked: { if (!root.busy) Qt.quit(); }
                                }
                            }
                        }
                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 1
                            color: root.border
                        }
                    }

                    // content
                    StackLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        implicitHeight: 0
                        currentIndex: root.page

                        // 0 Splash
                        Item {
                            Image {
                                anchors.fill: parent
                                source: Qt.resolvedUrl("assets/aequalyn-horizon.svg")
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.top
                                anchors.topMargin: Math.max(16, parent.height * 0.06)
                                text: "Welcome to Aequalyn"
                                color: "#142a30"
                                font.pixelSize: 30
                                font.weight: Font.DemiBold
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: Math.max(16, parent.height * 0.1)
                                text: "Your Distro"
                                color: "#dfe5e2"
                                font.pixelSize: 18
                                font.weight: Font.Medium
                            }
                        }

                        // 1 Install or Repair
                        Item {
                            ColumnLayout {
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 48, 560)
                                spacing: 16
                                Text { text: "What would you like to do?"; color: root.textPrimary; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.fillWidth: true }
                                Repeater {
                                    model: [
                                        { id: "install", title: "Install", desc: "Use this wizard to install Aequalyn on your computer." },
                                        { id: "repair", title: "Repair", desc: "Allows you to mount your disk and perform repairs or updates." }
                                    ]
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: choiceCol.implicitHeight + 32
                                        radius: 14
                                        color: root.flow === modelData.id ? root.bgSelected : root.bgSurface
                                        border.color: root.flow === modelData.id ? root.accent : root.border
                                        border.width: root.flow === modelData.id ? 2 : 1
                                        ColumnLayout {
                                            id: choiceCol
                                            anchors.fill: parent
                                            anchors.margins: 16
                                            spacing: 4
                                            Text { text: modelData.title; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                            Text { text: modelData.desc; color: root.textSecondary; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.flow = modelData.id
                                        }
                                    }
                                }
                                Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                            }
                        }

                        // Install step 0: Welcome (hardware)
                        Item {
                            ScrollView {
                                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                anchors.fill: parent
                                anchors.leftMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.rightMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.topMargin: 16
                                anchors.bottomMargin: 16
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text { text: "Hardware detection"; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                    Text { text: root.detecting ? "Detecting your system..." : "Review the proposal below. You can adjust everything later."; color: root.textMuted; font.pixelSize: 13; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        radius: 12
                                        color: root.bgSurface
                                        border.color: root.border
                                        implicitHeight: infoCol.implicitHeight + 20
                                        ColumnLayout {
                                            id: infoCol
                                            anchors.fill: parent
                                            anchors.margins: 10
                                            spacing: 6
                                            Text { text: "What is install.toml?"; color: root.textPrimary; font.pixelSize: 13; font.weight: Font.DemiBold }
                                            Text { text: "install.toml is the single configuration contract for the whole install: identity, disk, packages and Aequalyn defaults. The proposal below is saved to it, every Next updates it with your choices, and the Install step applies exactly what it contains. Re-running with --config install.toml reproduces the same install deterministically."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                            Text { text: "Where is it?"; color: root.textPrimary; font.pixelSize: 13; font.weight: Font.DemiBold }
                                            Text { text: "Saved to: " + root.configPath; color: root.accent; font.pixelSize: 12; font.family: "monospace"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                            Text { text: "You can edit it by hand before applying, or load another file with the field below."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                        }
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        radius: 14
                                        color: root.bgSurface
                                        border.color: root.border
                                        implicitHeight: grid.implicitHeight + 24
                                        GridLayout {
                                            id: grid
                                            anchors.fill: parent
                                            anchors.margins: 12
                                            columns: 2
                                            columnSpacing: 16
                                            rowSpacing: 8
                                            property var rows: [
                                                ["Firmware", (root.detect.firmware || "—")],
                                                ["CPU", (root.detect.cpu_vendor || "—") + "  (" + (root.detect.cpus || "?") + " threads)"],
                                                ["GPU", (root.detect.gpu_vendors || "—")],
                                                ["Memory", (root.detect.mem_gb || "?") + " GiB"],
                                                ["Laptop battery", (root.detect.battery || "—")],
                                                ["Disks", (root.detect.disk_count || 0) + "  (first: " + (root.detect.first_disk || "none") + ")"],
                                                ["Windows EFI", (root.detect.win_efi || "not found")],
                                                ["Proposed profiles", (root.detect.profiles || []).join(", ")],
                                                ["Proposed mode", (root.detect.mode || "—") + "   encrypt: " + (root.detect.encrypt === true)]
                                            ]
                                            Repeater {
                                                model: grid.rows
                                                delegate: RowLayout {
                                                    required property var modelData
                                                    Layout.columnSpan: 2
                                                    Layout.fillWidth: true
                                                    Text { text: modelData[0]; color: root.textMuted; font.pixelSize: 13; Layout.preferredWidth: 150 }
                                                    Text { text: modelData[1]; color: root.textPrimary; font.pixelSize: 13; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                                }
                                            }
                                        }
                                    }

                                    Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12 }
                                    Button {
                                        text: "Re-detect"
                                        enabled: !root.locked
                                        onClicked: { root.detecting = true; detectProc.running = true; lsblkProc.running = true; }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        TextFieldStyled {
                                            id: importPathField
                                            Layout.fillWidth: true
                                            placeholderText: "/path/to/install.toml"
                                        }
                                        Button {
                                            text: "Load"
                                            enabled: !root.locked
                                            onClicked: {
                                                if (importPathField.text.trim() === "") { root.statusText = "Enter a path to install.toml"; return; }
                                                importProc.path = importPathField.text.trim();
                                                importProc.jump = true;
                                                importProc.running = true;
                                            }
                                            background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
                                            contentItem: Text { text: parent.text; color: root.textPrimary; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                        }
                                        Button {
                                            text: "Browse"
                                            enabled: !root.locked
                                            onClicked: zenityProc.running = true
                                            background: Rectangle { color: root.accent; radius: 12 }
                                            contentItem: Text { text: parent.text; color: root.bgBase; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                        }
                                    }
                                    Text { text: root.imported ? "Imported config loaded. Review and apply." : ""; color: root.ok; font.pixelSize: 12 }
                                }
                            }
                        }

                        // 1 Identity
                        Item {
                            ScrollView {
                                ScrollBar.vertical.policy: ScrollBar.AsNeeded
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                anchors.fill: parent
                                anchors.leftMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.rightMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.topMargin: 16
                                anchors.bottomMargin: 16
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text { text: "Set the machine and user identity. Hostname, username, timezone and password are required."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    FieldLabel { text: "HOSTNAME" }
                                    TextFieldStyled { text: root.hostname; Layout.fillWidth: true; onTextChanged: root.hostname = text }
                                    Text { text: "The name of this computer on the network."; color: root.textMuted; font.pixelSize: 11 }
                                    FieldLabel { text: "USERNAME" }
                                    TextFieldStyled { text: root.username; Layout.fillWidth: true; onTextChanged: root.username = text }
                                    Text { text: "Your account name."; color: root.textMuted; font.pixelSize: 11 }
                                    FieldLabel { text: "TIMEZONE" }
                                    TimezoneGlobe {
                                        Layout.fillWidth: true
                                        selectedTimezone: root.timezone
                                        Layout.preferredHeight: 320
                                        onTimezoneSelected: (tz) => root.timezone = tz
                                    }
                                    Text { text: "Selected: " + root.timezone; color: root.textPrimary; font.pixelSize: 12 }
                                    Text { text: "Region/City, e.g. Europe/Bucharest. Scroll the page with the wheel; hold Ctrl and scroll over the globe to zoom."; color: root.textMuted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    Button {
                                        text: "Use system timezone (timedatectl)"
                                        enabled: !root.locked
                                        onClicked: tzProc.running = true
                                        background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
                                        contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                    FieldLabel { text: "CONSOLE KEYMAP" }
                                    TextFieldStyled { text: root.keymap; Layout.fillWidth: true; onTextChanged: root.keymap = text }
                                    Text { text: "Keyboard layout for the console (us, uk, de, ...)."; color: root.textMuted; font.pixelSize: 11 }
                                    FieldLabel { text: "PASSWORD (ALSO ROOT)" }
                                    TextFieldStyled { echoMode: TextInput.Password; text: root.password; Layout.fillWidth: true; onTextChanged: root.password = text }
                                    Text { text: "Used for your account and root; also LUKS if encrypted."; color: root.textMuted; font.pixelSize: 11 }
                                    Text {
                                        text: root.password === "" ? "Password cannot be empty." :
                                              (root.password !== root.passwordConfirm ? "Passwords do not match." : "Password OK")
                                        color: (root.password === "" || root.password !== root.passwordConfirm) ? root.warn : root.ok
                                        font.pixelSize: 11
                                    }
                                    FieldLabel { text: "CONFIRM PASSWORD" }
                                    TextFieldStyled { echoMode: TextInput.Password; text: root.passwordConfirm; Layout.fillWidth: true; onTextChanged: root.passwordConfirm = text }
                                }
                            }
                        }

                        // 2 Disk
                        Item {
                            ScrollView {
                                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                anchors.fill: parent
                                anchors.leftMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.rightMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.topMargin: 16
                                anchors.bottomMargin: 16
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text { text: "Choose the target disk and install mode. Full wipe erases the whole disk; dual boot keeps Windows."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    FieldLabel { text: "TARGET DISK" }
                                    ComboBoxStyled {
                                        Layout.fillWidth: true
                                        model: root.disks
                                        textRole: "label"
                                        currentIndex: {
                                            for (let i = 0; i < root.disks.length; i++) if (root.disks[i].name === root.selectedDisk) return i;
                                            return 0;
                                        }
                                        onActivated: root.selectedDisk = root.disks[currentIndex].name
                                    }
                                    FieldLabel { text: "INSTALL MODE" }
                                    ComboBoxStyled {
                                        Layout.fillWidth: true
                                        model: ["fullwipe", "dualboot", "manual"]
                                        currentIndex: Math.max(0, ["fullwipe","dualboot","manual"].indexOf(root.mode))
                                        onActivated: root.mode = currentText
                                    }
                                    CheckBox {
                                        enabled: !root.locked
                                        text: "Encrypt root with LUKS2"
                                        checked: root.encrypt
                                        onToggled: root.encrypt = checked
                                        contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 }
                                    }
                                    Text { text: "Selected: " + root.selectedDisk; color: root.textMuted; font.pixelSize: 12 }
                                    FieldLabel { text: "EFI PARTITION SIZE (MB)" }
                                    TextFieldStyled {
                                        Layout.fillWidth: true
                                        text: root.efiSizeMb
                                        inputMethodHints: Qt.ImhDigitsOnly
                                        validator: IntValidator { bottom: 300; top: 8192 }
                                        onTextChanged: {
                                            const v = parseInt(text, 10);
                                            if (!isNaN(v) && v >= 300 && v <= 8192) root.efiSizeMb = v;
                                        }
                                    }
                                    Text { text: "2 GiB (2048 MB) recommended: the ESP holds the kernel, initramfs and bootloader, and keeps room for snapshots/firmware updates."; color: root.textMuted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }

                                    // Preview of the disk changes. Read-only; it mirrors apply.sh.
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.topMargin: 8
                                        radius: 12
                                        color: root.bgSurface
                                        border.color: root.planBlocked ? root.warn : root.border
                                        implicitHeight: planCol.implicitHeight + 24
                                        ColumnLayout {
                                            id: planCol
                                            anchors.fill: parent
                                            anchors.margins: 12
                                            spacing: 6
                                            Text { text: "WHAT WILL HAPPEN TO " + root.selectedDisk; color: root.textMuted; font.pixelSize: 11; font.weight: Font.DemiBold; visible: root.selectedDisk !== "" }
                                            Repeater {
                                                model: root.planCur
                                                delegate: Text {
                                                    required property var modelData
                                                    text: "  " + modelData.name.replace("/dev/", "") + "   " + modelData.size + " GiB   " + modelData.fs + "   " + modelData.label
                                                    color: root.textMuted
                                                    font.pixelSize: 11
                                                    font.family: "monospace"
                                                    Layout.fillWidth: true
                                                    wrapMode: Text.WrapAnywhere
                                                }
                                            }
                                            Repeater {
                                                model: root.planNotes
                                                delegate: Text {
                                                    required property var modelData
                                                    text: (modelData.kind === "plan" ? "→ " : (modelData.kind === "warn" ? "! " : "✗ ")) + modelData.text
                                                    color: modelData.kind === "plan" ? root.textPrimary : root.warn
                                                    font.pixelSize: 12
                                                    font.weight: modelData.kind === "block" ? Font.DemiBold : Font.Normal
                                                    wrapMode: Text.WordWrap
                                                    Layout.fillWidth: true
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 3 Packages
                        Item {
                            ScrollView {
                                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                anchors.fill: parent
                                anchors.leftMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.rightMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.topMargin: 16
                                anchors.bottomMargin: 16
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text { text: "Select one or more package profiles plus browser, Flatpak, source and editor."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    FieldLabel { text: "PROFILES" }
                                    Text { text: "Select one or more profiles (at least one required)."; color: root.textMuted; font.pixelSize: 11 }
                                    Text { text: "Minimal: base system. Student: study tools. Dev: development. Gaming: gaming stack. Creative: media apps."; color: root.textMuted; font.pixelSize: 10; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    CheckBox { enabled: !root.locked; text: "Minimal"; checked: root.profMinimal; onToggled: { if (!checked && !(root.profStudent||root.profDev||root.profGaming||root.profCreative)) { checked = true; return; } root.profMinimal = checked; } contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    CheckBox { enabled: !root.locked; text: "Student"; checked: root.profStudent; onToggled: { if (!checked && !(root.profMinimal||root.profDev||root.profGaming||root.profCreative)) { checked = true; return; } root.profStudent = checked; } contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    CheckBox { enabled: !root.locked; text: "Dev"; checked: root.profDev; onToggled: { if (!checked && !(root.profMinimal||root.profStudent||root.profGaming||root.profCreative)) { checked = true; return; } root.profDev = checked; } contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    CheckBox { enabled: !root.locked; text: "Gaming"; checked: root.profGaming; onToggled: { if (!checked && !(root.profMinimal||root.profStudent||root.profDev||root.profCreative)) { checked = true; return; } root.profGaming = checked; } contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    CheckBox { enabled: !root.locked; text: "Creative"; checked: root.profCreative; onToggled: { if (!checked && !(root.profMinimal||root.profStudent||root.profDev||root.profGaming)) { checked = true; return; } root.profCreative = checked; } contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    FieldLabel { text: "BROWSER" }
                                    Text { text: "Default web browser."; color: root.textMuted; font.pixelSize: 11 }
                                    ComboBoxStyled {
                                        Layout.fillWidth: true
                                        model: ["Chromium", "Firefox", "Zen"]
                                        currentIndex: Math.max(0, ["Chromium","Firefox","Zen"].map(x=>x.toLowerCase()).indexOf(root.browser))
                                        onActivated: root.browser = currentText.toLowerCase()
                                    }
                                    CheckBox { enabled: !root.locked; text: "Seed web apps"; checked: root.seedWebapps; onToggled: root.seedWebapps = checked; contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    Text { text: "Adds Reddit, ChatGPT, YouTube, YouTube Music, WhatsApp, Gmail and GitHub, on Super + Shift + D/G/T/Y/H/E/B. The browser chosen above opens them; it can be changed later in Settings."; color: root.textMuted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    CheckBox { enabled: !root.locked; text: "Enable Flatpak"; checked: root.flatpak; onToggled: root.flatpak = checked; contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    CheckBox { enabled: !root.locked; text: "Install SDDM lock screens (~400 MB download, ~600 MB disk)"; checked: root.installLockscreens; onToggled: root.installLockscreens = checked; contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    Text { text: "Optional SDDM login themes (echo, pixie, qylock, ...). If skipped, the Lock Screens page is hidden in Settings."; color: root.textMuted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    Text { text: "Enable Flatpak application support."; color: root.textMuted; font.pixelSize: 11 }
                                    FieldLabel { text: "PACKAGE SOURCE" }
                                    Text { text: "Where packages are installed from."; color: root.textMuted; font.pixelSize: 11 }
                                    ComboBoxStyled {
                                        Layout.fillWidth: true
                                        model: ["Auto", "Offline", "Online"]
                                        currentIndex: Math.max(0, ["Auto","Offline","Online"].map(x=>x.toLowerCase()).indexOf(root.source))
                                        onActivated: root.source = currentText.toLowerCase()
                                    }
                                    FieldLabel { text: "TERMINAL EDITOR" }
                                    Text { text: "Default editor for the terminal."; color: root.textMuted; font.pixelSize: 11 }
                                    ComboBoxStyled {
                                        Layout.fillWidth: true
                                        model: ["Nano", "Vim"]
                                        currentIndex: Math.max(0, ["Nano","Vim"].map(x=>x.toLowerCase()).indexOf(root.editor))
                                        onActivated: root.editor = currentText.toLowerCase()
                                    }
                                }
                            }
                        }

                        // 4 Aequalyn
                        Item {
                            ScrollView {
                                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                anchors.fill: parent
                                anchors.leftMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.rightMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.topMargin: 16
                                anchors.bottomMargin: 16
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text { text: "Pick the default colour mode and whether GTK apps follow the theme."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    FieldLabel { text: "COLOUR MODE" }
                                    ComboBoxStyled {
                                        Layout.fillWidth: true
                                        model: ["Wallpaper", "Theme", "Light"]
                                        currentIndex: Math.max(0, ["Wallpaper","Theme","Light"].map(x=>x.toLowerCase()).indexOf(root.themeMode))
                                        onActivated: root.themeMode = currentText.toLowerCase()
                                    }
                                    CheckBox { enabled: !root.locked; text: "Theme third-party GTK apps"; checked: root.themeApps; onToggled: root.themeApps = checked; contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                    CheckBox { enabled: !root.locked; text: "Dry run (write config, do not install)"; checked: root.dryRun; onToggled: root.dryRun = checked; contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
                                }
                            }
                        }

                        // 5 Review
                        Item {
                            ScrollView {
                                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                anchors.fill: parent
                                anchors.leftMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.rightMargin: Math.max(16, (parent.width - 560) / 2)
                                anchors.topMargin: 16
                                anchors.bottomMargin: 16
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 8
                                    Text { text: "Review install.toml"; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                    Text { text: "Saved to " + root.configPath + ". Install applies exactly this file."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                    TextArea {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 230
                                        text: root.generateToml()
                                        font.family: "monospace"
                                        font.pixelSize: 12
                                        color: root.textPrimary
                                        readOnly: true
                                        background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
                                    }
                                    Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }

                                    ColumnLayout {
                                        visible: root.imported
                                        Layout.fillWidth: true
                                        spacing: 8
                                        FieldLabel { text: "PASSWORD (ALSO ROOT)" }
                                        TextFieldStyled { echoMode: TextInput.Password; text: root.password; Layout.fillWidth: true; onTextChanged: root.password = text }
                                        FieldLabel { text: "CONFIRM PASSWORD" }
                                        TextFieldStyled { echoMode: TextInput.Password; text: root.passwordConfirm; Layout.fillWidth: true; onTextChanged: root.passwordConfirm = text }
                                        Text { text: "Imported configs do not store passwords. Enter one before applying."; color: root.textMuted; font.pixelSize: 11 }
                                    }

                                    // Typed confirmation before anything touches the disk, in every mode.
                                    Rectangle {
                                        Layout.fillWidth: true
                                        radius: 12
                                        color: root.bgSurface
                                        border.color: root.warn
                                        implicitHeight: confirmCol.implicitHeight + 24
                                        ColumnLayout {
                                            id: confirmCol
                                            anchors.fill: parent
                                            anchors.margins: 12
                                            spacing: 6
                                            Text {
                                                text: root.confirmHeadline
                                                color: root.warn
                                                font.pixelSize: 13
                                                font.weight: Font.DemiBold
                                                wrapMode: Text.WordWrap
                                                Layout.fillWidth: true
                                            }
                                            Text {
                                                text: root.confirmDetail
                                                color: root.textSecondary
                                                font.pixelSize: 12
                                                wrapMode: Text.WordWrap
                                                Layout.fillWidth: true
                                            }
                                            FieldLabel { text: "TYPE " + root.diskShort + " TO CONFIRM" }
                                            TextFieldStyled {
                                                Layout.fillWidth: true
                                                placeholderText: root.diskShort
                                                enabled: !(root.writing || root.applying) && !root.locked
                                                onTextChanged: root.confirmText = text
                                            }
                                        }
                                    }

                                    Button {
                                        enabled: !(root.writing || root.applying) && !root.locked && root.confirmed
                                        text: root.writing ? "Writing..." : (root.applying ? "Applying..." : (root.dryRun ? "Write config (dry run)" : "Install"))
                                        onClicked: root.startApply()
                                        background: Rectangle {
                                            color: parent.enabled ? root.accent : root.bgHover
                                            radius: 12
                                        }
                                        contentItem: Text { text: parent.text; color: root.bgBase; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                }
                            }
                        }

                        // 6 Finish
                        Item {
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 8
                                Text { text: "Finish"; color: root.textPrimary; font.pixelSize: 18; font.weight: Font.DemiBold }
                                Text { text: root.statusText; color: root.warn; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                ProgressBar {
                                    Layout.fillWidth: true
                                    implicitHeight: 16
                                    indeterminate: root.writing || root.applying
                                    value: (root.writing || root.applying) ? 0 : 1
                                }
                                LogView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 200
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Button {
                                        text: root.rebooting ? "Rebooting..." : "Reboot now"
                                        enabled: root.installFinished && !root.rebooting
                                        onClicked: {
                                            root.saveGeom();
                                            root.rebooting = true;
                                            root.statusText = "Rebooting...";
                                            rebootProc.running = true;
                                        }
                                        background: Rectangle { color: parent.enabled ? root.accent : root.bgHover; radius: 12 }
                                        contentItem: Text { text: parent.text; color: root.bgBase; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                    Button {
                                        text: "Quit"
                                        enabled: !root.rebooting && !root.busy
                                        onClicked: { root.saveGeom(); Qt.quit(); }
                                        background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border; opacity: parent.enabled ? 1.0 : 0.4 }
                                        contentItem: Text { text: parent.text; color: parent.enabled ? root.textPrimary : root.textMuted; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                    }
                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }

                        // 9 Repair: select disk
                        Item {
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 10
                                Text { text: "Select the disk to repair"; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                Text { text: "Pick the disk that holds your Aequalyn install. The live USB is hidden."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                RowLayout {
                                    Layout.fillWidth: true
                                    Item { Layout.fillWidth: true }
                                    GhostButton { text: "Refresh"; enabled: !root.busy; onClicked: lsblkProc.running = true }
                                }
                                Text { visible: root.disks.length === 0; text: "No disks found."; color: root.warn; font.pixelSize: 12 }
                                Repeater {
                                    model: root.disks
                                    delegate: Rectangle {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        implicitHeight: 56
                                        radius: 12
                                        color: root.repairDisk === modelData.name ? root.bgSelected : root.bgSurface
                                        border.color: root.repairDisk === modelData.name ? root.accent : root.border
                                        border.width: root.repairDisk === modelData.name ? 2 : 1
                                        Text {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 16
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            color: root.textPrimary
                                            font.pixelSize: 13
                                            font.family: "monospace"
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.repairDisk = modelData.name
                                        }
                                    }
                                }
                                Item { Layout.fillHeight: true }
                                RowLayout {
                                    Layout.fillWidth: true
                                    GhostButton { text: "Quit"; enabled: !root.busy; onClicked: root.quitRepair("quit") }
                                    Item { Layout.fillWidth: true }
                                    AccentButton {
                                        text: "Next"
                                        enabled: root.repairDisk !== "" && !root.busy
                                        onClicked: { root.gotoRepair(10); root.startProbe(); }
                                    }
                                }
                            }
                        }

                        // 10 Repair: mount and unlock
                        Item {
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 10
                                Text { text: "Mount the system"; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                Text {
                                    text: "Target: " + root.repairDisk + (root.repairRoot !== "" ? "  →  " + root.repairRoot : "")
                                    color: root.textMuted
                                    font.pixelSize: 12
                                    font.family: "monospace"
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                }
                                Text { visible: root.repairProbing; text: "Reading partitions..."; color: root.textMuted; font.pixelSize: 12 }
                                Text {
                                    visible: !root.repairProbing && root.repairRoot !== ""
                                    text: root.repairEncrypted ? "✓ Encrypted volume detected (LUKS)" : "No encryption detected"
                                    color: root.repairEncrypted ? root.ok : root.textSecondary
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }
                                FieldLabel { visible: root.repairEncrypted; text: "LUKS PASSPHRASE" }
                                TextFieldStyled {
                                    id: repairPassField
                                    visible: root.repairEncrypted
                                    echoMode: TextInput.Password
                                    Layout.fillWidth: true
                                    enabled: !root.busy
                                    onTextChanged: root.repairPass = text
                                }
                                AccentButton {
                                    text: root.repairMounting ? "Mounting..." : (root.repairMounted ? "Mounted" : "Unlock & mount")
                                    enabled: !root.busy && !root.repairMounted && !root.repairProbing && root.repairRoot !== "" && (!root.repairEncrypted || root.repairPass !== "")
                                    onClicked: root.startMount()
                                }
                                Text { visible: root.repairMounted; text: "✓ Mounted on /mnt"; color: root.ok; font.pixelSize: 13; font.weight: Font.DemiBold }
                                LogView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 160
                                }
                                Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                RowLayout {
                                    Layout.fillWidth: true
                                    GhostButton { text: "Back"; enabled: !root.busy; onClicked: root.gotoRepair(9) }
                                    Item { Layout.fillWidth: true }
                                    AccentButton { text: "Next"; enabled: root.repairMounted && !root.busy; onClicked: root.gotoRepair(11) }
                                }
                            }
                        }

                        // 11 Repair: choose repairs
                        Item {
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 10
                                Text { text: "What should be repaired?"; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                Text { text: "Each option runs inside arch-chroot on the mounted system."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                RepairCard {
                                    enabled: !root.busy
                                    title: "a) Reinitialize archlinux-keyring"
                                    detail: "Reset the pacman keyring and refresh archlinux-keyring. Fixes invalid-signature and corrupted-package errors."
                                    checked: root.repairKeyring
                                    onToggled: root.repairKeyring = !root.repairKeyring
                                }
                                RepairCard {
                                    enabled: !root.busy
                                    title: "b) Reinstall linux kernel"
                                    detail: "Reinstall the linux package and rebuild the initramfs with mkinitcpio -P."
                                    checked: root.repairKernel
                                    onToggled: root.repairKernel = !root.repairKernel
                                }
                                RepairCard {
                                    enabled: !root.busy
                                    title: "c) Reinstall bootloader"
                                    detail: "Reinstall Limine to the EFI partition and regenerate limine.conf. Unchecked by default."
                                    checked: root.repairBootloader
                                    onToggled: root.repairBootloader = !root.repairBootloader
                                }
                                Item { Layout.fillHeight: true }
                                Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                RowLayout {
                                    Layout.fillWidth: true
                                    GhostButton { text: "Back"; enabled: !root.busy; onClicked: root.gotoRepair(10) }
                                    Item { Layout.fillWidth: true }
                                    AccentButton {
                                        text: "Run repairs"
                                        enabled: !root.busy && (root.repairKeyring || root.repairKernel || root.repairBootloader)
                                        onClicked: root.startRepairs()
                                    }
                                }
                            }
                        }

                        // 12 Repair: progress and arch-chroot log
                        Item {
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 10
                                Text { text: root.repairRunning ? "Running repairs" : "Repairs finished"; color: root.textPrimary; font.pixelSize: 16; font.weight: Font.DemiBold }
                                ProgressBar {
                                    Layout.fillWidth: true
                                    implicitHeight: 16
                                    indeterminate: root.repairRunning
                                    value: root.repairRunning ? 0 : 1
                                }
                                Repeater {
                                    model: root.repairPlan
                                    delegate: Text {
                                        required property var modelData
                                        readonly property string st: root.repairStates[modelData.id] || "pending"
                                        text: (st === "done" ? "✓ " : (st === "running" ? "◐ " : (st === "failed" ? "✗ " : "○ "))) + modelData.label
                                        color: st === "done" ? root.ok : (st === "failed" ? root.warn : (st === "running" ? root.accent : root.textMuted))
                                        font.pixelSize: 13
                                    }
                                }
                                LogView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    Layout.minimumHeight: 160
                                }
                                Text { text: root.statusText; color: root.warn; visible: root.statusText !== ""; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                RowLayout {
                                    Layout.fillWidth: true
                                    GhostButton { text: "Quit"; enabled: !root.busy; onClicked: root.quitRepair("quit") }
                                    Item { Layout.fillWidth: true }
                                    AccentButton {
                                        text: root.repairUnmounting ? "Unmounting..." : "Unmount & reboot"
                                        enabled: !root.busy
                                        onClicked: root.quitRepair("reboot")
                                    }
                                }
                            }
                        }
                    }

                    // bottom step bar
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.page >= 2 && root.page <= 8
                        height: 116
                        color: root.bgCard
                        Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.border }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 16
                            anchors.rightMargin: 16
                            spacing: 48
                            Repeater {
                                model: root.stepNames
                                delegate: Rectangle {
                                    required property int index
                                    required property var modelData
                                    visible: !(root.imported && index > 0 && index < 5)
                                    Layout.preferredWidth: visible ? 150 : 0
                                    height: 52
                                    radius: 12
                                    color: index === root.step ? Qt.rgba(0.537, 0.706, 0.98, 0.18) : "transparent"
                                    border.color: index === root.step ? root.accent : "transparent"
                                    border.width: 1
                                    opacity: (!root.locked && index <= root.maxAllowedStep) ? 1.0 : 0.4
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
                                        enabled: !root.locked && index <= root.maxAllowedStep
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.gotoStep(index)
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
                        Layout.fillWidth: true
                        visible: root.page <= 7
                        height: 34
                        color: "transparent"
                        Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.border }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            Button {
                                text: root.page <= 1 ? "Quit" : "Back"
                                visible: root.page !== 8
                                enabled: root.page <= 1 ? !root.busy : !root.locked
                                onClicked: {
                                    if (root.page <= 1) Qt.quit();
                                    else if (root.page === 2) root.gotoPage(1);
                                    else root.gotoStep(root.step - 1);
                                }
                                background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
                                contentItem: Text { text: parent.text; color: root.textPrimary; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            }
                            Item { Layout.fillWidth: true }
                            Button {
                                text: "Next"
                                visible: root.page <= 6
                                enabled: root.page <= 1 ? true : (!root.locked && root.step < root.maxAllowedStep)
                                onClicked: {
                                    if (root.page === 0) root.gotoPage(1);
                                    else if (root.page === 1) root.proceedFromMode();
                                    else if (root.imported && root.step === 0) root.gotoStep(5);
                                    else root.gotoStep(root.step + 1);
                                }
                                background: Rectangle { color: root.accent; radius: 12 }
                                contentItem: Text { text: parent.text; color: root.bgBase; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            }
                        }
                    }
                }
            }
        }
    }
}

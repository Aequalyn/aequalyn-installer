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
    property string configPath: root.isRoot ? "/root/install.toml" : (Quickshell.env("HOME") + "/install.toml")
    property string logFile: root.isRoot ? "/root/aequalyn-install_qml.log" : (Quickshell.env("HOME") + "/aequalyn-install_qml.log")

    property int step: 0
    readonly property var stepNames: ["Welcome", "Identity", "Disk", "Packages", "Aequalyn", "Review"]
    readonly property var stepDescriptions: [
        "Hardware proposal and overview",
        "Hostname, user, timezone, password",
        "Target disk, mode, encryption",
        "Profiles, browser, sources",
        "Theme and GTK apps",
        "Review install.toml and apply"
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

    property bool profMinimal: true
    property bool profStudent: false
    property bool profDev: false
    property bool profGaming: false
    property bool profCreative: false

    property string browser: "chromium"
    property bool flatpak: false
    property string source: "auto"
    property string editor: "nano"

    property string themeMode: "wallpaper"
    property bool themeApps: true

    property bool dryRun: false
    property bool writing: false
    property bool applying: false
    property bool locked: false
    property var timezones: []
    property var filteredTimezones: []
    onStepChanged: { if (root.step > root.maxAllowedStep) root.step = root.maxAllowedStep; }
    onMaxAllowedStepChanged: { if (root.step > root.maxAllowedStep) root.step = root.maxAllowedStep; }
    property string geomPath: Quickshell.env("HOME") + "/.config/aequalyn/installer-geometry.conf"
    property bool imported: false
    readonly property bool step0Valid: true
    readonly property bool step1Valid: root.hostname.trim() !== "" && root.username.trim() !== "" && root.timezone.trim() !== "" && root.password !== "" && root.password === root.passwordConfirm
    readonly property bool step2Valid: root.selectedDisk !== ""
    readonly property bool step3Valid: root.profMinimal || root.profStudent || root.profDev || root.profGaming || root.profCreative
    readonly property bool step4Valid: true
    readonly property int maxAllowedStep: root.imported ? 5 :
        (!root.step0Valid ? 0 :
        (!root.step1Valid ? 1 :
        (!root.step2Valid ? 2 :
        (!root.step3Valid ? 3 :
        (!root.step4Valid ? 4 : 5)))))
    property string logText: ""
    property string statusText: ""

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
        if (pkgs.browser) root.browser = pkgs.browser;
        root.flatpak = pkgs.flatpak === true;
        if (pkgs.editor) root.editor = pkgs.editor;
        const ae = d.aequalyn || {};
        if (ae.theme_mode) root.themeMode = ae.theme_mode;
        root.themeApps = ae.theme_apps !== false;
        root.imported = true;
        root.step = 5;
    }

    function generateToml() {
        const profiles = root.selectedProfiles();
        const profileStr = "[" + profiles.map(p => '"' + p + '"').join(", ") + "]";
        const enc = root.encrypt ? "true" : "false";
        const flat = root.flatpak ? "true" : "false";
        const apps = root.themeApps ? "true" : "false";
        const chain = root.detect.win_efi ? "true" : "false";
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
            "efi_size_mb = 512\n" +
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
            'profile = "default"\n';
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
        root.logText = "";
        root.statusText = "Writing configuration...";
        root.writing = true;
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
                    root.mode = root.detect.mode || "fullwipe";
                    root.encrypt = root.detect.encrypt === true;
                    root.selectedDisk = root.detect.first_disk || "";
                    const profs = root.detect.profiles || ["minimal"];
                    root.profMinimal = profs.indexOf("minimal") >= 0;
                    root.profStudent = profs.indexOf("student") >= 0;
                    root.profDev = profs.indexOf("dev") >= 0;
                    root.profGaming = profs.indexOf("gaming") >= 0;
                    root.profCreative = profs.indexOf("creative") >= 0;
                    if (root.detect.browser) root.browser = root.detect.browser;
                    root.flatpak = root.detect.flatpak === true;
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
        onStarted: { write(root.generateToml()); }
        stdout: StdioCollector { onStreamFinished: {} }
        stderr: StdioCollector { onStreamFinished: { if (text) root.logText += text; } }
        onExited: (code) => {
            root.writing = false;
            if (code !== 0) {
                root.statusText = "Failed to write config (exit " + code + ").";
                return;
            }
            if (root.dryRun) {
                root.statusText = "Dry run complete. Config written to " + root.configPath;
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
        environment: ({ "ASSUME_YES": "1", "AEQUALYN_NO_REBOOT": "1" })
        stdout: StdioCollector { onStreamFinished: { root.logText += text; } }
        stderr: StdioCollector { onStreamFinished: { if (text) root.logText += text; } }
        onExited: (code) => {
            root.applying = false;
            if (code === 0) root.statusText = "Installation complete. Log: " + root.logFile;
            else root.statusText = "Apply failed (exit " + code + "). See log.";
        }
    }

    Component.onCompleted: {
        root.detecting = true;
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
            write("x=" + win.x + "\ny=" + win.y + "\nwidth=" + win.width + "\nheight=" + win.height + "\n");
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
                                text: root.stepNames[root.step]
                                color: root.textPrimary
                                font.pixelSize: 20
                                font.weight: Font.DemiBold
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: (root.step + 1) + " / " + root.stepNames.length
                                color: root.textMuted
                                font.pixelSize: 12
                            }
                            Rectangle {
                                width: 30; height: 30; radius: 9
                                color: closeArea.containsMouse ? root.bgHover : "transparent"
                                Text { anchors.centerIn: parent; text: "✕"; color: root.textSecondary; font.pixelSize: 14 }
                                MouseArea {
                                    id: closeArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Qt.quit()
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
                        currentIndex: root.step

                        // 0 Welcome
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
                                            Text { text: "install.toml is the single configuration contract for the whole install: identity, disk, packages and Aequalyn defaults. The wizard writes it, shows it to you for review, and applies it only after you approve. Re-running with --config install.toml reproduces the same install deterministically."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                            Text { text: "Where is it?"; color: root.textPrimary; font.pixelSize: 13; font.weight: Font.DemiBold }
                                            Text { text: "It will be written to: " + root.configPath; color: root.accent; font.pixelSize: 12; font.family: "monospace"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                                            Text { text: "You can edit it by hand before applying, or pass an existing file with aequalyn-install --config FILE."; color: root.textMuted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
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
                                    Text { text: "Region/City, e.g. Europe/Bucharest."; color: root.textMuted; font.pixelSize: 11 }
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
                                    CheckBox { enabled: !root.locked; text: "Enable Flatpak"; checked: root.flatpak; onToggled: root.flatpak = checked; contentItem: Text { text: parent.text; color: root.textPrimary; font.pixelSize: 13; leftPadding: parent.indicator.width + 6 } }
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
                                    Text { text: "Nothing has been written to disk yet. Confirm to apply."; color: root.textMuted; font.pixelSize: 12 }
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

                                    TextArea {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 150
                                        text: root.logText
                                        font.family: "monospace"
                                        font.pixelSize: 11
                                        color: root.textMuted
                                        readOnly: true
                                        visible: root.logText !== ""
                                        background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
                                    }
                                    Button {
                                        enabled: !(root.writing || root.applying) && !root.locked
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
                    }

                    // bottom step bar
                    Rectangle {
                        Layout.fillWidth: true
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
                        Layout.fillWidth: true
                        height: 34
                        color: "transparent"
                        Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; height: 1; color: root.border }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20
                            Button {
                                text: "Back"
                                enabled: root.step > 0 && !root.locked
                                onClicked: root.step--
                                background: Rectangle { color: root.bgSurface; radius: 12; border.color: root.border }
                                contentItem: Text { text: parent.text; color: root.textPrimary; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            }
                            Item { Layout.fillWidth: true }
                            Button {
                                text: "Next"
                                visible: root.step < 5
                                enabled: root.step < 5 && !root.locked && root.step < root.maxAllowedStep
                                onClicked: { if (root.imported && root.step === 0) root.step = 5; else root.step++; }
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

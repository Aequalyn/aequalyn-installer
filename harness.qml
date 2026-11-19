// E2E harness for aequalyn-install --test: drives the REAL Installer.qml
// (same directory, so no import is needed -- shell.qml does the same)
// through Install -> Failure -> Retry -> Success with everything dangerous
// swapped for mocks -- detect/apply point at tests/'s scripts, config/log/
// geometry go to the sandbox -- and asserts the title-bar Close ✕ gate:
// blocked while a run is in flight, re-activated by the outcome. "Install
// is pressed" is installer.startApply(), the exact handler the Install
// button calls. Launched by tests/e2e.sh, which also screenshots every
// phase; the first apply fails, the Retry succeeds, so both outcome legs
// and the blocked state in between are exercised end to end.
import Quickshell
import QtQuick

Scope {
    id: harness
    // tests/ (the mocks) and the scratch dir: e2e.sh exports both, the
    // fallbacks keep a manual `qs -p harness.qml` runnable too
    property string testsDir: Quickshell.env("AEQUALYN_E2E_DIR")
        || Qt.resolvedUrl("tests").toString().replace("file://", "")
    property string sandbox: Quickshell.env("AEQUALYN_E2E_SANDBOX")
        || "/tmp/aequalyn-installer-e2e"
    // mirror of the ✕'s gate: MouseArea enabled: !(writing || applying).
    // The rendering itself is verified by tests/e2e.sh's corner screenshots.
    readonly property bool xBlocked: installer.writing || installer.applying
    property int failures: 0
    property bool midApplySeen: false
    property bool failureSeen: false
    property bool successSeen: false

    function assert(cond, label) {
        if (cond) console.log("[assert] PASS " + label)
        else { failures++; console.log("[assert] FAIL " + label) }
    }

    Installer {
        id: installer
        // sandboxed stand-ins: the real lib/apply.sh must never run here
        detectScript: harness.testsDir + "/mock-detect.sh"
        applyScript: harness.testsDir + "/mock-apply.sh"
        configPath: harness.sandbox + "/install.toml"
        logFile: harness.sandbox + "/apply.log"
        geomPath: harness.sandbox + "/geometry.conf"
        // the wizard state a user would have filled in by Review
        password: "test-password"
        passwordConfirm: "test-password"
        selectedDisk: "/dev/mock-disk"
    }

    // park the wizard where a real user would be: the Review page
    Timer {
        interval: 3000; running: true
        onTriggered: {
            installer.page = "install"
            installer.step = 5
            console.log("[phase] pre-install")
            harness.assert(!harness.xBlocked, "X active before Install is pressed")
            harness.assert(installer.step === 5 && installer.selectedDisk === "/dev/mock-disk",
                "wizard parked on Review with a disk selected")
        }
    }

    // "the Install button is pressed": its onClicked is root.startApply()
    Timer {
        interval: 5000; running: true
        onTriggered: {
            console.log("[phase] install-pressed")
            installer.startApply()
            harness.assert(installer.locked && installer.step === 6,
                "wizard committed to the Finish page")
            harness.assert(harness.xBlocked, "X blocked right after Install is pressed")
        }
    }

    // watch the real process chain: write -> apply -> outcome
    Timer {
        interval: 200; repeat: true; running: true
        onTriggered: {
            // keep Reboot Now / Debug out of reach while the scripted run owns
            // the outcome pages: this run must not reboot the live machine
            if (installer.finishAcknowledged) installer.finishAcknowledged = false
            if (installer.applying && !installer.writing && !harness.midApplySeen) {
                harness.midApplySeen = true
                console.log("[phase] mid-apply")
                harness.assert(harness.xBlocked, "X blocked while the apply runs")
            }
            // run 1 fails: the ✕ must come back and the wizard must unlock
            if (installer.installFailed && !harness.failureSeen) {
                harness.failureSeen = true
                console.log("[phase] failure")
                harness.assert(!harness.xBlocked, "X re-activated on Failure")
                harness.assert(!installer.locked && installer.step === 6,
                    "wizard unlocked for retry, parked on Finish")
                retryTimer.start()
            }
            // run 2 (the Retry) succeeds: the ✕ must come back for good
            if (installer.installFinished && !harness.successSeen) {
                harness.successSeen = true
                console.log("[phase] success")
                harness.assert(!installer.writing && !installer.applying, "apply exited cleanly")
                harness.assert(!harness.xBlocked, "X re-activated on Success")
                summaryTimer.start()
            }
        }
    }

    // mirrors the "Retry install" button's onClicked (finishAcknowledged =
    // false; step = 5) and then Install pressed a second time
    Timer {
        id: retryTimer
        interval: 4000
        onTriggered: {
            console.log("[phase] retry-pressed")
            installer.finishAcknowledged = false
            installer.step = 5
            installer.startApply()
            harness.assert(installer.writing && !installer.installFailed && !installer.installFinished,
                "retry: install state reset, writing again")
            harness.assert(harness.xBlocked, "X blocked again after retry Install")
        }
    }

    Timer {
        id: summaryTimer
        interval: 3500
        onTriggered: {
            console.log("[phase] done")
            console.log("[result] " + (harness.failures === 0 ? "ALL PASS" : harness.failures + " FAILURES"))
            Qt.quit()
        }
    }
}

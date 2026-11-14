pragma ComponentBehavior: Bound

import QtQuick
import "GlobeProjection.js" as Proj

// the globe: gpu shaded sphere (shaders/globe.*.qsb) + a canvas on top for the path,
// pins and place labels per zoom band. plain QtQuick, nothing from the shell.
// data comes in through points, pathPoints and bands, answer bandRequested(band)
Item {
    id: root
    clip: true
    implicitWidth: 400
    implicitHeight: 400

    // view
    property real yaw: 0
    property real pitch: 0.35
    property real zoom: 1
    readonly property real baseRadius: Math.min(width, height) * 0.46
    readonly property real radius: baseRadius * zoom
    readonly property real minZoom: 1
    readonly property real maxZoom: 40

    // data
    property var points: []        // [{lat, lng, name, country, kind: visited|wishlist, date}]
    property var pathPoints: []    // visited points with dates, in order
    property var bands: ({})       // {z0: {lng[], lat[], pop[], name[], cc[]}, ...}
    property bool showPath: true
    property bool showPlaces: true

    // theme
    property color accent: "#d4a35a"
  property color selectedColor: "#9ece6a"
  property string selectedName: ""
    property color wishlistColor: "#cba6f7"
    property color textColor: "#e8dcc8"
    property color bgColor: "#1a1815"

    signal bandRequested(string band)
    signal placeClicked(var place)     // {name, cc, country, lat, lng, kind}

    // internals
    property real _zoomGoal: 1
    property real _yawVel: 0
    property real _pitchVel: 0
    property bool _dragging: false
    property string _hoverText: ""
    property var _hits: []             // screen picks, rebuilt every paint
    readonly property string activeBand: zoom < 1.5 ? "z0" : zoom < 2.6 ? "z1" : zoom < 4.0 ? "z2" : "z3"
    readonly property bool shaderFailed: globe.status === ShaderEffect.Error

    property var _cellIndex: ({})      // band -> {cells: [[rowIdx...]]}
    property var _requested: ({})

    function _mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }
    function _css(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
               + Math.round(c.b * 255) + "," + a + ")"
    }
    // qml colors don't parse css rgba(), only the canvas does
    function _qc(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function _fmtPop(p) {
        return p >= 1e6 ? (p / 1e6).toFixed(1) + "M" : p >= 1000 ? Math.round(p / 1000) + "k" : String(p)
    }

    // public api
    function setZoom(z) {
        _zoomGoal = Math.max(minZoom, Math.min(maxZoom, z))
        zoom = _zoomGoal
    }
    function zoomBy(f) { setZoom(_zoomGoal * f) }

    function focusOn(lat, lng, z) {
        yawAnim.stop(); pitchAnim.stop(); zoomAnim.stop()
        _yawVel = 0; _pitchVel = 0
        var ty = -lng * Math.PI / 180
        var d = ((ty - yaw + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI
        yawAnim.to = yaw + d
        pitchAnim.to = Math.max(-1.5, Math.min(1.5, lat * Math.PI / 180))
        if (z !== undefined) {
            _zoomGoal = Math.max(minZoom, Math.min(maxZoom, z))
            zoomAnim.to = _zoomGoal
            zoomAnim.start()
        }
        yawAnim.start(); pitchAnim.start()
    }

    // center on the middle of your points (or a nice default) and zoom out
    function resetView() {
        var x = 0, y = 0, z = 0, n = 0
        for (var i = 0; i < points.length; i++) {
            var v = Proj.latLngToVec(points[i].lat, points[i].lng)
            x += v.x; y += v.y; z += v.z; n++
        }
        var len = Math.sqrt(x * x + y * y + z * z)
        if (n === 0 || len < 0.05) { focusOn(20, 10, 1); return }
        focusOn(Math.asin(y / len) * 180 / Math.PI, Math.atan2(x, z) * 180 / Math.PI, 1)
    }

    // animations
    NumberAnimation { id: yawAnim;   target: root; property: "yaw";   duration: 550; easing.type: Easing.InOutCubic }
    NumberAnimation { id: pitchAnim; target: root; property: "pitch"; duration: 550; easing.type: Easing.InOutCubic }
    NumberAnimation { id: zoomAnim;  target: root; property: "zoom";  duration: 550; easing.type: Easing.InOutCubic }
    Behavior on zoom { enabled: !zoomAnim.running; NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }

    // background + gpu globe
    Rectangle {
        anchors.fill: parent
        radius: 8
        color: root._mix(root.bgColor, Qt.rgba(0, 0, 0, 1), 0.45)
    }

    // plain disc if the shader can't be used on this backend
    Rectangle {
        visible: root.shaderFailed
        width: root.radius * 2; height: width; radius: width / 2
        x: root.width / 2 - width / 2; y: root.height / 2 - height / 2
        color: root._mix(root.bgColor, root.textColor, 0.12)
        border.width: 1; border.color: root._qc(root.textColor, 0.2)
    }

    Image {
        id: earthImg
        source: Qt.resolvedUrl("assets/earth.png")
        sourceSize: Qt.size(4096, 2048)
        asynchronous: true
        smooth: true
        onStatusChanged: if (status === Image.Ready) earthTex.scheduleUpdate()
    }

    ShaderEffectSource {
        id: earthTex
        sourceItem: earthImg
        hideSource: true
        live: false
        mipmap: true
        smooth: true
        wrapMode: ShaderEffectSource.Repeat
        textureSize: Qt.size(4096, 2048)
    }

    ShaderEffect {
        id: globe
        anchors.fill: parent
        blending: true
        property real yaw: root.yaw
        property real pitch: root.pitch
        property real radius: root.radius
        property vector2d center: Qt.vector2d(width / 2, height / 2)
        property vector2d resolution: Qt.vector2d(Math.max(width, 1), Math.max(height, 1))
        property color oceanColor:  root._mix(root.bgColor, Qt.rgba(0.02, 0.05, 0.09, 1), 0.65)
        property color landColor:   root._mix(root.bgColor, root.textColor, 0.42)
        property color borderColor: root._mix(root.bgColor, root.textColor, 0.75)
        property color gratColor:   root._mix(root.bgColor, root.textColor, 0.45)
        property color atmoColor:   root.accent
        property vector4d strength: Qt.vector4d(0.55, 0.28, 0.85, 0)
        property var earth: earthTex
        vertexShader: Qt.resolvedUrl("shaders/globe.vert.qsb")
        fragmentShader: Qt.resolvedUrl("shaders/globe.frag.qsb")
    }

    // overlay
    Canvas {
        id: overlay
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Threaded

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width, h = height
            if (w <= 0 || h <= 0) return
            var cx = w / 2, cy = h / 2, R = root.radius
            var P = Proj.makeProjector(root.yaw, root.pitch, cx, cy, R)
            var accentCss = root._css(root.accent, 1)
            var bgCss = root._css(root.bgColor, 0.9)
            var hits = []
            var placed = []

            // what is drawn already, in buckets of 32 px, so a new label is only checked
            // against its neighbours
            var BUCKET = 32
            var buckets = {}
            function take(box) {
                placed.push(box)
                for (var by = Math.floor(box[1] / BUCKET); by <= Math.floor(box[3] / BUCKET); by++)
                    for (var bx = Math.floor(box[0] / BUCKET); bx <= Math.floor(box[2] / BUCKET); bx++) {
                        var key = bx * 4096 + by
                        if (buckets[key]) buckets[key].push(box)
                        else buckets[key] = [box]
                    }
            }
            function free(x0, y0, x1, y1) {
                for (var by = Math.floor(y0 / BUCKET); by <= Math.floor(y1 / BUCKET); by++)
                    for (var bx = Math.floor(x0 / BUCKET); bx <= Math.floor(x1 / BUCKET); bx++) {
                        var list = buckets[bx * 4096 + by]
                        if (!list) continue
                        for (var i = 0; i < list.length; i++) {
                            var q = list[i]
                            if (x0 < q[2] && x1 > q[0] && y0 < q[3] && y1 > q[1]) return false
                        }
                    }
                return true
            }
            // labels are drawn by the text items above the canvas, not here: x is where
            // the text starts, y its baseline
            var labels = []
            function label(txt, x, y, alpha, color, bold) {
                labels.push({ t: txt, x: x, y: y, a: alpha, c: color, b: bold === true })
            }

            // 1. the path
            var pp = root.pathPoints
            if (root.showPath && pp && pp.length > 1) {
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                var seenPairs = {}
                for (var i = 1; i < pp.length; i++) {
                    var a = pp[i - 1], b = pp[i]
                    if (a.lat === b.lat && a.lng === b.lng) continue          // same city again: no leg
                    var gc = Proj.greatCircle(a.lat, a.lng, b.lat, b.lng, 3)
                    // route already drawn? bow it sideways so both stay visible
                    var pk = a.lat < b.lat || (a.lat === b.lat && a.lng < b.lng)
                           ? a.lat + "," + a.lng + ">" + b.lat + "," + b.lng
                           : b.lat + "," + b.lng + ">" + a.lat + "," + a.lng
                    var rep = seenPairs[pk] || 0
                    seenPairs[pk] = rep + 1
                    if (rep > 0) {
                        var dl = b.lng - a.lng
                        dl = ((dl + 540) % 360) - 180
                        var kx = Math.cos((a.lat + b.lat) / 2 * Math.PI / 180)
                        var vx = dl * kx, vy = b.lat - a.lat
                        var vl = Math.sqrt(vx * vx + vy * vy) || 1
                        var amp = Math.min(14, 0.12 * vl) * rep
                        var plat = vx / vl, plng = -vy / vl / Math.max(kx, 0.2)
                        for (var bk = 0; bk < gc.length; bk++) {
                            var s = Math.sin(Math.PI * bk / (gc.length - 1))
                            gc[bk].lat += plat * amp * s
                            gc[bk].lng += plng * amp * s
                        }
                    }
                    var t = (i / (pp.length - 1))
                    ctx.strokeStyle = root._css(root.accent, (0.30 + 0.65 * t).toFixed(2))
                    ctx.lineWidth = 1.6
                    ctx.beginPath()
                    var pen = false
                    var midx = 0, midy = 0, dirx = 0, diry = 0, haveMid = false
                    var px = 0, py = 0
                    for (var k = 0; k < gc.length; k++) {
                        var z = P(gc[k].lat, gc[k].lng)
                        if (z > 0.02) {
                            if (pen) ctx.lineTo(P.x, P.y); else { ctx.moveTo(P.x, P.y); pen = true }
                            if (k === Math.floor(gc.length / 2) && k > 0) {
                                midx = P.x; midy = P.y; dirx = P.x - px; diry = P.y - py; haveMid = true
                            }
                            px = P.x; py = P.y
                        } else {
                            pen = false
                        }
                    }
                    ctx.stroke()
                    if (haveMid) {                       // direction chevron
                        var len = Math.sqrt(dirx * dirx + diry * diry)
                        if (len > 0.01) {
                            dirx /= len; diry /= len
                            ctx.fillStyle = root._css(root.accent, (0.45 + 0.5 * t).toFixed(2))
                            ctx.beginPath()
                            ctx.moveTo(midx + dirx * 4.5, midy + diry * 4.5)
                            ctx.lineTo(midx - dirx * 3 - diry * 3, midy - diry * 3 + dirx * 3)
                            ctx.lineTo(midx - dirx * 3 + diry * 3, midy - diry * 3 - dirx * 3)
                            ctx.closePath()
                            ctx.fill()
                        }
                    }
                }
            }

            // 2. your pins (collected first so labels avoid them)
            var pts = root.points || []
            var pins = []
            var order = {}
            for (var oi = 0; oi < pp.length; oi++) {
                var ok = pp[oi].country + "|" + pp[oi].name
                if (!order[ok]) order[ok] = []
                order[ok].push(oi + 1)
            }
            for (var u = 0; u < pts.length; u++) {
                var pz = P(pts[u].lat, pts[u].lng)
                if (pz <= 0.05) continue
                if (P.x < -10 || P.x > w + 10 || P.y < -10 || P.y > h + 10) continue
                pins.push({ x: P.x, y: P.y, z: pz, pt: pts[u] })
                take([P.x - 6, P.y - 6, P.x + 6, P.y + 6])
            }

            // 3. places per zoom band
            var places = []
            if (root.showPlaces) {
                var bandName = root.activeBand
                if (!root._requested[bandName]) {
                    root._requested[bandName] = true
                    root.bandRequested(bandName)
                }
                if (!root._requested.z0) { root._requested.z0 = true; root.bandRequested("z0") }

                // best loaded band at or below the detail we want
                var order3 = ["z3", "z2", "z1", "z0"]
                var use = ""
                for (var bi = order3.indexOf(bandName); bi < 4; bi++)
                    if (root.bands[order3[bi]]) { use = order3[bi]; break }

                if (use) {
                    var band = root.bands[use]
                    var ci = root._cellIndex[use]
                    if (!ci) { ci = Proj.buildCells(band); root._cellIndex[use] = ci }

                    // the places in the cells that can be on screen, busiest first
                    var cand = Proj.visibleRows(ci, root.yaw, root.pitch, cx, cy, R)

                    var maxLabels = Math.min(root.maxLabels - 80, Math.round(16 + 30 * (root.zoom - 1)))
                    var lat = band.lat, lng = band.lng, name = band.name, pop = band.pop, cc = band.cc
                    var shown = 0
                    for (var ri = 0; ri < cand.length && shown < maxLabels; ri++) {
                        var r = cand[ri]
                        var zz = P(lat[r], lng[r])
                        if (zz < 0.12) continue
                        var sx = P.x, sy = P.y
                        if (sx < 4 || sx > w - 4 || sy < 8 || sy > h - 4) continue
                        var tw = name[r].length * 5.6
                        var x0 = sx + 5, y0 = sy - 7
                        if (x0 + tw > w - 2) continue
                        if (!free(x0, y0, x0 + tw + 2, y0 + 12) || !free(sx - 2, sy - 2, sx + 2, sy + 2)) continue
                        take([sx - 2, sy - 7, x0 + tw + 2, y0 + 12])
                        var fade = Math.min(1, (zz - 0.12) / 0.25)
                        var rad = 1.5 + Math.log(Math.max(pop[r], 1000)) / Math.LN10 * 0.28
                        ctx.fillStyle = root._css(root.textColor, (0.75 * fade).toFixed(2))
                        ctx.beginPath(); ctx.arc(sx, sy, rad, 0, 2 * Math.PI); ctx.fill()
                        label(name[r], x0, sy + 3.5, 0.72 * fade, root.textColor, false)
                        places.push({ x: sx, y: sy, name: name[r], cc: cc[r], pop: pop[r],
                                      lat: lat[r], lng: lng[r] })
                        shown++
                    }
                }
            }

            // 4. pins on top
            for (var d = 0; d < pins.length; d++) {
                var pin = pins[d], pt = pin.pt
                var col = (pt.name === root.selectedName) ? root.selectedColor : (pt.kind === "wishlist" ? root.wishlistColor : root.accent)
                var rr = 4 + 1.5 * pin.z
                ctx.beginPath()
                ctx.arc(pin.x, pin.y, rr, 0, 2 * Math.PI)
                ctx.fillStyle = root._css(col, pt.kind === "wishlist" ? 0.85 : 1)
                ctx.fill()
                ctx.lineWidth = 1.5
                ctx.strokeStyle = bgCss
                ctx.stroke()
                if (pt.kind === "wishlist") {            // hollow = not yet
                    ctx.beginPath(); ctx.arc(pin.x, pin.y, rr * 0.4, 0, 2 * Math.PI)
                    ctx.fillStyle = bgCss; ctx.fill()
                }
                if (pin.z > 0.2 && (root.zoom >= 1.25 || pins.length <= 14)) {
                    var ptxt = pt.name + (pt.kind === "visited" && pt.visitCount > 1 ? " ×" + pt.visitCount : "")
                    var lw = ptxt.length * 6.4 + 2
                    var lx = pin.x + rr + 3                       // right of the pin, else left
                    if (!free(lx, pin.y - 8, lx + lw, pin.y + 5)) lx = pin.x - rr - 3 - lw
                    if (free(lx, pin.y - 8, lx + lw, pin.y + 5) && lx > 2 && lx + lw < w - 2) {
                        take([lx, pin.y - 8, lx + lw, pin.y + 5])
                        label(ptxt, lx, pin.y + 4, Math.min(1, pin.z * 1.6), col, true)
                    }
                }
                var n = order[pt.country + "|" + pt.name]
                if (lx !== undefined && pin.z > 0.2 && (root.zoom >= 1.25 || pins.length <= 14)) {
                    hits.push({ x: lx + lw / 2, y: pin.y, kind: pt.kind, name: pt.name, country: pt.country,
                                date: pt.date, visits: pt.visits || [],
                                orders: pt.kind === "visited" ? (n || []) : [],
                                lat: pt.lat, lng: pt.lng })
                }
                hits.push({ x: pin.x, y: pin.y, kind: pt.kind, name: pt.name, country: pt.country,
                            date: pt.date, visits: pt.visits || [],
                            orders: pt.kind === "visited" ? (n || []) : [],
                            lat: pt.lat, lng: pt.lng })
            }
            for (var q = 0; q < places.length; q++)
                hits.push({ x: places[q].x, y: places[q].y, kind: "place", name: places[q].name,
                            cc: places[q].cc, pop: places[q].pop, lat: places[q].lat, lng: places[q].lng })
            root._hits = hits
            root._labels = labels
        }
    }

    // the place and pin names: text items, drawn on the gpu with a halo in the globe's
    // background color. there are always MAX_LABELS of them, the unused ones hidden,
    // so moving the globe only moves them
    readonly property int maxLabels: 640
    property var _labels: []
    FontMetrics { id: labelMetrics; font.pixelSize: 11; font.family: "sans-serif" }
    Item {
        id: labelLayer
        anchors.fill: parent
        Repeater {
            id: labelPool
            model: root.maxLabels
            delegate: Text {
                required property int index
                readonly property var spec: index < root._labels.length ? root._labels[index] : null
                visible: spec !== null
                x: spec ? spec.x : 0
                y: spec ? spec.y - labelMetrics.ascent : 0
                text: spec ? spec.t : ""
                color: spec ? spec.c : "transparent"
                opacity: spec ? spec.a : 0
                font.pixelSize: 11
                font.family: "sans-serif"
                font.bold: spec ? spec.b : false
                style: Text.Outline
                styleColor: root._qc(root.bgColor, 0.9)
                textFormat: Text.PlainText
            }
        }
    }

    // tooltip for one of your pins, long visit lists trimmed to the latest few
    function _pinText(hit) {
        var v = hit.visits || [], o = hit.orders || [], t = ""
        if (o.length) t += "#" + (o.length > 5 ? o.slice(0, 2).join(" #") + " … #" + o[o.length - 1] : o.join(" #")) + "  "
        t += hit.name + " · " + hit.country
        if (v.length === 1) t += " · " + v[0]
        else if (v.length > 1) {
            var keep = v.slice(-4)
            t += " · " + v.length + " visits: " + (v.length > keep.length ? "… " : "") + keep.join(", ")
        }
        if (hit.kind === "wishlist") t += " · wishlist"
        return t
    }

    function _pick(mx, my, maxDist) {
        var best = null, bd = maxDist * maxDist
        for (var i = 0; i < _hits.length; i++) {
            var hh = _hits[i]
            var dx = hh.x - mx, dy = hh.y - my
            var d2 = dx * dx + dy * dy - (hh.kind === "place" ? 0 : 36)   // your pins win ties
            if (d2 <= bd) { bd = d2; best = hh }
        }
        return best
    }

    // repaint triggers
    onYawChanged: overlay.requestPaint()
    onPitchChanged: overlay.requestPaint()
    onZoomChanged: overlay.requestPaint()
    onPointsChanged: overlay.requestPaint()
    onPathPointsChanged: overlay.requestPaint()
    onBandsChanged: { _cellIndex = ({}); overlay.requestPaint() }
    onShowPathChanged: overlay.requestPaint()
    onShowPlacesChanged: overlay.requestPaint()
    onAccentChanged: overlay.requestPaint()
    onSelectedNameChanged: overlay.requestPaint()
    onSelectedColorChanged: overlay.requestPaint()
    onTextColorChanged: overlay.requestPaint()
    onBgColorChanged: overlay.requestPaint()
    onWidthChanged: overlay.requestPaint()
    onHeightChanged: overlay.requestPaint()
    Component.onCompleted: { resetView(); overlay.requestPaint() }

    // gpu textures belong to one window. popping out (or docking back) needs the earth
    // mask rendered again there, or the globe has no land
    onWindowChanged: function(win) {
        if (!win) return
        earthTex.scheduleUpdate()
        overlay.requestPaint()
        refreshTimer.restart()
    }
    Timer {                       // once more after the new window's first frame
        id: refreshTimer
        interval: 150
        onTriggered: { earthTex.scheduleUpdate(); overlay.requestPaint() }
    }

    // tooltip
    TextMetrics {
        id: tipMetrics
        text: root._hoverText
        font.pixelSize: 12
    }
    Rectangle {
        id: tip
        visible: root._hoverText !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        width: tipLabel.width + 16
        height: tipLabel.implicitHeight + 8
        radius: 6
        color: root._qc(root.bgColor, 0.92)
        border.width: 1
        border.color: root._qc(root.textColor, 0.25)
        Text {
            id: tipLabel
            anchors.centerIn: parent
            width: Math.max(40, Math.min(tipMetrics.width + 2, root.width - 120))
            text: root._hoverText
            color: root.textColor
            font.pixelSize: 12
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
        }
    }

    // zoom buttons, one bordered box
    Rectangle {
        id: zoomBox
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        width: 34
        height: 105
        radius: 8
        color: root._qc(root.bgColor, 0.92)
        border.width: 1
        border.color: root._qc(root.textColor, 0.14)
        MouseArea { anchors.fill: parent }          // clicks don't reach the globe
        Column {
            anchors.fill: parent
            Repeater {
                model: [ { t: "+", f: 1.4 }, { t: "\u2212", f: 1 / 1.4 }, { t: "\u2316", f: 0 } ]
                delegate: Item {
                    id: cell
                    required property var modelData
                    required property int index
                    width: zoomBox.width
                    height: zoomBox.height / 3
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 1
                        radius: 6
                        color: zArea.containsMouse ? root._qc(root.textColor, 0.08) : "transparent"
                    }
                    Rectangle {
                        visible: cell.index > 0
                        anchors.top: parent.top
                        width: parent.width
                        height: 1
                        color: root._qc(root.textColor, 0.14)
                    }
                    Text {
                        anchors.centerIn: parent
                        text: cell.modelData.t
                        color: root.textColor
                        font.pixelSize: 16
                        textFormat: Text.PlainText
                    }
                    MouseArea {
                        id: zArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cell.modelData.f === 0 ? root.resetView() : root.zoomBy(cell.modelData.f)
                    }
                }
            }
        }
    }

    Text {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: 8
        text: root.zoom.toFixed(1) + "×"
        color: root._qc(root.textColor, 0.45)
        font.pixelSize: 11
        textFormat: Text.PlainText
    }

    // interaction
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(e) { root.zoomBy(Math.pow(1.0025, e.angleDelta.y)); e.accepted = true }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root._dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property real lastX: 0
        property real lastY: 0
        property real lastT: 0
        property real pressX: 0
        property real pressY: 0
        property real travelled: 0

        onPressed: function(m) {
            yawAnim.stop(); pitchAnim.stop(); zoomAnim.stop()
            root._dragging = true
            root._yawVel = 0; root._pitchVel = 0
            lastX = pressX = m.x; lastY = pressY = m.y; lastT = Date.now(); travelled = 0
        }

        onPositionChanged: function(m) {
            if (!pressed) {
                var hit = root._pick(m.x, m.y, 10)
                if (!hit) root._hoverText = ""
                else if (hit.kind === "place")
                    root._hoverText = hit.name + ", " + hit.cc + " · " + root._fmtPop(hit.pop)
                else
                    root._hoverText = root._pinText(hit)
                return
            }
            var now = Date.now()
            var dt = Math.max(1, now - lastT)
            // dragging moves the surface with the cursor: 1 px ~ 1/radius rad at the center
            var yd = (m.x - lastX) / root.radius * 8.0
            var pd = (m.y - lastY) / root.radius * 8.0
            travelled += Math.abs(m.x - lastX) + Math.abs(m.y - lastY)
            var lim = Math.PI / 2 - 0.02
            root.yaw += yd
            root.pitch = Math.max(-lim, Math.min(lim, root.pitch + pd))
            root._yawVel = yd / dt * 16
            root._pitchVel = pd / dt * 16
            lastX = m.x; lastY = m.y; lastT = now
            root._hoverText = ""
        }

        onReleased: function(m) {
            root._dragging = false
            if (Date.now() - lastT > 80) { root._yawVel = 0; root._pitchVel = 0 }
            if (travelled < 5) {                      // a click, not a drag
                root._yawVel = 0; root._pitchVel = 0
                var hit = root._pick(m.x, m.y, 12)
                if (hit) root.placeClicked({ name: hit.name, cc: hit.cc || "", country: hit.country || "",
                                             lat: hit.lat, lng: hit.lng, kind: hit.kind })
            }
        }
        onExited: root._hoverText = ""
    }

    // inertia
    Timer {
        interval: 16
        running: !root._dragging && (Math.abs(root._yawVel) > 0.00005 || Math.abs(root._pitchVel) > 0.00005)
        repeat: true
        onTriggered: {
            var lim = Math.PI / 2 - 0.02
            root.yaw += root._yawVel
            root.pitch = Math.max(-lim, Math.min(lim, root.pitch + root._pitchVel))
            root._yawVel *= 0.93
            root._pitchVel *= 0.93
        }
    }
}

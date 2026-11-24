.pragma library

// orthographic globe math, same conventions as shaders/globe.frag
// world:  x = cos(lat)*sin(lng), y = sin(lat), z = cos(lat)*cos(lng)
// view:   yaw around Y, then pitch around X, screen center = (lat = pitch, lng = -yaw)
// screen: x right, y up, visible when z > 0

var PI = Math.PI;
var D2R = PI / 180.0;

function latLngToVec(lat, lng) {
    var la = lat * D2R, lo = lng * D2R;
    return { x: Math.cos(la) * Math.sin(lo), y: Math.sin(la), z: Math.cos(la) * Math.cos(lo) };
}

function rotate(v, yaw, pitch) {
    var cy = Math.cos(yaw), sy = Math.sin(yaw);
    var cp = Math.cos(pitch), sp = Math.sin(pitch);
    var x1 = cy * v.x + sy * v.z;
    var z1 = -sy * v.x + cy * v.z;
    return { x: x1, y: cp * v.y - sp * z1, z: sp * v.y + cp * z1 };
}

function project(lat, lng, yaw, pitch, cx, cy, radius) {
    var r = rotate(latLngToVec(lat, lng), yaw, pitch);
    if (r.z <= 0.0) return { visible: false, x: 0, y: 0, scale: 0 };
    return { visible: true, x: cx + r.x * radius, y: cy - r.y * radius, scale: r.z };
}

// projector without allocations for hot loops. p(lat, lng) returns z (> 0 = visible),
// then read p.x / p.y
function makeProjector(yaw, pitch, cx, cy, radius) {
    var cy_ = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
    var f = function(lat, lng) {
        var la = lat * D2R, lo = lng * D2R, cl = Math.cos(la);
        var x = cl * Math.sin(lo), y = Math.sin(la), z = cl * Math.cos(lo);
        var x1 = cy_ * x + sy * z, z1 = -sy * x + cy_ * z;
        var y2 = cp * y - sp * z1, z2 = sp * y + cp * z1;
        f.x = cx + x1 * radius;
        f.y = cy - y2 * radius;
        return z2;
    };
    f.x = 0; f.y = 0;
    return f;
}

// angle (radians) between two lat/lng points
function angleBetween(lat1, lng1, lat2, lng2) {
    var a = latLngToVec(lat1, lng1), b = latLngToVec(lat2, lng2);
    var d = a.x * b.x + a.y * b.y + a.z * b.z;
    return Math.acos(Math.max(-1, Math.min(1, d)));
}

// points on the great circle from A to B (both included), at most maxStepDeg apart
function greatCircle(lat1, lng1, lat2, lng2, maxStepDeg) {
    var a = latLngToVec(lat1, lng1), b = latLngToVec(lat2, lng2);
    var dot = Math.max(-1, Math.min(1, a.x * b.x + a.y * b.y + a.z * b.z));
    var om = Math.acos(dot);
    var n = Math.max(1, Math.min(96, Math.ceil(om / (maxStepDeg * D2R))));
    var out = [];
    var so = Math.sin(om);
    for (var i = 0; i <= n; i++) {
        var t = i / n, k1, k2;
        if (so < 1e-6) { k1 = 1 - t; k2 = t; }
        else { k1 = Math.sin((1 - t) * om) / so; k2 = Math.sin(t * om) / so; }
        var x = k1 * a.x + k2 * b.x, y = k1 * a.y + k2 * b.y, z = k1 * a.z + k2 * b.z;
        out.push({ lat: Math.asin(Math.max(-1, Math.min(1, y))) / D2R, lng: Math.atan2(x, z) / D2R });
    }
    return out;
}

// the places of a band in one degree cells: the rows of cell c are
// rows[start[c] .. start[c + 1]), in the band's order (busiest first)
function buildCells(band) {
    const cols = 360, rowsN = 180, lat = band.lat, lng = band.lng, n = lat.length
    const cellOf = new Int32Array(n), start = new Int32Array(cols * rowsN + 1)
    for (let i = 0; i < n; i++) {
        const iy = Math.max(0, Math.min(rowsN - 1, Math.floor(lat[i] + 90)))
        const ix = Math.max(0, Math.min(cols - 1, Math.floor(lng[i] + 180)))
        cellOf[i] = iy * cols + ix
        start[cellOf[i] + 1]++
    }
    for (let c = 0; c < cols * rowsN; c++) start[c + 1] += start[c]
    const fill = start.slice(0, cols * rowsN), rows = new Int32Array(n)
    for (let i = 0; i < n; i++) rows[fill[cellOf[i]]++] = i
    return { cols: cols, rowsN: rowsN, start: start, rows: rows }
}

// the rows of every cell the view can reach, sorted so the busiest places come first.
// only the cells around the middle of the view are looked at, not the whole world
function visibleRows(ci, yaw, pitch, cx, cy, R) {
    const D = Math.PI / 180
    const hd = Math.sqrt(cx * cx + cy * cy)
    const reach = Math.min(Math.PI / 2, (hd >= R ? Math.PI / 2 : Math.asin(hd / R)) + 0.03)
    const clat = Math.max(-89.9, Math.min(89.9, pitch / D))
    const clng = (((-yaw / D) + 180) % 360 + 360) % 360 - 180
    const cv = latLngToVec(clat, clng)
    const cosLim = Math.cos(Math.min(Math.PI, reach + 0.0124))   // plus half a cell's diagonal
    const deg = reach / D
    const lat0 = Math.max(-90, Math.floor(clat - deg - 1)), lat1 = Math.min(89, Math.floor(clat + deg + 1))
    // near a pole, or zoomed out, every longitude can be in view
    const span = Math.abs(clat) + deg + 1 >= 89 ? 180
               : Math.min(180, Math.asin(Math.min(1, Math.sin(reach) / Math.cos(clat * D))) / D + 2)
    // a cell only gets as many places as could ever be labelled in it at this size
    // on screen: its busiest ones
    const cellPx = R * D
    const perCell = Math.max(2, Math.ceil(cellPx * cellPx / 400) + 1)
    const out = []
    for (let iy = lat0 + 90; iy <= lat1 + 90; iy++) {
        const la = (iy - 90 + 0.5) * D, cl = Math.cos(la), sl = Math.sin(la)
        const first = Math.floor(clng - span), last = Math.floor(clng + span)
        for (let lo = first; lo <= Math.min(last, first + 359); lo++) {
            const ix = ((lo + 180) % 360 + 360) % 360
            const c = iy * ci.cols + ix
            const a = ci.start[c], b = ci.start[c + 1]
            if (a === b) continue
            const lc = (ix - 180 + 0.5) * D
            if (cl * Math.sin(lc) * cv.x + sl * cv.y + cl * Math.cos(lc) * cv.z < cosLim) continue
            for (let k = a; k < Math.min(b, a + perCell); k++) out.push(ci.rows[k])
        }
    }
    out.sort((m, n) => m - n)
    return out
}

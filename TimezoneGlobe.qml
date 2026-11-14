import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root
    property var countries: []
    property var stations: []
    property var points: []
    property string selectedTimezone: ""
    signal timezoneSelected(string tz)

    FileView {
        path: Qt.resolvedUrl("assets/countries.json").toString().replace(/^file:\/\//, "")
        onLoaded: {
            try {
                var c = JSON.parse(text());
                root.countries = Array.isArray(c.features) ? c.features : [];
            } catch (e) { root.countries = []; }
        }
    }

    FileView {
        path: Qt.resolvedUrl("assets/timezone-stations.json").toString().replace(/^file:\/\//, "")
        onLoaded: {
            try {
                var s = JSON.parse(text());
                var pts = [];
                for (var i = 0; i < s.length; i++) {
                    pts.push({
                        lat: s[i].latitude,
                        lng: s[i].longitude,
                        name: s[i].timezone,
                        country: s[i].countryCode,
                        kind: "visited",
                        date: ""
                    });
                }
                root.points = pts;
            } catch (e) { root.points = []; }
        }
    }

    GlobeView {
        id: globe
        anchors.fill: parent
        points: root.points
        pathPoints: []
        bands: ({})
        accent: "#7aa2f7"
        selectedColor: "#9ece6a"
        selectedName: root.selectedTimezone
        textColor: "#c0caf5"
        bgColor: "#1a1b26"
        onPlaceClicked: function(place) {
            if (place && place.name) {
                root.selectedTimezone = place.name;
                root.timezoneSelected(place.name);
            }
        }
    }
}

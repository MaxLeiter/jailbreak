import QtQuick 2.15

Rectangle {
    id: root
    property Item containment
    color: "#16202a"

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 76
        color: "#253241"
        opacity: 0.96
    }

    Text {
        anchors.centerIn: parent
        text: "Xios Plasma"
        color: "white"
        font.pixelSize: Math.max(36, Math.round(Math.min(parent.width, parent.height) / 14))
        font.bold: true
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.verticalCenter
        anchors.topMargin: 52
        text: "KWin + plasmashell first light"
        color: "#b7c7d8"
        font.pixelSize: Math.max(18, Math.round(Math.min(parent.width, parent.height) / 32))
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 8
        color: "#3daee9"
    }
}

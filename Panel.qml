import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar chip + popup panel to tune window corner rounding and blur intensity
// live. Dragging a slider applies the change to the running Hyprland
// session immediately via `hyprctl keyword` (no config write, no reload);
// releasing it persists the setting as a marked block in the user's own
// ~/.config/hypr/looknfeel.lua so it survives restarts, using the same
// atomic, symlink-safe writer other Omarchy plugins use for their own
// config files.
Panel {
  id: root
  moduleName: "charlieras262.omablur"
  ipcTarget: "charlieras262.omablur"

  readonly property string pluginId: "charlieras262.omablur"
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.slice(7)
    if (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.slice(0, u.length - 1)
    return u
  }

  // ---------------------------------------------------------- committed state
  //
  // These reflect Hyprland's actual live config, probed on first open. They
  // only change on slider release / toggle click -- never mid-drag, so nothing
  // downstream (the persisted file) writes on every pixel of a drag.
  property bool loaded: false
  property int rounding: 8
  property bool blurEnabled: true
  property int blurPercent: 50 // 0-100, converted to size/passes below

  // Percentage-to-Hyprland conversion. `size` (blur kernel radius) scales
  // linearly across its full valid range (1-20); `passes` is stepped because
  // each additional pass roughly doubles the GPU cost for a much smaller
  // visual gain past 2-3, so a linear mapping would make the top half of the
  // slider barely distinguishable but noticeably heavier.
  function clampInt(value, min, max, fallback) {
    var n = Math.round(Number(value))
    if (!isFinite(n)) return fallback
    return Math.max(min, Math.min(max, n))
  }
  function blurSizeFor(percent) { return clampInt(1 + (percent / 100) * 19, 1, 20, 8) }
  function blurPassesFor(percent) {
    var p = clampInt(percent, 0, 100, 50)
    if (p < 34) return 1
    if (p < 67) return 2
    return 3
  }
  // Inverse of blurSizeFor, used to seed the slider from Hyprland's current
  // decoration:blur:size on first open.
  function percentForBlurSize(size) {
    return clampInt(((size - 1) / 19) * 100, 0, 100, 50)
  }

  // -------------------------------------------------------------- open/close
  onOpenedChanged: if (opened && !loaded) refresh()

  function refresh() {
    roundingProbe.running = true
    blurEnabledProbe.running = true
    blurSizeProbe.running = true
  }

  Process {
    id: roundingProbe
    command: ["hyprctl", "-j", "getoption", "decoration:rounding"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.rounding = root.clampInt(parsed.int, 0, 20, root.rounding)
        } catch (e) { /* keep previous value */ }
        root.loaded = true
      }
    }
  }

  Process {
    id: blurEnabledProbe
    command: ["hyprctl", "-j", "getoption", "decoration:blur:enabled"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.blurEnabled = !!parsed.int
        } catch (e) { /* keep previous value */ }
      }
    }
  }

  Process {
    id: blurSizeProbe
    command: ["hyprctl", "-j", "getoption", "decoration:blur:size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          var size = root.clampInt(parsed.int, 1, 20, 8)
          root.blurPercent = root.percentForBlurSize(size)
        } catch (e) { /* keep previous value */ }
      }
    }
  }

  // ------------------------------------------------------------- live apply
  //
  // Single in-flight hyprctl process; a request arriving while one is
  // already running just overwrites the queued values (last one wins) and
  // gets picked up on the next exit, instead of piling up processes.
  property bool applyQueued: false
  property int queuedRounding: rounding
  property bool queuedBlurEnabled: blurEnabled
  property int queuedBlurPercent: blurPercent

  function applyLive(r, enabled, percent) {
    queuedRounding = root.clampInt(r, 0, 20, root.rounding)
    queuedBlurEnabled = !!enabled
    queuedBlurPercent = root.clampInt(percent, 0, 100, root.blurPercent)
    if (applyProc.running) { applyQueued = true; return }
    runApply()
  }

  function runApply() {
    applyQueued = false
    var size = blurSizeFor(queuedBlurPercent)
    var passes = blurPassesFor(queuedBlurPercent)
    var batch = "keyword decoration:rounding " + queuedRounding
      + " ; keyword decoration:blur:enabled " + (queuedBlurEnabled ? 1 : 0)
      + " ; keyword decoration:blur:size " + size
      + " ; keyword decoration:blur:passes " + passes
    applyProc.command = ["hyprctl", "--batch", batch]
    applyProc.running = true
  }

  Process {
    id: applyProc
    onExited: if (root.applyQueued) root.runApply()
  }

  // ---------------------------------------------------------------- persist
  //
  // Only called on slider release / toggle click, never mid-drag.
  function luaBlock() {
    var size = blurSizeFor(root.blurPercent)
    var passes = blurPassesFor(root.blurPercent)
    return "hl.config({\n"
      + "  decoration = {\n"
      + "    rounding = " + root.rounding + ",\n"
      + "    blur = {\n"
      + "      enabled = " + (root.blurEnabled ? "true" : "false") + ",\n"
      + "      size = " + size + ",\n"
      + "      passes = " + passes + ",\n"
      + "      new_optimizations = true,\n"
      + "      ignore_opacity = true,\n"
      + "    },\n"
      + "  },\n"
      + "})\n"
  }

  function persistNow() {
    persistProc.command = ["python3", root.pluginDir + "/compat/install-looknfeel.py", root.pluginId, root.luaBlock()]
    persistProc.running = true
  }

  Process { id: persistProc }

  // ------------------------------------------------------------------ input
  function previewRounding(v) { applyLive(v, root.blurEnabled, root.blurPercent) }
  function setRounding(v) {
    root.rounding = root.clampInt(v, 0, 20, root.rounding)
    applyLive(root.rounding, root.blurEnabled, root.blurPercent)
    persistNow()
  }

  function previewBlurPercent(v) { applyLive(root.rounding, root.blurEnabled, v) }
  function setBlurPercent(v) {
    root.blurPercent = root.clampInt(v, 0, 100, root.blurPercent)
    applyLive(root.rounding, root.blurEnabled, root.blurPercent)
    persistNow()
  }

  function toggleBlurEnabled() {
    root.blurEnabled = !root.blurEnabled
    applyLive(root.rounding, root.blurEnabled, root.blurPercent)
    persistNow()
  }

  // --------------------------------------------------------------------- UI
  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "◐"
    tooltipText: "Rounding & Blur"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(18)

        // ---------------------------------------------------------- header
        Text {
          text: "ROUNDING & BLUR"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        // --------------------------------------------------------- rounding
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            Text {
              id: roundingHeader
              text: "CORNER ROUNDING"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item { width: parent.width - roundingHeader.implicitWidth - roundingValue.implicitWidth; height: 1 }
            Text {
              id: roundingValue
              text: Math.round(roundingSlider.dragging ? roundingSlider.liveValue : root.rounding) + "px"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          PanelSlider {
            id: roundingSlider
            bar: root.bar
            width: parent.width
            height: Style.space(20)
            minimum: 0
            maximum: 20
            step: 1
            integer: true
            value: root.rounding
            onMoved: function(v) { root.previewRounding(v) }
            onReleased: function(v) { root.setRounding(v) }
          }
        }

        // ------------------------------------------------------------ blur
        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              id: blurLabel
              text: "BLUR"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Item {
              width: parent.width - blurLabel.implicitWidth - blurSwitch.implicitWidth - parent.spacing * 2
              height: 1
            }
            ToggleSwitch {
              id: blurSwitch
              anchors.verticalCenter: parent.verticalCenter
              checked: root.blurEnabled
              foreground: root.bar.foreground
              onToggled: root.toggleBlurEnabled()
            }
          }

          Row {
            width: parent.width
            visible: root.blurEnabled
            Text {
              id: intensityHeader
              text: "INTENSITY"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item { width: parent.width - intensityHeader.implicitWidth - intensityValue.implicitWidth; height: 1 }
            Text {
              id: intensityValue
              text: Math.round(blurSlider.dragging ? blurSlider.liveValue : root.blurPercent) + "%"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          PanelSlider {
            id: blurSlider
            bar: root.bar
            width: parent.width
            height: Style.space(20)
            visible: root.blurEnabled
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            value: root.blurPercent
            onMoved: function(v) { root.previewBlurPercent(v) }
            onReleased: function(v) { root.setBlurPercent(v) }
          }
        }
      }
    }
  }
}

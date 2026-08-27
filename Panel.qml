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
  //
  // `loaded` only flips true once all three probes have answered, and
  // sliders/switch stay non-interactive until then (see the Column below).
  // Without that gate, touching a control before a slower probe returns
  // would apply/persist a still-default value for whichever field hadn't
  // loaded yet, clobbering its real, already-configured value.
  property bool roundingLoaded: false
  property bool blurEnabledLoaded: false
  property bool blurSizeLoaded: false
  readonly property bool loaded: roundingLoaded && blurEnabledLoaded && blurSizeLoaded

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
        root.roundingLoaded = true
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
          // hyprctl reports this option as a "bool" field, not "int" --
          // unlike every other decoration:* option this plugin reads.
          var parsed = JSON.parse(text)
          root.blurEnabled = parsed.bool !== undefined ? !!parsed.bool : !!parsed.int
        } catch (e) { /* keep previous value */ }
        root.blurEnabledLoaded = true
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
        root.blurSizeLoaded = true
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
    onExited: {
      // Style.cornerRadius already mirrors decoration:rounding for the rest
      // of the shell (every popup panel, and any bar -- like Floating Bar --
      // that defaults its own corners to it); Style.refresh() is its own
      // public re-probe, called only after our keyword call has actually
      // landed so it can't read the pre-change value.
      Style.refresh()
      if (root.applyQueued) root.runApply()
    }
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

  // Custom glyph instead of a font icon: a rounded square with a soft halo
  // behind it, drawn from plain Rectangles (no shader/blur dependency),
  // reading as "rounded corners + blur" at a glance.
  Component {
    id: omablurGlyph
    Item {
      anchors.fill: parent

      // Squircle badge: cream card with a soft dark blob glowing off-center,
      // faked with stacked semi-transparent circles (no blur/effects module
      // dependency) since a real gaussian blur isn't available here.
      Rectangle {
        id: squircle
        anchors.fill: parent
        radius: width * 0.28
        color: "#efe9df"
      }
      Item {
        anchors.fill: squircle
        anchors.margins: 1
        clip: true

        Rectangle {
          width: squircle.width * 0.98
          height: width
          radius: width / 2
          x: squircle.width * 0.06
          y: squircle.height * 0.30
          color: "#1a1a1a"
          opacity: 0.10
        }
        Rectangle {
          width: squircle.width * 0.74
          height: width
          radius: width / 2
          x: squircle.width * 0.15
          y: squircle.height * 0.40
          color: "#1a1a1a"
          opacity: 0.22
        }
        Rectangle {
          width: squircle.width * 0.52
          height: width
          radius: width / 2
          x: squircle.width * 0.22
          y: squircle.height * 0.48
          color: "#1a1a1a"
          opacity: 0.45
        }
        Rectangle {
          width: squircle.width * 0.32
          height: width
          radius: width / 2
          x: squircle.width * 0.30
          y: squircle.height * 0.56
          color: "#141414"
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: omablurGlyph
    opticalSize: Style.bar.iconCanvas * 1.4
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
        // Disabled until every probe answers, so a click that lands before a
        // slower one returns can't apply/persist a still-default value over
        // an already-configured one (see the `loaded` comment above).
        enabled: root.loaded
        opacity: root.loaded ? 1 : 0.45
        Behavior on opacity { NumberAnimation { duration: 120 } }

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

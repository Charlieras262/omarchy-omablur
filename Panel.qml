import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar chip + popup panel to tune window corner rounding and blur intensity
// live. Dragging a slider applies the change to the running Hyprland
// session immediately via `hyprctl eval` (Omarchy's Lua config parser
// doesn't support the older `hyprctl keyword`, so this is required, not
// just faster); no config write, no reload happens for the live preview.
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

  // ------------------------------------------------------------- presets
  //
  // "off" isn't a preset name; it's whatever rounding=0 with blur disabled
  // looks like, and the master switch below is what puts it there. The
  // three real presets are chosen so no combination of the two collides
  // with each other or with that off state, which is what makes detecting
  // the active one from Hyprland's own live values (rather than storing our
  // own separate "which preset" flag) possible in the first place.
  readonly property var presets: ({
    "default": { rounding: 8, blurPercent: 40 },
    "minimum": { rounding: 2, blurPercent: 10 },
    "medium": { rounding: 14, blurPercent: 70 }
  })
  property string activePreset: "default"

  function detectPreset() {
    if (!root.blurEnabled) return "custom"
    for (var name in root.presets) {
      var p = root.presets[name]
      if (root.rounding === p.rounding && root.blurPercent === p.blurPercent) return name
    }
    return "custom"
  }

  function applyPreset(name) {
    if (name === "custom") { root.activePreset = "custom"; return }
    var p = root.presets[name]
    if (!p) return
    root.activePreset = name
    root.rounding = p.rounding
    root.blurPercent = p.blurPercent
    root.blurEnabled = true
    applyLive(root.rounding, true, root.blurPercent)
    persistNow()
  }

  // The master switch flattens everything to rounding=0 / blur off (an
  // easy-to-detect combination none of the presets above produce) without
  // losing whatever was set before -- that's remembered here for the
  // session, in memory only, so switching back on restores it. A fresh
  // panel that opens already in that flattened state (nothing to restore
  // yet) falls back to the "default" preset instead.
  readonly property bool masterEnabled: root.rounding > 0 || root.blurEnabled
  property int savedRounding: 8
  property int savedBlurPercent: 40
  property string savedPreset: "default"

  function toggleMaster() {
    if (root.masterEnabled) {
      root.savedRounding = root.rounding
      root.savedBlurPercent = root.blurPercent
      root.savedPreset = root.activePreset
      root.rounding = 0
      root.blurEnabled = false
      applyLive(0, false, root.blurPercent)
    } else {
      root.rounding = root.savedRounding
      root.blurPercent = root.savedBlurPercent
      root.blurEnabled = true
      root.activePreset = root.savedPreset
      applyLive(root.rounding, true, root.blurPercent)
    }
    persistNow()
  }

  // ------------------------------------------------------- bar transparency
  //
  // Blur only renders behind a surface that isn't fully opaque -- an opaque
  // bar shows none of it no matter how strong decoration:blur is set. Reuse
  // the bar's own existing transparency toggle (the same one its own menu
  // entry calls, persisted the same way) instead of drawing our own
  // translucent surface, so this plays along with whatever that bar already
  // does for transparency -- restoring full opacity is just calling it with
  // false, not a separate "default" concept to keep in sync by hand.
  function setBarTransparent(value) {
    if (!root.bar) return
    var want = !!value
    if ((root.bar.requestedTransparent === true) === want) return
    if (root.bar.shell && typeof root.bar.shell.mutateShellConfig === "function") {
      root.bar.shell.mutateShellConfig(function(config) {
        if (typeof config.bar !== "object" || config.bar === null) config.bar = {}
        config.bar.transparent = want
      })
    } else if (typeof root.bar.setRequestedTransparency === "function") {
      root.bar.setRequestedTransparency(want)
    }
  }
  onBlurEnabledChanged: root.setBarTransparent(root.blurEnabled)

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
  onLoadedChanged: if (loaded) {
    root.activePreset = root.detectPreset()
    root.setBarTransparent(root.blurEnabled)
  }

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
    applyProc.command = ["hyprctl", "eval", root.decorationConfig(queuedRounding, queuedBlurEnabled, size, passes)]
    applyProc.running = true
  }

  Process {
    id: applyProc
    onExited: {
      // Style.cornerRadius already mirrors decoration:rounding for the rest
      // of the shell (every popup panel, and any bar -- like Floating Bar --
      // that defaults its own corners to it); Style.refresh() is its own
      // public re-probe, called only after our eval call has actually
      // landed so it can't read the pre-change value.
      Style.refresh()
      if (root.applyQueued) root.runApply()
    }
  }

  // ---------------------------------------------------------------- persist
  //
  // Only called on slider release / toggle click, never mid-drag.
  // Shared by the live apply (hyprctl eval) and the persisted file (wrapped
  // as-is inside our marked block) so both always describe the same state
  // the same way.
  function decorationConfig(rounding, blurEnabled, size, passes) {
    return "hl.config({\n"
      + "  decoration = {\n"
      + "    rounding = " + rounding + ",\n"
      + "    blur = {\n"
      + "      enabled = " + (blurEnabled ? "true" : "false") + ",\n"
      + "      size = " + size + ",\n"
      + "      passes = " + passes + ",\n"
      + "      new_optimizations = true,\n"
      + "      ignore_opacity = true,\n"
      + "    },\n"
      + "  },\n"
      + "})"
  }

  function luaBlock() {
    var size = blurSizeFor(root.blurPercent)
    var passes = blurPassesFor(root.blurPercent)
    return root.decorationConfig(root.rounding, root.blurEnabled, size, passes) + "\n"
  }

  function persistNow() {
    persistProc.command = ["python3", root.pluginDir + "/compat/install-looknfeel.py", root.pluginId, root.luaBlock()]
    persistProc.running = true
  }

  Process { id: persistProc }

  // ------------------------------------------------------------------ input
  // Both sliders only ever show while activePreset is "custom", which is
  // only reachable with the master switch on -- so blur is always meant to
  // read as "on" here too, same as the three named presets already force it.
  function previewRounding(v) { applyLive(v, true, root.blurPercent) }
  function setRounding(v) {
    root.rounding = root.clampInt(v, 0, 20, root.rounding)
    root.blurEnabled = true
    applyLive(root.rounding, true, root.blurPercent)
    persistNow()
  }

  function previewBlurPercent(v) { applyLive(root.rounding, true, v) }
  function setBlurPercent(v) {
    root.blurPercent = root.clampInt(v, 0, 100, root.blurPercent)
    root.blurEnabled = true
    applyLive(root.rounding, true, root.blurPercent)
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

      // Squircle outline housing a soft blob glowing off-center, faked with
      // stacked semi-transparent circles (no blur/effects module dependency)
      // since a real gaussian blur isn't available here. Monochrome, in the
      // bar's own foreground color, like every other bar icon.
      Rectangle {
        id: squircle
        anchors.centerIn: parent
        width: parent.width * 0.86
        height: parent.height * 0.86
        radius: width * 0.28
        color: button.foreground
        opacity: 0.14
      }
      Item {
        anchors.fill: squircle
        anchors.margins: 1
        clip: true

        Rectangle {
          width: squircle.width * 0.72
          height: width
          radius: width / 2
          x: squircle.width * 0.16
          y: squircle.height * 0.38
          color: button.foreground
          opacity: 0.3
        }
        Rectangle {
          width: squircle.width * 0.5
          height: width
          radius: width / 2
          x: squircle.width * 0.24
          y: squircle.height * 0.46
          color: button.foreground
          opacity: 0.6
        }
        Rectangle {
          width: squircle.width * 0.3
          height: width
          radius: width / 2
          x: squircle.width * 0.32
          y: squircle.height * 0.54
          color: button.foreground
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: omablurGlyph
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

        // ------------------------------------------------------------ hero
        Item {
          width: parent.width
          height: Math.max(heroIconWrap.height, heroTextCol.implicitHeight, heroToggle.implicitHeight)

          Item {
            id: heroIconWrap
            width: Style.space(30)
            height: Style.space(30)
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Loader { anchors.fill: parent; sourceComponent: omablurGlyph }
          }

          Column {
            id: heroTextCol
            anchors.left: heroIconWrap.right
            anchors.leftMargin: Style.space(10)
            anchors.right: heroToggle.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Rounding & Blur"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              text: "WINDOW DECORATIONS"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          ToggleSwitch {
            id: heroToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.masterEnabled
            foreground: root.bar.foreground
            onToggled: root.toggleMaster()
          }
        }

        PanelSeparator { width: parent.width; foreground: root.bar.foreground }

        // --------------------------------------------------------- presets
        Column {
          width: parent.width
          spacing: Style.space(8)
          enabled: root.masterEnabled
          opacity: root.masterEnabled ? 1 : 0.45
          Behavior on opacity { NumberAnimation { duration: 120 } }

          PanelSectionHeader {
            text: "PRESET"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Grid {
            id: presetGrid
            width: parent.width
            columns: 4
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Button {
              text: "Default"
              width: presetGrid.cellWidth
              bordered: true
              active: root.activePreset === "default"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.applyPreset("default")
            }
            Button {
              text: "Minimum"
              width: presetGrid.cellWidth
              bordered: true
              active: root.activePreset === "minimum"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.applyPreset("minimum")
            }
            Button {
              text: "Medium"
              width: presetGrid.cellWidth
              bordered: true
              active: root.activePreset === "medium"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.applyPreset("medium")
            }
            Button {
              text: "Custom"
              width: presetGrid.cellWidth
              bordered: true
              active: root.activePreset === "custom"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.applyPreset("custom")
            }
          }

          // ------------------------------------------------------- custom
          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.activePreset === "custom"

            Item { width: 1; height: Style.space(2) }
            PanelSeparator { width: parent.width; foreground: root.bar.foreground }

            PanelSectionHeader {
              text: "CONFIG"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

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

            Column {
              width: parent.width
              spacing: Style.space(6)

              Row {
                width: parent.width
                Text {
                  id: intensityHeader
                  text: "BLUR INTENSITY"
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
  }
}

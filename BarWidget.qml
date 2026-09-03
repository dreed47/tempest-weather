import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for a WeatherFlow Tempest station. The pill shows the current
// condition glyph and temperature; the popup (Panel.qml, loaded lazily) holds
// the detail view and owns the weather fetch.
//
// Structure mirrors Omarchy's first-party weather widget so the bar's popout
// coordinator, hotkey routing, and popout-switch handoff all behave the same.
BarWidget {
  id: root
  moduleName: "io.github.dreed47.tempest-weather"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function notify() {
    if (!root.bar || !panelLoader.item) return
    var lines = panelLoader.item.statusLines()
    if (!lines || lines.length === 0) return
    var headline = lines.shift()
    var body = lines.join("\n")
    var cmd = "omarchy-notification-send " + root.bar.shellQuote(headline)
    if (body !== "") cmd += " " + root.bar.shellQuote(body)
    var g = panelLoader.item.statusGlyph
    if (g && g !== "") cmd += " -g " + root.bar.shellQuote(g)
    root.bar.run(cmd)
  }

  // Popout contract expected by Bar.findPanelWidget / requestPopout: the
  // bar-widget root must expose open/close/opened and the popout-switch pair.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  visible: panelLoader.item && panelLoader.item.label !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The pill paints a glyph plus a temperature, so it is a text label in a
  // padded slot (like omarchy.clock), not a single icon. Line the bar's
  // open-popup indicator up with that text rather than a fixed icon slot.
  readonly property real openPanelIndicatorWidth: button.labelWidth

  // The plugin's headless alert service (AlertService.qml). It polls faster
  // than the popup and makes a sound on lightning / precip-start, reading its
  // own config from shell.json. Referenced here only so the pill can show a
  // bolt while a lightning alert is live.
  readonly property var alertService: bar && bar.shell ? bar.shell.serviceFor("io.github.dreed47.tempest-weather") : null

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // WidgetButton, not BarIconButton: the pill is "<glyph>  72°", a multi-char
  // text label. BarIconButton is icon-only and clamps itself to a fixed square
  // slot, so the temperature overflows the button box and overlaps the next
  // bar widget in the center section. WidgetButton sizes its width to the
  // label, so implicitWidth above is honest and the bar spaces it correctly.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Flag live alerts on the pill even with the popup closed: a warning
    // triangle (0xf071) for an active NWS alert, a bolt (0xf0e7 nf-fa-bolt)
    // for a recent lightning strike.
    text: (root.alertService && root.alertService.nwsActive
        ? String.fromCharCode(0xf071) + "  " : "")
      + (root.alertService && root.alertService.lightningActive
        ? String.fromCharCode(0xf0e7) + "  " : "")
      + (panelLoader.item ? panelLoader.item.label : "")
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : ""

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.notify()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}

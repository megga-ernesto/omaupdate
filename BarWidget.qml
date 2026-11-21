import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "elmegga.omaupdate"
    property bool opened: false
    property bool showingSettings: false
    readonly property bool glassFinish: setting("glassFinish", false) === true
    readonly property bool blurBackdrop: setting("blurBackdrop", false) === true
    readonly property bool wantsBackdropBlur: opened && glassFinish && blurBackdrop
    property bool backdropBlurFailed: false
    property string notice: "intro"
    property var results: []
    property bool scanning: false
    property double lastScan: 0
    property var sourceExpansion: ({})
    readonly property real cardRadius: Style.space(20)
    readonly property real controlRadius: Style.space(14)
    readonly property var orderedResults: results.slice().sort((a, b) => Number(!!b.important) - Number(!!a.important) || sourceRank(a) - sourceRank(b))

    function sourceRank(row) {
        if (row.count > 0 && row.group !== "")
            return 0;
        if (row.status === "error")
            return 1;
        return row.status === "current" ? 2 : 3;
    }
    readonly property var scanChoices: [
        {
            value: "0",
            label: strings.t("manualScan")
        },
        {
            value: "30",
            label: strings.t("halfHourScan")
        },
        {
            value: "60",
            label: strings.t("hourlyScan")
        },
        {
            value: "360",
            label: strings.t("sixHourScan")
        },
        {
            value: "720",
            label: strings.t("twelveHourScan")
        },
        {
            value: "1440",
            label: strings.t("dailyScan")
        }
    ]
    readonly property string scanFrequency: {
        const configured = String(setting("scanMinutes", 30));
        return scanChoices.some(choice => choice.value === configured) ? configured : "30";
    }
    readonly property int updateCount: results.reduce((total, row) => total + (row.group !== "" ? row.count : 0), 0)
    readonly property string countLabel: results.some(row => row.group !== "" && row.status !== "error") ? I18n.formatNumber(updateCount) : "–"
    readonly property bool hasImportantUpdates: results.some(row => row.important)
    readonly property int alertLevel: severity(updateCount, hasImportantUpdates)

    function severity(count, important) {
        if (important || count >= 20)
            return 3;
        if (count >= 6)
            return 2;
        return count > 0 ? 1 : 0;
    }

    function alertColor(level, background, foreground) {
        if (level === 0)
            return foreground;
        const light = 0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b > 0.53;
        const colors = light ? ["#795500", "#984517", "#bb1730"] : ["#dec374", "#ee9d6f", "#ff5267"];
        return colors[level - 1];
    }

    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("updates.py").toString().replace(/^file:\/\//, ""))

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function open() {
        if (!opened) {
            sourceExpansion = {};
            showingSettings = false;
        }
        opened = true;
    }
    function close() {
        opened = false;
    }

    function peers() {
        const widgets = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [];
        return widgets.length ? widgets : [root];
    }

    function changeFrequency(value) {
        if (value === scanFrequency || !scanChoices.some(choice => choice.value === value))
            return;
        saveSetting("scanMinutes", Number(value));
    }

    function saveSetting(key, value) {
        const entry = Object.assign({}, settings, {
            id: moduleName,
            [key]: value
        });
        if (bar && bar.shell && bar.shell.updateEntryInline(moduleName, entry)) {
            settings = entry;
        }
    }

    function finishScan(rows, nextNotice) {
        for (const widget of peers()) {
            if (rows !== null) {
                widget.results = rows;
                widget.lastScan = Date.now();
            }
            widget.notice = nextNotice;
            widget.scanning = false;
        }
    }

    function check(afterInstall = false) {
        const widgets = peers();
        if (widgets.some(widget => widget.scanning) || (launcher.running && !afterInstall))
            return;
        for (const widget of widgets) {
            widget.scanning = true;
            widget.notice = "searching";
        }
        scanner.running = true;
    }

    function launch(action, manager = "") {
        if (launcher.running)
            return;
        const args = ["omarchy", "launch", "tui", "--app-id=TUI.float", "python3", helper, action, "--hold"];
        if (manager)
            args.push("--manager", manager);
        close();
        if (action === "apply") {
            // Omarchy restarts the shell mid-update. Keep the terminal independent.
            Quickshell.execDetached(args);
        } else {
            launcher.argv = args;
            launcher.running = true;
        }
    }

    Translations {
        id: strings
        directory: Qt.resolvedUrl("i18n")
    }

    component RoundedButton: Button {
        radius: root.controlRadius
    }

    component PanelText: Text {
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
    }

    component VersionLabel: Item {
        id: version
        required property var parts
        required property color mutedColor
        required property color highlightColor
        readonly property string value: parts.join("") || "—"
        implicitWidth: segments.implicitWidth
        implicitHeight: fallback.implicitHeight

        Row {
            id: segments
            anchors.verticalCenter: parent.verticalCenter
            visible: implicitWidth <= version.width

            Repeater {
                model: version.parts.join("") ? version.parts : ["—"]
                PanelText {
                    required property string modelData
                    required property int index
                    text: modelData
                    font.pixelSize: Style.font.caption
                    color: index === 1 ? version.highlightColor : version.mutedColor
                    font.bold: index === 1 && modelData !== ""
                    wrapMode: Text.NoWrap
                }
            }
        }

        PanelText {
            id: fallback
            anchors.fill: parent
            visible: !segments.visible
            text: version.value
            wrapMode: Text.NoWrap
            elide: Text.ElideMiddle
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: Style.font.caption
            color: version.parts[1] ? version.highlightColor : version.mutedColor
            font.bold: version.parts[1] !== ""
        }
    }

    ShellIpc {
        target: "elmegga.omaupdate"
        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
        function check(): void {
            root.check();
        }
        function rescanInstalled(): void {
            root.check(true);
        }
    }

    Timer {
        interval: Math.max(1, Number(root.scanFrequency)) * 60000
        running: root.scanFrequency !== "0"
        repeat: true
        triggeredOnStart: true
        onTriggered: if (root.peers()[0] === root && !launcher.running)
            root.check()
    }

    Process {
        id: scanner
        command: ["python3", root.helper, "scan"]
        stdout: StdioCollector {
            id: scanOutput
            waitForEnd: true
        }
        onExited: function (exitCode) {
            try {
                const rows = exitCode === 0 ? JSON.parse(scanOutput.text) : null;
                root.finishScan(Array.isArray(rows) ? rows : null, Array.isArray(rows) ? "" : "scanError");
            } catch (error) {
                root.finishScan(null, "scanError");
            }
        }
    }

    Process {
        command: ["python3", "-B", decodeURIComponent(String(Qt.resolvedUrl("backdrop-blur.py")).slice(7))]
        running: root.wantsBackdropBlur
        onStarted: root.backdropBlurFailed = false
        onExited: function (code) {
            root.backdropBlurFailed = root.wantsBackdropBlur && code !== 0;
        }
    }

    Process {
        id: launcher
        property var argv: []
        command: argv
        onExited: function (exitCode) {
            if (exitCode !== 0) {
                root.notice = "installError";
                root.open();
            }
        }
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "\uf021"
        labelVisible: false
        readonly property real markSize: Math.min(Style.space(14), Math.max(1, root.barSize - 2 * Style.space(3)))
        fontSize: markSize
        Accessible.name: strings.t("title")
        fixedWidth: root.vertical ? -1 : mark.implicitWidth + Style.space(8)
        fixedHeight: root.vertical ? mark.implicitHeight + Style.space(6) : -1
        tooltipText: strings.t(root.hasImportantUpdates ? "importantUpdates" : "title")
        readonly property color updateColor: root.alertColor(root.alertLevel, Color.bar.background, foreground)
        onPressed: root.opened ? root.close() : root.open()

        GridLayout {
            id: mark
            anchors.centerIn: parent
            columns: root.vertical ? 1 : 2
            layoutDirection: Qt.LeftToRight
            LayoutMirroring.enabled: false
            columnSpacing: Style.space(4)
            rowSpacing: Style.space(2)
            scale: button.pressScale

            OpticalGlyph {
                Layout.alignment: Qt.AlignCenter
                Layout.preferredWidth: button.markSize
                Layout.preferredHeight: button.markSize
                text: button.text
                fontFamily: button.fontFamily
                fontSize: button.fontSize
                paintedSize: button.markSize
                color: button.updateColor
            }

            Text {
                Layout.alignment: Qt.AlignCenter
                textFormat: Text.PlainText
                text: root.countLabel
                font.family: button.fontFamily
                font.pixelSize: root.vertical ? Style.font.caption : button.fontSize
                color: button.updateColor
            }
        }
    }

    Item {
        id: panelAnchor
        parent: button
        width: button.width
        height: button.height
        x: popup.anchorShift
    }

    TransformWatcher {
        id: barAnchorTransform
        a: popup.anchorWindow ? popup.anchorWindow.contentItem : null
        b: button
    }

    KeyboardPanel {
        id: popup
        WlrLayershell.namespace: "omarchy-omaupdate"
        owner: root
        bar: root.bar
        anchorItem: panelAnchor
        open: root.opened
        centerOnBar: false
        focusTarget: loadedContent
        padding: 0
        borderSpec: Border.none()

        readonly property real gap: Style.space(10)
        readonly property real preferredWidth: Style.space(442)
        readonly property bool sideBySide: root.showingSettings && availableCardWidth >= Style.space(760) + gap
        readonly property bool stacked: root.showingSettings && !sideBySide
        readonly property real settingsWidth: sideBySide ? Math.min(preferredWidth, Math.max(Style.space(318), availableCardWidth * 0.37)) : mainWidth
        readonly property real mainWidth: fittedContentWidth(sideBySide ? Math.min(preferredWidth, availableCardWidth - settingsWidth - gap) : preferredWidth)
        readonly property real anchorCenter: {
            barAnchorTransform.transform;
            return anchorWindow ? button.mapToItem(anchorWindow.contentItem, button.width / 2, 0).x : 0;
        }
        readonly property real mainLeft: Math.max(margin, Math.min(anchorCenter - mainWidth / 2, screenW - margin - mainWidth))
        readonly property bool settingsOnLeft: barPos === "right" || (barPos !== "left" && mainLeft - margin > screenW - margin - mainLeft - mainWidth)
        readonly property real anchorShift: sideBySide && !root.vertical ? mainLeft - (settingsOnLeft ? settingsWidth + gap : 0) + contentWidth / 2 - anchorCenter : 0
        readonly property real heightLimit: Math.min(Style.space(690), availableCardHeight > 0 ? availableCardHeight * 0.88 : Style.space(690))

        contentWidth: sideBySide ? mainWidth + gap + settingsWidth : mainWidth
        contentHeight: fittedContentHeight(loadedContentHeight)

        content: FocusScope {
            id: dashboard
            readonly property var panelSurface: {
                let ancestor = parent;
                while (ancestor) {
                    if (ancestor instanceof BorderSurface)
                        return ancestor;
                    ancestor = ancestor.parent;
                }
                return null;
            }
            readonly property real settingsHeight: Math.min(settingsHeader.implicitHeight + settingsGroups.implicitHeight + Style.space(40), popup.stacked ? Math.max(0, (popup.heightLimit - popup.gap) * 0.44) : popup.heightLimit)
            readonly property real mainHeight: Math.min(Style.space(665), popup.stacked ? Math.max(0, popup.heightLimit - settingsHeight - popup.gap) : popup.heightLimit)
            implicitHeight: popup.stacked ? mainHeight + popup.gap + settingsHeight : Math.max(mainHeight, root.showingSettings ? settingsHeight : 0)

            Binding {
                target: dashboard.panelSurface
                property: "color"
                value: "transparent"
                when: dashboard.panelSurface !== null
            }

            Keys.onEscapePressed: {
                if (root.showingSettings) {
                    root.showingSettings = false;
                    settingsButton.forceActiveFocus();
                } else {
                    root.close();
                }
            }
            readonly property color ink: Color.popups.text
            readonly property color secondary: Qt.tint(ink, Qt.alpha(Color.popups.background, 0.32))
            readonly property color updateColor: root.alertColor(root.alertLevel, Color.popups.background, ink)
            readonly property color importantColor: root.alertColor(3, Color.popups.background, ink)
            readonly property color surface: Qt.alpha(ink, 0.055)
            readonly property color line: Qt.alpha(ink, 0.15)

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onClicked: root.close()
            }

            PaneSurface {
                x: popup.sideBySide && popup.settingsOnLeft ? popup.settingsWidth + popup.gap : 0
                y: popup.barPos === "bottom" ? dashboard.height - height : 0
                width: popup.mainWidth
                height: dashboard.mainHeight

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(10)
                    spacing: Style.space(12)

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Style.space(8)
                        Layout.rightMargin: Style.space(8)
                        Layout.topMargin: Style.space(6)
                        spacing: Style.space(8)

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(4)

                            PanelText {
                                Layout.fillWidth: true
                                font.pixelSize: Style.font.subtitle
                                font.bold: true
                                text: strings.t("title")
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }

                            PanelText {
                                Layout.fillWidth: true
                                font.pixelSize: Style.font.caption
                                color: dashboard.secondary
                                text: root.lastScan ? strings.t("lastScan").arg(new Date(root.lastScan).toLocaleString(Qt.locale(I18n.formatLocale), Locale.ShortFormat)) : strings.t("noScanYet")
                            }
                        }

                        RoundedButton {
                            foreground: dashboard.ink
                            focusable: true
                            bordered: true
                            enabled: !root.scanning
                            iconText: "\uf021"
                            text: strings.t("search")
                            radius: height / 2
                            opacity: enabled ? 1 : 0.4
                            onClicked: root.check()
                        }

                        RoundedButton {
                            id: settingsButton
                            Layout.preferredWidth: Style.space(37)
                            Layout.preferredHeight: Style.space(37)
                            radius: height / 2
                            horizontalPadding: 0
                            verticalPadding: 0
                            foreground: dashboard.ink
                            iconText: "\uf013"
                            iconSize: Style.space(17)
                            selected: root.showingSettings
                            bordered: true
                            focusable: true
                            Accessible.name: strings.t("settings")
                            tooltipText: strings.t("settings")
                            onClicked: root.showingSettings = !root.showingSettings
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: overview.implicitHeight + Style.space(24)
                        radius: root.controlRadius
                        color: dashboard.surface
                        border.color: dashboard.line

                        RowLayout {
                            id: overview
                            anchors.fill: parent
                            anchors.margins: Style.space(12)
                            spacing: Style.space(12)

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(3)

                                PanelText {
                                    font.pixelSize: Style.space(21)
                                    font.bold: true
                                    color: dashboard.updateColor
                                    text: root.countLabel
                                }

                                PanelText {
                                    Layout.fillWidth: true
                                    font.pixelSize: Style.font.caption
                                    color: root.hasImportantUpdates ? dashboard.importantColor : dashboard.secondary
                                    text: strings.t(root.hasImportantUpdates ? "importantUpdates" : "availableUpdates")
                                }
                            }

                            RoundedButton {
                                foreground: Color.accent.hslLightness > 0.56 ? "#171717" : "#ffffff"
                                background: Color.accent
                                color: hot ? Qt.tint(background, Qt.alpha(foreground, 0.12)) : background
                                radius: height / 2
                                Layout.preferredHeight: Style.space(44)
                                opacity: enabled ? 1 : 0.4
                                bordered: true
                                focusable: true
                                enabled: !launcher.running
                                iconText: "\uf019"
                                text: strings.t("apply")
                                onClicked: root.launch("apply")
                            }
                        }
                    }

                    PanelText {
                        Layout.fillWidth: true
                        visible: root.notice !== ""
                        font.pixelSize: Style.font.caption
                        color: (root.notice === "scanError" || root.notice === "installError") ? Color.urgent : dashboard.secondary
                        text: root.notice ? strings.t(root.notice) : ""
                    }

                    PanelText {
                        Layout.fillWidth: true
                        font.bold: true
                        text: strings.t("sources")
                    }

                    ListView {
                        id: sources
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: root.orderedResults
                        Controls.ScrollBar.vertical: Controls.ScrollBar {
                            policy: sources.contentHeight > sources.height + 1 ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
                            background: null
                            width: Style.space(5)
                            contentItem: Rectangle {
                                implicitWidth: Style.space(3)
                                radius: width / 2
                                color: dashboard.line
                            }
                        }
                        spacing: Style.space(6)

                        delegate: Rectangle {
                            id: sourceCard
                            required property var modelData
                            readonly property bool expanded: root.sourceExpansion[modelData.source] ?? (root.sourceRank(modelData) === 0)
                            readonly property bool hasDetails: modelData.items.length > 0 || modelData.detail !== "" || modelData.status === "manual"
                            width: sources.width
                            height: sourceContent.implicitHeight + Style.space(8)
                            color: dashboard.surface
                            radius: root.controlRadius
                            border.color: expanded ? dashboard.line : "transparent"

                            ColumnLayout {
                                id: sourceContent
                                width: parent.width - Style.space(12)
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.top: parent.top
                                anchors.topMargin: Style.space(4)
                                spacing: Style.space(4)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.space(4)

                                    RoundedButton {
                                        Layout.fillWidth: true
                                        leftAlign: true
                                        focusable: sourceCard.hasDetails
                                        enabled: sourceCard.hasDetails
                                        implicitHeight: Style.spacing.controlHeight
                                        foreground: dashboard.ink
                                        onClicked: root.sourceExpansion = Object.assign({}, root.sourceExpansion, {
                                            [sourceCard.modelData.source]: !sourceCard.expanded
                                        })

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: Style.space(8)
                                            anchors.rightMargin: Style.space(8)
                                            spacing: Style.space(8)

                                            PanelText {
                                                Layout.fillWidth: true
                                                font.bold: true
                                                text: strings.t("source." + sourceCard.modelData.source, sourceCard.modelData.source)
                                            }

                                            PanelText {
                                                color: dashboard.secondary
                                                font.pixelSize: Style.font.caption
                                                text: sourceCard.modelData.status === "manual" ? strings.t("inventory") : strings.t(sourceCard.modelData.status)
                                            }

                                            Rectangle {
                                                visible: sourceCard.modelData.count > 0
                                                implicitWidth: tally.implicitWidth + Style.space(12)
                                                implicitHeight: tally.implicitHeight + Style.space(5)
                                                color: Qt.alpha(Color.accent, 0.24)
                                                radius: height / 2

                                                PanelText {
                                                    id: tally
                                                    anchors.centerIn: parent
                                                    font.pixelSize: Style.font.caption
                                                    font.bold: true
                                                    text: I18n.formatNumber(sourceCard.modelData.count)
                                                }
                                            }

                                            PanelText {
                                                Layout.preferredWidth: Style.space(10)
                                                font.pixelSize: Style.font.caption
                                                color: dashboard.secondary
                                                text: sourceCard.hasDetails ? (sourceCard.expanded ? "−" : "+") : ""
                                            }
                                        }
                                    }

                                    RoundedButton {
                                        visible: !!sourceCard.modelData.install
                                        enabled: !launcher.running
                                        focusable: true
                                        bordered: true
                                        foreground: dashboard.ink
                                        text: strings.t("install")
                                        onClicked: root.launch("install", sourceCard.modelData.install)
                                    }
                                }

                                ColumnLayout {
                                    visible: sourceCard.expanded
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Style.space(8)
                                    Layout.rightMargin: Style.space(8)
                                    Layout.bottomMargin: Style.space(8)
                                    spacing: Style.space(6)

                                    Rectangle {
                                        Layout.fillWidth: true
                                        implicitHeight: 1
                                        color: dashboard.line
                                    }

                                    Loader {
                                        Layout.fillWidth: true
                                        active: sourceCard.expanded && sourceCard.modelData.items.length > 0
                                        visible: active
                                        sourceComponent: ColumnLayout {
                                            spacing: Style.space(2)

                                            Repeater {
                                                model: sourceCard.modelData.items
                                                delegate: Rectangle {
                                                    id: packageRow
                                                    required property var modelData
                                                    readonly property bool hasVersions: modelData.current.join("") !== "" || modelData.available.join("") !== ""
                                                    readonly property string detail: {
                                                        const priority = modelData.priority ? "\n" + strings.t("priority." + modelData.priority) : "";
                                                        if (!hasVersions)
                                                            return modelData.name + priority;
                                                        const label = modelData.kind ? "\n" + strings.t("version." + modelData.kind) : "";
                                                        return modelData.name + priority + "\n" + strings.t("version.installed") + ": " + currentVersion.value + "\n" + strings.t("version.available") + ": " + availableVersion.value + label;
                                                    }
                                                    Accessible.name: detail
                                                    Accessible.role: Accessible.StaticText
                                                    Layout.fillWidth: true
                                                    implicitHeight: packageLine.implicitHeight + Style.space(8)
                                                    radius: Style.space(10)
                                                    color: Qt.alpha(dashboard.ink, hover.hovered ? 0.11 : 0.055)

                                                    HoverHandler {
                                                        id: hover
                                                    }

                                                    RowLayout {
                                                        id: packageLine
                                                        anchors.fill: parent
                                                        anchors.leftMargin: Style.space(8)
                                                        anchors.rightMargin: Style.space(8)
                                                        spacing: Style.space(7)

                                                        PanelText {
                                                            visible: !!packageRow.modelData.priority
                                                            color: dashboard.importantColor
                                                            font.bold: true
                                                            font.pixelSize: Style.font.caption
                                                            text: "!"
                                                        }

                                                        PanelText {
                                                            id: packageName
                                                            Layout.fillWidth: true
                                                            Layout.minimumWidth: Style.space(45)
                                                            text: packageRow.modelData.name
                                                            wrapMode: Text.NoWrap
                                                            elide: Text.ElideRight
                                                            font.bold: true
                                                            font.pixelSize: Style.font.caption
                                                        }

                                                        PanelText {
                                                            visible: packageRow.hasVersions
                                                            text: "·"
                                                            color: dashboard.secondary
                                                        }

                                                        VersionLabel {
                                                            id: currentVersion
                                                            visible: packageRow.hasVersions
                                                            Layout.fillWidth: true
                                                            Layout.minimumWidth: Style.space(28)
                                                            Layout.maximumWidth: Math.max(implicitWidth, Layout.minimumWidth)
                                                            parts: packageRow.modelData.current
                                                            mutedColor: dashboard.secondary
                                                            highlightColor: dashboard.ink
                                                        }

                                                        PanelText {
                                                            visible: packageRow.hasVersions
                                                            text: "→"
                                                            color: dashboard.secondary
                                                        }

                                                        VersionLabel {
                                                            id: availableVersion
                                                            visible: packageRow.hasVersions
                                                            Layout.fillWidth: true
                                                            Layout.minimumWidth: Style.space(28)
                                                            Layout.maximumWidth: Math.max(implicitWidth, Layout.minimumWidth)
                                                            parts: packageRow.modelData.available
                                                            mutedColor: dashboard.secondary
                                                            highlightColor: Style.selectedStateColor(dashboard.ink, Color.accent)
                                                        }
                                                    }

                                                    Controls.ToolTip {
                                                        visible: hover.hovered && (packageRow.hasVersions || packageName.truncated)
                                                        delay: 650
                                                        width: Math.min(Style.space(330), sources.width)
                                                        padding: Style.space(8)
                                                        contentItem: PanelText {
                                                            text: packageRow.detail
                                                            color: Color.tooltip.text
                                                        }
                                                        background: BorderSurface {
                                                            radius: root.controlRadius
                                                            color: Color.tooltip.background
                                                            borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    PanelText {
                                        Layout.fillWidth: true
                                        font.pixelSize: Style.font.caption
                                        color: dashboard.secondary
                                        readonly property int remaining: sourceCard.modelData.count - sourceCard.modelData.items.length
                                        visible: remaining > 0
                                        text: strings.t("more").arg(I18n.formatNumber(remaining))
                                    }

                                    PanelText {
                                        Layout.fillWidth: true
                                        font.pixelSize: Style.font.caption
                                        color: dashboard.secondary
                                        visible: text !== ""
                                        text: sourceCard.modelData.status === "manual" ? strings.t("manual") : sourceCard.modelData.detail
                                    }
                                }
                            }
                        }
                    }
                }
            }

            PaneSurface {
                settingsPane: true
                visible: root.showingSettings
                x: popup.sideBySide && !popup.settingsOnLeft ? popup.mainWidth + popup.gap : 0
                y: popup.stacked ? (popup.barPos === "bottom" ? 0 : dashboard.mainHeight + popup.gap) : (popup.barPos === "bottom" ? dashboard.height - height : 0)
                width: popup.settingsWidth
                height: dashboard.settingsHeight

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(10)
                    spacing: Style.space(8)

                    RowLayout {
                        id: settingsHeader
                        Layout.fillWidth: true
                        Layout.leftMargin: Style.space(8)
                        Layout.rightMargin: Style.space(8)
                        Layout.topMargin: Style.space(6)
                        spacing: Style.space(8)

                        PanelText {
                            Layout.fillWidth: true
                            text: strings.t("settings")
                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                        }

                        RoundedButton {
                            Layout.preferredWidth: Style.space(37)
                            Layout.preferredHeight: Style.space(37)
                            radius: height / 2
                            horizontalPadding: 0
                            verticalPadding: 0
                            foreground: dashboard.ink
                            text: "×"
                            bordered: true
                            focusable: true
                            Accessible.name: strings.t("closeSettings")
                            onClicked: {
                                root.showingSettings = false;
                                settingsButton.forceActiveFocus();
                            }
                        }
                    }

                    Flickable {
                        id: settingsScroll
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentHeight: settingsGroups.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        Controls.ScrollBar.vertical: Controls.ScrollBar {
                            policy: settingsScroll.contentHeight > settingsScroll.height + 1 ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff
                            background: null
                        }

                        ColumnLayout {
                            id: settingsGroups
                            width: settingsScroll.width
                            spacing: Style.space(8)

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: scanGroup.implicitHeight + Style.space(28)
                                radius: root.controlRadius
                                color: dashboard.surface
                                border.color: dashboard.line

                                ColumnLayout {
                                    id: scanGroup
                                    anchors.fill: parent
                                    anchors.margins: Style.space(14)
                                    spacing: Style.space(8)

                                    PanelText {
                                        Layout.fillWidth: true
                                        text: strings.t("scanSettings")
                                        color: Color.accent
                                        font.bold: true
                                    }

                                    RoundedSelect {
                                        Layout.fillWidth: true
                                        label: strings.t("scanFrequency")
                                        value: root.scanFrequency
                                        options: root.scanChoices
                                        onChanged: value => root.changeFrequency(value)
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: appearanceGroup.implicitHeight + Style.space(28)
                                radius: root.controlRadius
                                color: dashboard.surface
                                border.color: dashboard.line

                                ColumnLayout {
                                    id: appearanceGroup
                                    anchors.fill: parent
                                    anchors.margins: Style.space(14)
                                    spacing: Style.space(8)

                                    PanelText {
                                        Layout.fillWidth: true
                                        text: strings.t("appearance")
                                        color: Color.accent
                                        font.bold: true
                                    }

                                    Toggle {
                                        Layout.fillWidth: true
                                        label: strings.t("glassFinish")
                                        foreground: dashboard.ink
                                        checked: root.glassFinish
                                        titleSize: Style.font.body
                                        rounded: true
                                        radius: Style.space(10)
                                        implicitHeight: Style.space(34)
                                        onClicked: root.saveSetting("glassFinish", !checked)
                                    }

                                    Toggle {
                                        Layout.fillWidth: true
                                        visible: root.glassFinish
                                        label: strings.t("blurBackdrop")
                                        foreground: dashboard.ink
                                        checked: root.blurBackdrop
                                        titleSize: Style.font.body
                                        rounded: true
                                        radius: Style.space(10)
                                        implicitHeight: Style.space(34)
                                        onClicked: root.saveSetting("blurBackdrop", !checked)
                                    }

                                    PanelText {
                                        Layout.fillWidth: true
                                        visible: root.wantsBackdropBlur && root.backdropBlurFailed
                                        color: Color.urgent
                                        text: strings.t("blurFailed")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    component PaneSurface: Rectangle {
        id: pane
        property bool settingsPane: false
        radius: root.cardRadius
        border.width: 1
        border.color: Qt.alpha(dashboard.ink, root.glassFinish ? 0.24 : 0.15)

        function finish(tint, opacity) {
            const base = Qt.tint(Color.popups.background, Qt.alpha(Color.accent, tint));
            return root.glassFinish ? Qt.alpha(base, opacity + (settingsPane ? 0.08 : 0)) : base;
        }

        gradient: Gradient {
            GradientStop {
                position: 0
                color: pane.finish(root.glassFinish ? 0.25 : 0.17, 0.77)
            }
            GradientStop {
                position: 0.54
                color: pane.finish(root.glassFinish ? 0.12 : 0.06, 0.72)
            }
            GradientStop {
                position: 1
                color: pane.finish(root.glassFinish ? 0.04 : 0, 0.88)
            }
        }

        Rectangle {
            visible: root.glassFinish
            anchors.top: parent.top
            anchors.topMargin: 1
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(24)
            anchors.rightMargin: Style.space(24)
            height: 1
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop {
                    position: 0
                    color: "transparent"
                }
                GradientStop {
                    position: 0.5
                    color: Qt.alpha(dashboard.ink, 0.22)
                }
                GradientStop {
                    position: 1
                    color: "transparent"
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
        }
    }
}

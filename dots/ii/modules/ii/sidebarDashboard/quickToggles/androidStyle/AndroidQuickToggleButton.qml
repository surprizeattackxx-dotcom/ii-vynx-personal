import QtQuick
import QtQuick.Layouts
import qs.services
import qs.modules.common
import qs.modules.common.models.quickToggles
import qs.modules.common.functions
import qs.modules.common.widgets

GroupButton {
    id: root

    required property int buttonIndex
    required property var buttonData
    required property bool expandedSize
    required property real baseCellWidth
    required property real baseCellHeight
    required property real cellSpacing
    required property int cellSize

    signal openMenu()

    property QuickToggleModel toggleModel
    property string name:        toggleModel?.name ?? ""
    property string statusText:  (toggleModel?.hasStatusText) ? (toggleModel?.statusText || (toggled ? Translation.tr("Active") : Translation.tr("Inactive"))) : ""
    property string tooltipText: toggleModel?.tooltipText ?? ""
    property string buttonIcon:  toggleModel?.icon ?? "close"
    property bool available:     toggleModel?.available ?? true
    toggled: toggleModel?.toggled ?? false
    property var mainAction: toggleModel?.mainAction ?? null
    altAction: toggleModel?.hasMenu ? (() => root.openMenu()) : (toggleModel?.altAction ?? null)

    property bool editMode: false

    baseWidth:  root.baseCellWidth * cellSize + cellSpacing * (cellSize - 1)
    baseHeight: root.baseCellHeight
    enableImplicitWidthAnimation:  !editMode && root.mouseArea.containsMouse
    enableImplicitHeightAnimation: !editMode && root.mouseArea.containsMouse
    Behavior on baseWidth  { animation: Appearance.animation.elementMove.numberAnimation.createObject(this) }
    Behavior on baseHeight { animation: Appearance.animation.elementMove.numberAnimation.createObject(this) }
    opacity: 0
    Component.onCompleted: { opacity = 1 }
    Behavior on opacity { animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this) }

    enabled: available || editMode
    padding: 6
    horizontalPadding: padding
    verticalPadding:   padding

    // ── M3 colors — primaryContainer for ALL toggled states including expanded+altAction ──
    colBackground:              Appearance.m3colors.m3surfaceContainerHigh
    colBackgroundToggled:       Appearance.m3colors.m3primaryContainer
    colBackgroundToggledHover:  Qt.lighter(Appearance.m3colors.m3primaryContainer, 1.08)
    colBackgroundToggledActive: Qt.darker(Appearance.m3colors.m3primaryContainer, 1.08)

    buttonRadius:        toggled ? Appearance.rounding.large : height / 2
    buttonRadiusPressed: Appearance.rounding.normal

    // Always onPrimaryContainer when toggled — fixes expanded+altAction buttons (EasyEffects etc.)
    property color colText: (toggled && enabled)
    ? Appearance.m3colors.m3onPrimaryContainer
    : ColorUtils.transparentize(Appearance.colors.colOnLayer2, enabled ? 0 : 0.7)

    property color colIcon: expandedSize
    ? (root.toggled ? Appearance.m3colors.m3onPrimaryContainer : Appearance.colors.colOnLayer3)
    : colText

    onClicked: {
        if (root.expandedSize && root.altAction) root.altAction();
        else root.mainAction();
    }

    contentItem: RowLayout {
        spacing: 4
        anchors {
            centerIn:    root.expandedSize ? undefined : parent
            fill:        root.expandedSize ? parent    : undefined
            leftMargin:  root.horizontalPadding
            rightMargin: root.horizontalPadding
        }

        // ── Icon ──────────────────────────────────────────────────────────────
        MouseArea {
            id: iconMouseArea
            hoverEnabled: true
            acceptedButtons: (root.expandedSize && root.altAction) ? Qt.LeftButton : Qt.NoButton
            Layout.alignment:    Qt.AlignHCenter
            Layout.fillHeight:   true
            Layout.topMargin:    root.verticalPadding
            Layout.bottomMargin: root.verticalPadding
            implicitHeight: iconBackground.implicitHeight
            implicitWidth:  iconBackground.implicitWidth
            cursorShape: Qt.PointingHandCursor
            onClicked: root.mainAction()

            Rectangle {
                id: iconBackground
                anchors.fill:  parent
                implicitWidth: height
                radius: root.radius - root.verticalPadding

                color: {
                    const base = root.toggled
                    ? Appearance.m3colors.m3primary
                    : Appearance.m3colors.m3surfaceContainerHighest
                    // Only show icon container as distinct element in expanded+menu mode
                    const transparentizeAmount = (root.altAction && root.expandedSize) ? 0 : 1
                    return ColorUtils.transparentize(base, transparentizeAmount)
                }

                Behavior on radius { animation: Appearance.animation.elementMove.numberAnimation.createObject(this) }
                Behavior on color  { animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this) }

                MaterialSymbol {
                    anchors.centerIn: parent
                    fill:     root.toggled ? 1 : 0
                    iconSize: root.expandedSize ? 22 : 24
                    // onPrimary inside icon circle when toggled, colIcon otherwise
                    color: (root.toggled && root.altAction && root.expandedSize)
                    ? Appearance.m3colors.m3onPrimary
                    : root.colIcon
                    text: root.buttonIcon
                }

                Loader {
                    anchors.fill: parent
                    active: (root.expandedSize && root.altAction)
                    sourceComponent: Rectangle {
                        radius: iconBackground.radius
                        color: ColorUtils.transparentize(root.colIcon,
                                                         iconMouseArea.containsPress  ? 0.88 :
                                                         iconMouseArea.containsMouse  ? 0.95 : 1)
                        Behavior on color { animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this) }
                    }
                }
            }
        }

        // ── Text column (expanded only) ────────────────────────────────────────
        Loader {
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true
            visible: root.expandedSize
            active:  visible
            sourceComponent: Column {
                spacing: -2
                StyledText {
                    anchors { left: parent.left; right: parent.right }
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight:    600
                    color:          root.colText
                    elide:          Text.ElideRight
                    text:           root.name
                }
                StyledText {
                    visible: root.statusText
                    anchors { left: parent.left; right: parent.right }
                    font { pixelSize: Appearance.font.pixelSize.smaller; weight: 100 }
                    color:  root.colText
                    elide:  Text.ElideRight
                    text:   root.statusText
                }
            }
        }
    }

    // ── Edit mode interaction ─────────────────────────────────────────────────
    MouseArea {
        id: editModeInteraction
        visible:        root.editMode
        anchors.fill:   parent
        cursorShape:    Qt.PointingHandCursor
        hoverEnabled:   true
        acceptedButtons: Qt.AllButtons

        function toggleEnabled() {
            const toggleList = Config.options.sidebar.quickToggles.android.toggles;
            const buttonType = root.buttonData.type;
            if (!toggleList.find(t => t.type === buttonType))
                toggleList.push({ type: buttonType, size: 1 });
            else
                toggleList.splice(root.buttonIndex, 1);
        }
        function toggleSize() {
            const toggleList = Config.options.sidebar.quickToggles.android.toggles;
            const buttonType = root.buttonData.type;
            if (!toggleList.find(t => t.type === buttonType)) return;
            toggleList[root.buttonIndex].size = 3 - toggleList[root.buttonIndex].size;
        }
        function movePositionBy(offset) {
            const toggleList  = Config.options.sidebar.quickToggles.android.toggles;
            const buttonType  = root.buttonData.type;
            const targetIndex = root.buttonIndex + offset;
            if (!toggleList.find(t => t.type === buttonType)) return;
            if (targetIndex < 0 || targetIndex >= toggleList.length) return;
            const temp = toggleList[root.buttonIndex];
            toggleList[root.buttonIndex] = toggleList[targetIndex];
            toggleList[targetIndex] = temp;
        }

        onReleased:     (e) => { if (e.button === Qt.LeftButton) toggleEnabled(); }
        onPressed:      (e) => { if (e.button === Qt.RightButton) toggleSize(); }
        onPressAndHold: (e) => { toggleSize(); }
        onWheel:        (e) => {
            if      (e.angleDelta.y < 0) movePositionBy(1);
            else if (e.angleDelta.y > 0) movePositionBy(-1);
            e.accepted = true;
        }
    }

    // ── Edit mode highlight border ────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: root.editMode ? 1.5 : 0
        border.color: root.editMode
        ? Qt.rgba(Appearance.colors.colPrimary.r,
                  Appearance.colors.colPrimary.g,
                  Appearance.colors.colPrimary.b, 0.7)
        : "transparent"
        visible: root.editMode
        Behavior on border.color { ColorAnimation { duration: 150 } }

        // Small drag handle hint in top-right corner
        MaterialSymbol {
            anchors { top: parent.top; right: parent.right; margins: 3 }
            text: "drag_indicator"
            iconSize: 9
            color: Appearance.colors.colPrimary
            opacity: 0.7
        }
    }

    StyledToolTip {
        extraVisibleCondition: root.tooltipText !== ""
        text: root.tooltipText
    }
}

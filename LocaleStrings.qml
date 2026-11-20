import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    readonly property string systemLocale: Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "C"
    readonly property string language: {
        if (["C", "POSIX"].includes(systemLocale.split(".")[0]))
            return "en";
        const choices = (Quickshell.env("LANGUAGE") || "").split(":").concat(systemLocale);
        return choices.map(languageOf).find(code => code === "en" || code === "es") || "en";
    }
    readonly property var formatLocale: Qt.locale(languageOf(systemLocale) === language ? systemLocale.split(/[.@]/)[0] : language)

    function languageOf(locale) {
        return locale.toLowerCase().split(/[-_.@]/)[0];
    }

    function readCatalog(contents) {
        try {
            return JSON.parse(contents || "{}");
        } catch (error) {
            return {};
        }
    }

    readonly property var english: readCatalog(englishFile.text())
    readonly property var localized: language === "en" ? english : readCatalog(localizedFile.text())

    function t(key, fallback) {
        return localized[key] || english[key] || (fallback === undefined ? key : fallback);
    }

    function formatNumber(number) {
        return number.toLocaleString(formatLocale, "f", 0);
    }

    property FileView englishFile: FileView {
        path: Qt.resolvedUrl("i18n/en.json")
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
    }

    property FileView localizedFile: FileView {
        path: root.language === "en" ? "" : Qt.resolvedUrl("i18n/" + root.language + ".json")
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
    }
}

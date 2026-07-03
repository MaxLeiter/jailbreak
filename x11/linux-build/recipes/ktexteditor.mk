ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# ktexteditor.mk - KF6 TextEditor for KWrite. Text-to-speech and print UI
# are patched out until qtmultimedia/qtspeech and Qt iOS printing are ready.

SUBPROJECTS += ktexteditor
KTEXTEDITOR_VERSION = $(KF6_VERSION)
DEB_KTEXTEDITOR_V ?= $(KTEXTEDITOR_VERSION)+ios1

ktexteditor-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,ktexteditor))
	$(call EXTRACT_TAR,ktexteditor-$(KF6_VERSION).tar.xz,ktexteditor-$(KF6_VERSION),ktexteditor)
	sed -i 's/Core Widgets Qml PrintSupport TextToSpeech/Core Widgets Qml/' $(BUILD_WORK)/ktexteditor/CMakeLists.txt
	sed -i '/Qt6::TextToSpeech/d;/Qt6::PrintSupport/d' $(BUILD_WORK)/ktexteditor/src/CMakeLists.txt
	sed -i '/printing\/kateprinter.cpp/d;/printing\/printpainter.cpp/d;/printing\/printconfigwidgets.cpp/d' $(BUILD_WORK)/ktexteditor/src/CMakeLists.txt
	sed -i '/#include <QTextToSpeech>/d' $(BUILD_WORK)/ktexteditor/src/view/kateview.cpp $(BUILD_WORK)/ktexteditor/src/utils/kateglobal.cpp
	sed -i '/class QTextToSpeech;/d' $(BUILD_WORK)/ktexteditor/src/utils/kateglobal.h
	sed -i '/#include "printing\/kateprinter.h"/d' $(BUILD_WORK)/ktexteditor/src/view/kateview.cpp $(BUILD_WORK)/ktexteditor/src/document/katedocument.cpp
	perl -0777 -i -pe 's/QTextToSpeech \*KTextEditor::EditorPrivate::speechEngine\(KTextEditor::ViewPrivate \*view\)\n\{.*?\n\}\n\nvoid KTextEditor::EditorPrivate::speechEngineUserDestoyed\(\)\n\{.*?\n\}\n\n//s' $(BUILD_WORK)/ktexteditor/src/utils/kateglobal.cpp
	perl -0777 -i -pe 's/void KTextEditor::ViewPrivate::setupSpeechActions\(\)\n\{.*?\n\}\n\nvoid KTextEditor::ViewPrivate::slotFoldToplevelNodes/void KTextEditor::ViewPrivate::setupSpeechActions()\n{\n}\n\nvoid KTextEditor::ViewPrivate::slotFoldToplevelNodes/s' $(BUILD_WORK)/ktexteditor/src/view/kateview.cpp
	perl -0777 -i -pe 's/bool KTextEditor::ViewPrivate::print\(\)\n\{\n    return KatePrinter::print\(this\);\n\}/bool KTextEditor::ViewPrivate::print()\n{\n    return false;\n}/s' $(BUILD_WORK)/ktexteditor/src/view/kateview.cpp
	perl -0777 -i -pe 's/void KTextEditor::ViewPrivate::printPreview\(\)\n\{\n    KatePrinter::printPreview\(this\);\n\}/void KTextEditor::ViewPrivate::printPreview()\n{\n}/s' $(BUILD_WORK)/ktexteditor/src/view/kateview.cpp
	perl -0777 -i -pe 's/bool KTextEditor::DocumentPrivate::print\(\)\n\{\n    return KatePrinter::print\(this\);\n\}/bool KTextEditor::DocumentPrivate::print()\n{\n    return false;\n}/s' $(BUILD_WORK)/ktexteditor/src/document/katedocument.cpp
	perl -0777 -i -pe 's/void KTextEditor::DocumentPrivate::printPreview\(\)\n\{\n    KatePrinter::printPreview\(this\);\n\}/void KTextEditor::DocumentPrivate::printPreview()\n{\n}/s' $(BUILD_WORK)/ktexteditor/src/document/katedocument.cpp
	perl -0777 -i -pe 's/\n    \/\*\*\n     \* text to speech engine.*?\n     \*\/\n    QTextToSpeech \*speechEngine\(KTextEditor::ViewPrivate \*view\);\n//s' $(BUILD_WORK)/ktexteditor/src/utils/kateglobal.h
	perl -0777 -i -pe 's/\n    \/\*\*\n     \* Was the view that started the current speak output destroyed\?\n     \*\/\n    void speechEngineUserDestoyed\(\);\n//s' $(BUILD_WORK)/ktexteditor/src/utils/kateglobal.h
	perl -0777 -i -pe 's/\n    \/\*\*\n     \* text to speech engine.*?\n    QPointer<KTextEditor::ViewPrivate> m_speechEngineLastUser;\n//s' $(BUILD_WORK)/ktexteditor/src/utils/kateglobal.h
	perl -0777 -i -pe 's/\n    <Menu name="speech" group="tools_speech">.*?<\/Menu>\n//s' $(BUILD_WORK)/ktexteditor/src/data/katepart5ui.rc
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/ktexteditor/.build_complete),)
ktexteditor:
	@echo "Using previously built ktexteditor."
else
ktexteditor: ktexteditor-setup ksyntaxhighlighting
	rm -rf $(BUILD_WORK)/ktexteditor/build
	mkdir -p $(BUILD_WORK)/ktexteditor/build
	cd $(BUILD_WORK)/ktexteditor/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DENABLE_KAUTH=OFF \
		-DENABLE_PCH=OFF \
		-DBUILD_QCH=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_EditorConfig=TRUE
	+ninja -C $(BUILD_WORK)/ktexteditor/build
	+DESTDIR="$(BUILD_STAGE)/ktexteditor" ninja -C $(BUILD_WORK)/ktexteditor/build install
	$(call AFTER_BUILD,copy)
endif

ktexteditor-package: ktexteditor-stage
	rm -rf $(BUILD_DIST)/kf6-texteditor $(BUILD_DIST)/kf6-texteditor-dev
	$(call KF6_COPY_RUNTIME,ktexteditor,kf6-texteditor)
	$(call KF6_COPY_DEV,ktexteditor,kf6-texteditor)
	$(call SIGN,kf6-texteditor,general.xml)
	$(call PACK,kf6-texteditor,DEB_KTEXTEDITOR_V)
	$(call PACK,kf6-texteditor-dev,DEB_KTEXTEDITOR_V)
	rm -rf $(BUILD_DIST)/kf6-texteditor $(BUILD_DIST)/kf6-texteditor-dev

.PHONY: ktexteditor ktexteditor-package

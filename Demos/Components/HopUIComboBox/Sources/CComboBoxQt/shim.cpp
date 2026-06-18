// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// C++ implementation of the pure-C QComboBox surface in CComboBoxQt.h. The text signal is wired once with
// QObject::connect + a capturing lambda forwarding to the stored Swift callback (no moc needed); the
// connection's context object is the combo box, so it's torn down with the widget. The combo is editable,
// so the user can type freeform text as well as choose a menu item.

#include "CComboBoxQt.h"
#include <QtWidgets/QComboBox>

extern "C" {

void *hopqt_combobox_new(void) {
    QComboBox *box = new QComboBox();
    box->setEditable(true);
    // Don't auto-insert typed text as a new permanent menu item; it's just the field's value.
    box->setInsertPolicy(QComboBox::NoInsert);
    return box;
}

void hopqt_combobox_clear(void *combo) { static_cast<QComboBox *>(combo)->clear(); }

void hopqt_combobox_add_item(void *combo, const char *text) {
    static_cast<QComboBox *>(combo)->addItem(QString::fromUtf8(text));
}

void hopqt_combobox_set_text(void *combo, const char *text) {
    static_cast<QComboBox *>(combo)->setCurrentText(QString::fromUtf8(text));
}

void hopqt_combobox_connect(void *combo, hopqt_combo_text_fn fn, void *context) {
    QComboBox *box = static_cast<QComboBox *>(combo);
    // currentTextChanged fires for both freeform typing and menu selection.
    QObject::connect(box, &QComboBox::currentTextChanged, box, [fn, context](const QString &text) {
        if (fn) fn(text.toUtf8().constData(), context);
    });
}

}  // extern "C"

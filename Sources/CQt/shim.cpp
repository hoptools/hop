// Copyright 2026
// SPDX-License-Identifier: MPL-2.0
//
// C++ implementation of the CQt shim. Includes QtWidgets and bridges it to the pure-C surface
// declared in CQt.h. Signals are wired once with QObject::connect + a capturing lambda, so no moc
// step is needed: the lambda forwards to a stored C callback whose target the Swift side updates.

#include "CQt.h"

#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>
#include <QtWidgets/QLabel>
#include <QtWidgets/QPushButton>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QSlider>
#include <QtWidgets/QDateTimeEdit>
#include <QtCore/QDateTime>
#include <QtCore/QEvent>
#include <QtWidgets/QColorDialog>
#include <QtWidgets/QFileDialog>
#include <QtGui/QColor>
#include <QtGui/QFont>
#include <QtWidgets/QListView>
#include <QtWidgets/QTreeWidget>
#include <QtWidgets/QTreeWidgetItemIterator>
#include <QtWidgets/QComboBox>
#include <QtWidgets/QCheckBox>
#include <QtWidgets/QTabWidget>
#include <QtWidgets/QFrame>
#include <QtWidgets/QProgressBar>
#include <QtWidgets/QSplitter>
#include <QtWidgets/QMainWindow>
#include <QtWidgets/QToolBar>
#include <QtWidgets/QMenuBar>
#include <QtWidgets/QMenu>
#include <QtGui/QAction>
#include <QtGui/QKeySequence>
#include <QtGui/QStyleHints>
#include <QtGui/QGuiApplication>
#include <QtGui/QResizeEvent>
#include <QtGui/QPalette>
#include <QtWidgets/QScrollArea>
#include <QtWidgets/QScrollBar>
#include <QtCore/QAbstractListModel>
#include <QtCore/QItemSelectionModel>
#include <QtWidgets/QBoxLayout>
#include <QtWidgets/QVBoxLayout>
#include <QtWidgets/QHBoxLayout>
#include <QtCore/QString>
#include <QtCore/QObject>
#include <QtCore/QSignalBlocker>
#include <QtCore/QTimer>
#include <QtGui/QPainter>
#include <QtGui/QPainterPath>
#include <QtGui/QPixmap>
#include <QtGui/QIcon>
#include <QtGui/QColor>
#include <QtGui/QPen>
#include <QtGui/QBrush>
#include <QtGui/QPaintEvent>
#include <QtGui/QImage>
#include <QtCore/QRectF>
#include <string>
#include <cmath>
#include <cstdlib>
#include <cstring>

static QBoxLayout *boxLayout(void *boxWidget) {
    return qobject_cast<QBoxLayout *>(static_cast<QWidget *>(boxWidget)->layout());
}

// A read-only list model that fetches each visible row's text on demand via a C callback. QListView
// only requests data() for visible rows, so this stays lazy for very large row counts. Overriding
// the inherited virtuals needs no Q_OBJECT/moc since we declare no new signals or slots.
class HopListModel : public QAbstractListModel {
public:
    int rowCountValue = 0;
    hopqt_row_cb rowCallback = nullptr;
    void *userData = nullptr;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override {
        return parent.isValid() ? 0 : rowCountValue;
    }

    QVariant data(const QModelIndex &index, int role) const override {
        if (role != Qt::DisplayRole || rowCallback == nullptr) return QVariant();
        char *s = rowCallback(index.row(), userData);
        QString text = QString::fromUtf8(s ? s : "");
        if (s) free(s);
        return text;
    }
};

// A widget that renders a custom shape: its paintEvent hands an antialiased QPainter back to Swift,
// which drives it. Overriding the virtual paintEvent needs no Q_OBJECT/moc (no new signals/slots).
class HopShapeWidget : public QWidget {
public:
    hopqt_paint_cb paintCallback = nullptr;
    void *userData = nullptr;
protected:
    void paintEvent(QPaintEvent *) override {
        if (paintCallback == nullptr) return;
        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing, true);
        paintCallback(&painter, width(), height(), userData);
    }
};

// A plain absolute-positioning container: it runs no layout manager, so HopUI's layout engine sets
// every child's geometry. The root container reports size changes so the runtime can re-lay-out.
class HopFixedWidget : public QWidget {
public:
    hopqt_resize_cb resizeCallback = nullptr;
    void *resizeUserData = nullptr;
protected:
    void resizeEvent(QResizeEvent *e) override {
        QWidget::resizeEvent(e);
        if (resizeCallback) resizeCallback(width(), height(), resizeUserData);
    }
};

extern "C" {

void *hopqt_app_new(void) {
    static int argc = 1;
    static char arg0[] = "hopqt";
    static char *argv[] = { arg0, nullptr };
    return new QApplication(argc, argv);
}

int hopqt_app_exec(void *app) {
    return static_cast<QApplication *>(app)->exec();
}

void hopqt_post(hopqt_void_cb cb, void *user_data) {
    QTimer::singleShot(0, qApp, [cb, user_data]() { if (cb) cb(user_data); });
}

void hopqt_run_on_main(void *job, hop_job_main_fn fn) {
    // invokeMethod with a QueuedConnection posts a metacall event to qApp's (main) thread; this is
    // thread-safe, so the main-actor executor can call it from a background thread.
    QMetaObject::invokeMethod(qApp, [job, fn]() { if (fn) fn(job); }, Qt::QueuedConnection);
}

void hopqt_set_color_scheme(int dark) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    // Qt 6.8 added a public setter for the application-wide color scheme (Qt::ColorScheme itself is
    // 6.5+). Use it when available (macOS Homebrew Qt, current installers).
    if (QStyleHints *hints = QGuiApplication::styleHints()) {
        hints->setColorScheme(dark ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);
    }
#else
    // Older Qt (e.g. the qt6-base-dev that Ubuntu ships, ~6.4) has no public color-scheme setter, so
    // the app simply follows the system theme. No-op; silence the unused-parameter warning.
    (void)dark;
#endif
}

void hopqt_set_accessible_name(void *widget, const char *name) {
    static_cast<QWidget *>(widget)->setAccessibleName(QString::fromUtf8(name));
}

void hopqt_set_accessible_description(void *widget, const char *desc) {
    static_cast<QWidget *>(widget)->setAccessibleDescription(QString::fromUtf8(desc));
}

void hopqt_set_object_name(void *widget, const char *name) {
    static_cast<QWidget *>(widget)->setObjectName(QString::fromUtf8(name));
}

void *hopqt_window_new(const char *title) {
    // QMainWindow so we can use the idiomatic addToolBar / setCentralWidget.
    QMainWindow *w = new QMainWindow();
    w->setWindowTitle(QString::fromUtf8(title));
    w->resize(820, 760);
    return w;
}

void hopqt_window_set_central(void *window, void *child) {
    static_cast<QMainWindow *>(window)->setCentralWidget(static_cast<QWidget *>(child));
}

void hopqt_window_show(void *window) {
    static_cast<QWidget *>(window)->show();
}

void *hopqt_menu_bar(void *window) {
    return static_cast<QMainWindow *>(window)->menuBar();
}

void *hopqt_menu_add(void *menubar, const char *title) {
    return static_cast<QMenuBar *>(menubar)->addMenu(QString::fromUtf8(title));
}

void hopqt_menu_add_button(void *menu, const char *title, hopqt_void_cb cb, void *user_data) {
    QMenu *m = static_cast<QMenu *>(menu);
    QAction *action = m->addAction(QString::fromUtf8(title));
    QObject::connect(action, &QAction::triggered, m, [cb, user_data]() { if (cb) cb(user_data); });
}

void hopqt_menu_add_command(void *menu, const char *title, int command) {
    QMenu *m = static_cast<QMenu *>(menu);
    QAction *action = m->addAction(QString::fromUtf8(title));
    QKeySequence::StandardKey key = QKeySequence::UnknownKey;
    switch (command) {
        case 0: key = QKeySequence::Cut; break;
        case 1: key = QKeySequence::Copy; break;
        case 2: key = QKeySequence::Paste; break;
        case 3: key = QKeySequence::Undo; break;
        case 4: key = QKeySequence::Redo; break;
        case 5: key = QKeySequence::SelectAll; break;
    }
    if (key != QKeySequence::UnknownKey) action->setShortcut(key);
    // Apply the standard edit command to the focused text field (the platform-idiomatic behavior).
    QObject::connect(action, &QAction::triggered, m, [command]() {
        QLineEdit *edit = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        if (edit == nullptr) return;
        switch (command) {
            case 0: edit->cut(); break;
            case 1: edit->copy(); break;
            case 2: edit->paste(); break;
            case 3: edit->undo(); break;
            case 4: edit->redo(); break;
            case 5: edit->selectAll(); break;
        }
    });
}

void hopqt_menu_add_separator(void *menu) {
    static_cast<QMenu *>(menu)->addSeparator();
}

void *hopqt_toolbar_add(void *window) {
    QMainWindow *w = static_cast<QMainWindow *>(window);
    QToolBar *tb = new QToolBar();
    tb->setMovable(false);
    tb->setFloatable(false);
    w->addToolBar(tb);
    return tb;
}

void hopqt_toolbar_add_button(void *toolbar, const char *title, hopqt_void_cb cb, void *user_data) {
    QToolBar *tb = static_cast<QToolBar *>(toolbar);
    QAction *action = tb->addAction(QString::fromUtf8(title));
    QObject::connect(action, &QAction::triggered, tb, [cb, user_data]() { if (cb) cb(user_data); });
}

void hopqt_toolbar_add_label(void *toolbar, const char *text) {
    QToolBar *tb = static_cast<QToolBar *>(toolbar);
    QLabel *label = new QLabel(QString::fromUtf8(text));
    label->setContentsMargins(8, 0, 8, 0);
    tb->addWidget(label);
}

void hopqt_toolbar_clear(void *toolbar) {
    static_cast<QToolBar *>(toolbar)->clear();
}

void *hopqt_vbox_new(int spacing) {
    QWidget *w = new QWidget();
    QVBoxLayout *l = new QVBoxLayout(w);
    l->setSpacing(spacing);
    l->setContentsMargins(12, 12, 12, 12);
    // Pack content at the top instead of distributing extra vertical space between items (which a
    // QVBoxLayout does by default when stretched taller than its content, e.g. inside a split pane).
    l->setAlignment(Qt::AlignTop);
    return w;
}

void *hopqt_hbox_new(int spacing) {
    QWidget *w = new QWidget();
    QHBoxLayout *l = new QHBoxLayout(w);
    l->setSpacing(spacing);
    l->setContentsMargins(0, 0, 0, 0);
    return w;
}

void hopqt_box_add(void *box, void *child) {
    if (QBoxLayout *l = boxLayout(box)) {
        Qt::Alignment a = qobject_cast<QVBoxLayout *>(l) ? Qt::AlignHCenter : Qt::AlignVCenter;
        l->addWidget(static_cast<QWidget *>(child), 0, a);
    }
}

// The alignment applied to box children (matches hopqt_box_add): center on the cross axis.
static Qt::Alignment boxChildAlignment(QBoxLayout *l) {
    return qobject_cast<QVBoxLayout *>(l) ? Qt::AlignHCenter : Qt::AlignVCenter;
}

void hopqt_box_insert(void *box, void *child, int index) {
    if (QBoxLayout *l = boxLayout(box)) {
        l->insertWidget(index, static_cast<QWidget *>(child), 0, boxChildAlignment(l));
    }
}

void hopqt_box_reorder(void *box, void *child, int index) {
    if (QBoxLayout *l = boxLayout(box)) {
        // Re-inserting an existing widget moves it, preserving the QWidget (and its state).
        l->removeWidget(static_cast<QWidget *>(child));
        l->insertWidget(index, static_cast<QWidget *>(child), 0, boxChildAlignment(l));
    }
}

void hopqt_box_remove(void *box, void *child) {
    if (QBoxLayout *l = boxLayout(box)) {
        l->removeWidget(static_cast<QWidget *>(child));
        static_cast<QWidget *>(child)->setParent(nullptr);
    }
}

void hopqt_box_set_spacing(void *box, int spacing) {
    if (QBoxLayout *l = boxLayout(box)) l->setSpacing(spacing);
}

void hopqt_widget_set_style(void *widget, const char *css) {
    static_cast<QWidget *>(widget)->setStyleSheet(QString::fromUtf8(css));
}

// Style a container as a rounded, bordered, filled "card" (for GroupBox/Section). Scoped via objectName
// so the chrome applies only to this widget, not its children; WA_StyledBackground lets a plain QWidget
// paint the stylesheet background.
void hopqt_widget_make_card(void *widget) {
    QWidget *w = static_cast<QWidget *>(widget);
    w->setObjectName(QStringLiteral("hopCard"));
    w->setAttribute(Qt::WA_StyledBackground, true);
    // Theme-neutral subtle fill + border (works in light and dark; palette(base) painted inconsistently).
    w->setStyleSheet(QStringLiteral(
        "#hopCard { background: rgba(128,128,128,0.10); border: 1px solid rgba(128,128,128,0.35); border-radius: 8px; }"));
}

void *hopqt_label_new(const char *text) {
    return new QLabel(QString::fromUtf8(text));
}

void hopqt_label_set_text(void *label, const char *text) {
    static_cast<QLabel *>(label)->setText(QString::fromUtf8(text));
}

void *hopqt_button_new(const char *text) {
    return new QPushButton(QString::fromUtf8(text));
}

void hopqt_button_set_text(void *button, const char *text) {
    static_cast<QPushButton *>(button)->setText(QString::fromUtf8(text));
}

void hopqt_button_connect(void *button, hopqt_void_cb cb, void *user_data) {
    QPushButton *b = static_cast<QPushButton *>(button);
    QObject::connect(b, &QPushButton::clicked, b, [cb, user_data]() {
        if (cb) cb(user_data);
    });
}

// `.onTapGesture`: a QObject event filter that fires the C callback on the Nth-equivalent click. eventFilter
// is a plain virtual override, so no Q_OBJECT/moc is needed (consistent with the lambda-based connects).
namespace {
class HopTapFilter : public QObject {
public:
    int count; hopqt_void_cb cb; void *user_data;
    HopTapFilter(int c, hopqt_void_cb f, void *d) : count(c), cb(f), user_data(d) {}
    bool eventFilter(QObject *, QEvent *ev) override {
        QEvent::Type want = (count >= 2) ? QEvent::MouseButtonDblClick : QEvent::MouseButtonRelease;
        if (ev->type() == want && cb) cb(user_data);
        return false;  // don't consume — let the widget handle it too
    }
};
}

void *hopqt_tap_install(void *widget, int count, hopqt_void_cb cb, void *user_data) {
    QWidget *w = static_cast<QWidget *>(widget);
    HopTapFilter *filter = new HopTapFilter(count, cb, user_data);
    w->installEventFilter(filter);
    return filter;
}

void hopqt_tap_remove(void *widget, void *filter) {
    if (!filter) return;
    static_cast<QWidget *>(widget)->removeEventFilter(static_cast<HopTapFilter *>(filter));
    static_cast<HopTapFilter *>(filter)->deleteLater();
}

void *hopqt_lineedit_new(const char *placeholder) {
    QLineEdit *e = new QLineEdit();
    e->setPlaceholderText(QString::fromUtf8(placeholder));
    e->setMinimumWidth(200);
    return e;
}

void hopqt_lineedit_set_text(void *edit, const char *text) {
    static_cast<QLineEdit *>(edit)->setText(QString::fromUtf8(text));
}

void hopqt_lineedit_set_placeholder(void *edit, const char *text) {
    static_cast<QLineEdit *>(edit)->setPlaceholderText(QString::fromUtf8(text));
}

const char *hopqt_lineedit_text(void *edit) {
    // Valid until the next call; sufficient for the reconciler's immediate equality check.
    static std::string buffer;
    buffer = static_cast<QLineEdit *>(edit)->text().toStdString();
    return buffer.c_str();
}

void hopqt_lineedit_connect(void *edit, hopqt_text_cb cb, void *user_data) {
    QLineEdit *e = static_cast<QLineEdit *>(edit);
    QObject::connect(e, &QLineEdit::textChanged, e, [cb, user_data](const QString &text) {
        if (cb) {
            std::string s = text.toStdString();
            cb(s.c_str(), user_data);
        }
    });
}

// QSlider works in integers, which suits the integer-backed demo state; we round across the bridge.

void *hopqt_slider_new(double min, double max) {
    QSlider *s = new QSlider(Qt::Horizontal);
    s->setRange((int)min, (int)max);
    s->setMinimumWidth(200);
    return s;
}

void hopqt_slider_set_range(void *slider, double min, double max) {
    static_cast<QSlider *>(slider)->setRange((int)min, (int)max);
}

void hopqt_slider_set_value(void *slider, double value) {
    QSlider *s = static_cast<QSlider *>(slider);
    int iv = (int)std::llround(value);
    if (s->value() != iv) s->setValue(iv);  // guard against feedback loops
}

double hopqt_slider_value(void *slider) {
    return (double)static_cast<QSlider *>(slider)->value();
}

void hopqt_slider_connect(void *slider, hopqt_double_cb cb, void *user_data) {
    QSlider *s = static_cast<QSlider *>(slider);
    QObject::connect(s, &QSlider::valueChanged, s, [cb, user_data](int v) {
        if (cb) cb((double)v, user_data);
    });
}

void *hopqt_datetime_new(void) {
    QDateTimeEdit *e = new QDateTimeEdit();
    e->setCalendarPopup(true);   // a compact field with a drop-down calendar
    return e;
}

void hopqt_datetime_set_components(void *edit, int want_date, int want_time) {
    QDateTimeEdit *e = static_cast<QDateTimeEdit *>(edit);
    QString fmt;
    if (want_date) fmt += "yyyy-MM-dd";
    if (want_date && want_time) fmt += " ";
    if (want_time) fmt += "HH:mm";
    if (fmt.isEmpty()) fmt = "yyyy-MM-dd";
    e->setDisplayFormat(fmt);
}

void hopqt_datetime_set(void *edit, double unix_seconds) {
    QDateTimeEdit *e = static_cast<QDateTimeEdit *>(edit);
    QDateTime target = QDateTime::fromSecsSinceEpoch((qint64)unix_seconds);
    if (e->dateTime() != target) {
        QSignalBlocker block(e);   // programmatic set must not re-fire dateTimeChanged
        e->setDateTime(target);
    }
}

double hopqt_datetime_get(void *edit) {
    return (double)static_cast<QDateTimeEdit *>(edit)->dateTime().toSecsSinceEpoch();
}

void hopqt_datetime_set_range(void *edit, int has_min, double min_unix, int has_max, double max_unix) {
    QDateTimeEdit *e = static_cast<QDateTimeEdit *>(edit);
    if (has_min) e->setMinimumDateTime(QDateTime::fromSecsSinceEpoch((qint64)min_unix));
    else e->clearMinimumDateTime();
    if (has_max) e->setMaximumDateTime(QDateTime::fromSecsSinceEpoch((qint64)max_unix));
    else e->clearMaximumDateTime();
}

void hopqt_datetime_connect(void *edit, hopqt_double_cb cb, void *user_data) {
    QDateTimeEdit *e = static_cast<QDateTimeEdit *>(edit);
    QObject::connect(e, &QDateTimeEdit::dateTimeChanged, e, [cb, user_data](const QDateTime &v) {
        if (cb) cb((double)v.toSecsSinceEpoch(), user_data);
    });
}

// A swatch button that opens a QColorDialog on click. The chosen color is painted on the button and
// reported via the registered callback; programmatic set never opens the dialog or fires the callback.
class HopColorWell : public QPushButton {
public:
    QColor color = QColor(0, 0, 0);
    bool supportsAlpha = true;
    hopqt_color_cb cb = nullptr;
    void *userData = nullptr;
    HopColorWell() {
        setMinimumWidth(60);
        QObject::connect(this, &QPushButton::clicked, this, [this]() {
            QColorDialog::ColorDialogOptions opts;
            if (supportsAlpha) opts |= QColorDialog::ShowAlphaChannel;
            QColor picked = QColorDialog::getColor(color, this, QString(), opts);
            if (picked.isValid()) {
                color = picked;
                applyColor();
                if (cb) cb(color.redF(), color.greenF(), color.blueF(), color.alphaF(), userData);
            }
        });
    }
    void applyColor() {
        setStyleSheet(QString("background-color: rgba(%1,%2,%3,%4); border: 1px solid gray; min-height: 18px;")
                          .arg(color.red()).arg(color.green()).arg(color.blue()).arg(color.alphaF()));
    }
};

void *hopqt_colorwell_new(void) {
    HopColorWell *w = new HopColorWell();
    w->applyColor();
    return w;
}

void hopqt_colorwell_set(void *btn, double r, double g, double b, double a) {
    HopColorWell *w = static_cast<HopColorWell *>(btn);
    QColor c;
    c.setRgbF((float)r, (float)g, (float)b, (float)a);
    if (w->color != c) { w->color = c; w->applyColor(); }
}

void hopqt_colorwell_set_alpha(void *btn, int support_alpha) {
    static_cast<HopColorWell *>(btn)->supportsAlpha = support_alpha != 0;
}

double hopqt_colorwell_red(void *btn)   { return static_cast<HopColorWell *>(btn)->color.redF(); }
double hopqt_colorwell_green(void *btn) { return static_cast<HopColorWell *>(btn)->color.greenF(); }
double hopqt_colorwell_blue(void *btn)  { return static_cast<HopColorWell *>(btn)->color.blueF(); }
double hopqt_colorwell_alpha(void *btn) { return static_cast<HopColorWell *>(btn)->color.alphaF(); }

void hopqt_colorwell_connect(void *btn, hopqt_color_cb cb, void *user_data) {
    HopColorWell *w = static_cast<HopColorWell *>(btn);
    w->cb = cb;
    w->userData = user_data;
}

char *hopqt_file_open(void *widget, int multiple, const char *filter) {
    QWidget *parent = widget ? static_cast<QWidget *>(widget)->window() : nullptr;
    QString f = filter ? QString::fromUtf8(filter) : QString();
    if (multiple) {
        QStringList files = QFileDialog::getOpenFileNames(parent, QStringLiteral("Open"), QString(), f);
        if (files.isEmpty()) return nullptr;
        return strdup(files.join(QChar('\n')).toUtf8().constData());
    }
    QString file = QFileDialog::getOpenFileName(parent, QStringLiteral("Open"), QString(), f);
    if (file.isEmpty()) return nullptr;
    return strdup(file.toUtf8().constData());
}

char *hopqt_file_save(void *widget, const char *default_name, const char *filter) {
    QWidget *parent = widget ? static_cast<QWidget *>(widget)->window() : nullptr;
    QString f = filter ? QString::fromUtf8(filter) : QString();
    QString dir = (default_name && default_name[0]) ? QString::fromUtf8(default_name) : QString();
    QString file = QFileDialog::getSaveFileName(parent, QStringLiteral("Save"), dir, f);
    if (file.isEmpty()) return nullptr;
    return strdup(file.toUtf8().constData());
}

void *hopqt_splitter_new(void) {
    QSplitter *s = new QSplitter(Qt::Horizontal);
    s->setChildrenCollapsible(false);
    s->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    return s;
}

void hopqt_splitter_add(void *splitter, void *child) {
    static_cast<QSplitter *>(splitter)->addWidget(static_cast<QWidget *>(child));
}

void hopqt_splitter_set_sizes(void *splitter, int first, int second) {
    QSplitter *s = static_cast<QSplitter *>(splitter);
    s->setStretchFactor(0, 0);  // sidebar holds its width
    s->setStretchFactor(1, 1);  // detail absorbs resizing
    QList<int> sizes;
    sizes << first << second;
    // Apply once the splitter has a real width (a pre-show setSizes is recomputed from size hints).
    QTimer::singleShot(0, s, [s, sizes]() { s->setSizes(sizes); });
}

// --- Custom shapes (QWidget + QPainter + QPainterPath) ----------------------

void *hopqt_shape_new(hopqt_paint_cb cb, void *user_data) {
    HopShapeWidget *w = new HopShapeWidget();
    w->paintCallback = cb;
    w->userData = user_data;
    return w;
}

void hopqt_shape_update(void *widget) {
    static_cast<QWidget *>(widget)->update();
}

void hopqt_widget_set_fixed_size(void *widget, int width, int height) {
    QWidget *w = static_cast<QWidget *>(widget);
    if (width >= 0) w->setFixedWidth(width);
    if (height >= 0) w->setFixedHeight(height);
}

// --- Framework-owned layout (absolute positioning) -------------------------

void *hopqt_fixed_new(void) {
    return new HopFixedWidget();
}

void hopqt_fixed_add(void *parent, void *child) {
    QWidget *c = static_cast<QWidget *>(child);
    c->setParent(static_cast<QWidget *>(parent));
    c->show();  // a reparented child starts hidden; the engine then positions it
}

void hopqt_fixed_remove(void *child) {
    static_cast<QWidget *>(child)->setParent(nullptr);
}

void hopqt_fixed_connect_resize(void *fixed, hopqt_resize_cb cb, void *user_data) {
    HopFixedWidget *w = static_cast<HopFixedWidget *>(fixed);
    w->resizeCallback = cb;
    w->resizeUserData = user_data;
}

void hopqt_widget_set_geometry(void *widget, int x, int y, int width, int height) {
    static_cast<QWidget *>(widget)->setGeometry(x, y, width, height);
}

void hopqt_widget_resize(void *widget, int width, int height) {
    static_cast<QWidget *>(widget)->resize(width, height);  // no position — QScrollArea owns it (preserves scroll)
}

// --- Scroll area (real clipping/scrolling viewport for ScrollView) ----------

void *hopqt_scrollarea_new(void) {
    QScrollArea *a = new QScrollArea();
    a->setWidgetResizable(false);  // the engine sizes the content; the area scrolls it
    a->setFrameShape(QFrame::NoFrame);
    a->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    a->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    return a;
}

void hopqt_scrollarea_set_content(void *area, void *widget) {
    static_cast<QScrollArea *>(area)->setWidget(static_cast<QWidget *>(widget));
}

void hopqt_scrollarea_offset(void *area, int *out_x, int *out_y) {
    QScrollArea *a = static_cast<QScrollArea *>(area);
    *out_x = a->horizontalScrollBar()->value();
    *out_y = a->verticalScrollBar()->value();
}

void hopqt_scrollarea_connect_scroll(void *area, hopqt_resize_cb cb, void *user_data) {
    QScrollArea *a = static_cast<QScrollArea *>(area);
    auto fire = [a, cb, user_data]() {
        if (cb) cb(a->horizontalScrollBar()->value(), a->verticalScrollBar()->value(), user_data);
    };
    QObject::connect(a->verticalScrollBar(), &QScrollBar::valueChanged, a, [fire](int) { fire(); });
    QObject::connect(a->horizontalScrollBar(), &QScrollBar::valueChanged, a, [fire](int) { fire(); });
}

void hopqt_widget_size_hint(void *widget, int *out_w, int *out_h) {
    QSize s = static_cast<QWidget *>(widget)->sizeHint();
    *out_w = s.width();
    *out_h = s.height();
}

void hopqt_widget_size(void *widget, int *out_w, int *out_h) {
    QSize s = static_cast<QWidget *>(widget)->size();
    *out_w = s.width();
    *out_h = s.height();
}

void hopqt_painter_save(void *painter) { static_cast<QPainter *>(painter)->save(); }
void hopqt_painter_restore(void *painter) { static_cast<QPainter *>(painter)->restore(); }
void hopqt_painter_translate(void *painter, double dx, double dy) {
    static_cast<QPainter *>(painter)->translate(dx, dy);
}
void hopqt_painter_rotate(void *painter, double degrees) {
    static_cast<QPainter *>(painter)->rotate(degrees);
}
void hopqt_painter_scale(void *painter, double sx, double sy) {
    static_cast<QPainter *>(painter)->scale(sx, sy);
}

void hopqt_painter_fill_path(void *painter, void *path, double r, double g, double b, double a) {
    QColor color;
    color.setRgbF(r, g, b, a);
    static_cast<QPainter *>(painter)->fillPath(*static_cast<QPainterPath *>(path), QBrush(color));
}

void hopqt_painter_stroke_path(void *painter, void *path, double r, double g, double b, double a, double width) {
    QColor color;
    color.setRgbF(r, g, b, a);
    QPen pen(color);
    pen.setWidthF(width);
    pen.setJoinStyle(Qt::RoundJoin);
    QPainter *p = static_cast<QPainter *>(painter);
    p->strokePath(*static_cast<QPainterPath *>(path), pen);
}

void *hopqt_path_new(void) { return new QPainterPath(); }
void hopqt_path_free(void *path) { delete static_cast<QPainterPath *>(path); }
void hopqt_path_move_to(void *path, double x, double y) { static_cast<QPainterPath *>(path)->moveTo(x, y); }
void hopqt_path_line_to(void *path, double x, double y) { static_cast<QPainterPath *>(path)->lineTo(x, y); }
void hopqt_path_cubic_to(void *path, double c1x, double c1y, double c2x, double c2y, double x, double y) {
    static_cast<QPainterPath *>(path)->cubicTo(c1x, c1y, c2x, c2y, x, y);
}
void hopqt_path_quad_to(void *path, double cx, double cy, double x, double y) {
    static_cast<QPainterPath *>(path)->quadTo(cx, cy, x, y);
}
void hopqt_path_close(void *path) { static_cast<QPainterPath *>(path)->closeSubpath(); }
void hopqt_path_add_rect(void *path, double x, double y, double w, double h) {
    static_cast<QPainterPath *>(path)->addRect(x, y, w, h);
}
void hopqt_path_add_rounded_rect(void *path, double x, double y, double w, double h, double rx, double ry) {
    static_cast<QPainterPath *>(path)->addRoundedRect(x, y, w, h, rx, ry);
}
void hopqt_path_add_ellipse(void *path, double x, double y, double w, double h) {
    static_cast<QPainterPath *>(path)->addEllipse(x, y, w, h);
}
void hopqt_path_add_arc(void *path, double cx, double cy, double r, double start_rad, double end_rad, int clockwise) {
    QPainterPath *p = static_cast<QPainterPath *>(path);
    QRectF rect(cx - r, cy - r, 2 * r, 2 * r);
    // Qt angles are CCW-positive and degrees; our angles (like CoreGraphics/Cairo) increase clockwise
    // in the y-down space, so negate. A counterclockwise arc sweeps the complementary direction.
    double startDeg = -start_rad * 180.0 / M_PI;
    double sweepDeg = -(end_rad - start_rad) * 180.0 / M_PI;
    if (clockwise == 0) sweepDeg = (sweepDeg < 0) ? sweepDeg + 360.0 : sweepDeg - 360.0;
    if (p->elementCount() == 0) p->arcMoveTo(rect, startDeg);
    p->arcTo(rect, startDeg, sweepDeg);
}

// --- Drop-down menu button (QPushButton + QMenu) ----------------------------

void *hopqt_menubutton_new(const char *label) {
    QPushButton *button = new QPushButton(QString::fromUtf8(label));
    QMenu *menu = new QMenu(button);
    button->setMenu(menu);  // QPushButton shows a menu indicator and pops the menu on click
    return button;
}

void *hopqt_menubutton_menu(void *button) {
    return static_cast<QPushButton *>(button)->menu();
}

void *hopqt_menu_add_submenu(void *menu, const char *title) {
    return static_cast<QMenu *>(menu)->addMenu(QString::fromUtf8(title));
}

void hopqt_menu_clear(void *menu) {
    static_cast<QMenu *>(menu)->clear();
}

// --- Separator (Divider) ----------------------------------------------------

void *hopqt_separator_new(void) {
    QFrame *frame = new QFrame();
    frame->setFrameShape(QFrame::HLine);
    frame->setFrameShadow(QFrame::Sunken);
    return frame;
}

// --- Offscreen raster rendering (QImage + QPainter) -------------------------

void *hopqt_image_new(int width, int height) {
    QImage *image = new QImage(width, height, QImage::Format_ARGB32);
    image->fill(Qt::white);
    return image;
}

void hopqt_image_free(void *image) {
    delete static_cast<QImage *>(image);
}

void *hopqt_image_begin(void *image) {
    QPainter *painter = new QPainter(static_cast<QImage *>(image));
    painter->setRenderHint(QPainter::Antialiasing, true);
    return painter;
}

void hopqt_image_end(void *painter) {
    QPainter *p = static_cast<QPainter *>(painter);
    p->end();
    delete p;
}

unsigned hopqt_image_pixel(void *image, int x, int y) {
    return static_cast<QImage *>(image)->pixel(x, y);  // 0xAARRGGBB
}

int hopqt_image_save_png(void *image, const char *path) {
    return static_cast<QImage *>(image)->save(QString::fromUtf8(path), "PNG") ? 1 : 0;
}

void *hopqt_progress_new(void) {
    QProgressBar *bar = new QProgressBar();
    bar->setMinimumWidth(240);
    bar->setTextVisible(false);
    return bar;
}

void hopqt_progress_set_fraction(void *bar, double fraction) {
    QProgressBar *b = static_cast<QProgressBar *>(bar);
    b->setRange(0, 1000);
    b->setValue((int)(fraction * 1000.0));
}

void hopqt_progress_set_indeterminate(void *bar) {
    // A 0–0 range makes QProgressBar render an animated "busy" indicator.
    static_cast<QProgressBar *>(bar)->setRange(0, 0);
}

// --- Selection drop-down (QComboBox) ----------------------------------------

void *hopqt_combo_new(void) {
    return new QComboBox();
}

void hopqt_combo_set_items(void *combo, int count, hopqt_row_cb row_cb, void *user_data) {
    QComboBox *c = static_cast<QComboBox *>(combo);
    QSignalBlocker block(c);  // don't emit currentIndexChanged while rebuilding
    c->clear();
    for (int i = 0; i < count; i++) {
        char *s = row_cb ? row_cb(i, user_data) : nullptr;
        c->addItem(QString::fromUtf8(s ? s : ""));
        if (s) free(s);
    }
}

int hopqt_combo_selected(void *combo) {
    return static_cast<QComboBox *>(combo)->currentIndex();
}

void hopqt_combo_set_selected(void *combo, int index) {
    QComboBox *c = static_cast<QComboBox *>(combo);
    QSignalBlocker block(c);  // setting selection programmatically must not re-fire the callback
    c->setCurrentIndex(index);
}

void hopqt_combo_connect(void *combo, hopqt_int_cb cb, void *user_data) {
    QComboBox *c = static_cast<QComboBox *>(combo);
    QObject::connect(c, QOverload<int>::of(&QComboBox::currentIndexChanged), c,
                     [cb, user_data](int index) { if (cb) cb(index, user_data); });
}

void *hopqt_list_new(void) {
    QListView *v = new QListView();
    v->setUniformItemSizes(true);  // big perf win for large, fixed-height rows
    v->setMinimumWidth(180);       // fills its split pane
    v->setSelectionMode(QAbstractItemView::SingleSelection);
    return v;
}

// Qt has no native source list. On this Qt/macOS build, applying ANY stylesheet to a QListView — or
// removing its frame — makes it stop painting the viewport background (it renders black), and stylesheet
// `palette(base)`/`palette(window)` both resolve to black, so there's no reliable way to give Qt the
// source-list look. It therefore keeps the default (light, bordered) list; AppKit and GTK get the full
// sidebar treatment. Kept as a no-op hook in case a future Qt makes this safe.
void hopqt_list_set_sidebar(void *list, int sidebar) {
    (void)list; (void)sidebar;
}

void hopqt_list_set_model(void *list, int count, hopqt_row_cb row_cb, void *user_data) {
    QListView *v = static_cast<QListView *>(list);
    HopListModel *model = new HopListModel();
    model->rowCountValue = count;
    model->rowCallback = row_cb;
    model->userData = user_data;
    QAbstractItemModel *old = v->model();
    v->setModel(model);
    model->setParent(v);
    if (old) old->deleteLater();
}

void hopqt_list_connect_selection(void *list, hopqt_int_cb cb, void *user_data) {
    QListView *v = static_cast<QListView *>(list);
    QObject::connect(v->selectionModel(), &QItemSelectionModel::currentRowChanged, v,
        [cb, user_data](const QModelIndex &current, const QModelIndex &) {
            if (cb) cb(current.isValid() ? current.row() : -1, user_data);
        });
}

int hopqt_list_selected(void *list) {
    QModelIndex idx = static_cast<QListView *>(list)->currentIndex();
    return idx.isValid() ? idx.row() : -1;
}

void hopqt_list_set_selected(void *list, int index) {
    QListView *v = static_cast<QListView *>(list);
    if (index < 0) {
        v->clearSelection();
        v->setCurrentIndex(QModelIndex());
    } else {
        v->setCurrentIndex(v->model()->index(index, 0));
    }
}

// --- Tree (OutlineGroup: QTreeWidget) ---------------------------------------
//
// The native QTreeWidget owns its item model. Swift describes the tree as a pre-order flattened list of
// (title, key, depth) rows; the shim rebuilds the nested QTreeWidgetItems from `depth`, stashing each
// row's key in the item's UserRole. Selection is reported and set by key (the QTreeWidget object is
// stable across rebuilds, so the selection signal is connected once).

void *hopqt_tree_new(void) {
    QTreeWidget *t = new QTreeWidget();
    t->setHeaderHidden(true);
    t->setColumnCount(1);
    t->setUniformRowHeights(true);
    t->setSelectionMode(QAbstractItemView::SingleSelection);
    t->setMinimumWidth(180);
    return t;
}

void hopqt_tree_set_sidebar(void *tree, int sidebar) {
    QTreeWidget *t = static_cast<QTreeWidget *>(tree);
    t->setFrameShape(sidebar ? QFrame::NoFrame : QFrame::StyledPanel);
}

void hopqt_tree_set_rows(void *tree, int count, hopqt_row_cb title_cb, hopqt_row_cb key_cb,
                         hopqt_intret_cb depth_cb, hopqt_intret_cb selectable_cb, void *user_data) {
    QTreeWidget *t = static_cast<QTreeWidget *>(tree);
    QSignalBlocker block(t);  // don't fire selection signals while rebuilding
    t->clear();
    bool anyHeader = false;
    QTreeWidgetItem *stack[64];
    for (int i = 0; i < 64; i++) stack[i] = nullptr;
    for (int i = 0; i < count; i++) {
        int depth = depth_cb ? depth_cb(i, user_data) : 0;
        if (depth < 0) depth = 0;
        if (depth > 62) depth = 62;
        char *title = title_cb ? title_cb(i, user_data) : nullptr;
        char *key = key_cb ? key_cb(i, user_data) : nullptr;
        int selectable = selectable_cb ? selectable_cb(i, user_data) : 1;
        QTreeWidgetItem *item = new QTreeWidgetItem();
        item->setText(0, QString::fromUtf8(title ? title : ""));
        if (key) item->setData(0, Qt::UserRole, QString::fromUtf8(key));
        if (!selectable) {
            // Section header: make it unselectable and bold so the tree reads as a sectioned list.
            item->setFlags(item->flags() & ~Qt::ItemIsSelectable);
            QFont f = item->font(0); f.setBold(true); item->setFont(0, f);
            anyHeader = true;
        }
        if (depth == 0 || stack[depth - 1] == nullptr) {
            t->addTopLevelItem(item);
        } else {
            stack[depth - 1]->addChild(item);
        }
        stack[depth] = item;
        if (title) free(title);
        if (key) free(key);
    }
    t->setRootIsDecorated(anyHeader ? false : true);  // sectioned list: drop the tree disclosure triangles
    t->expandAll();
}

void hopqt_tree_connect_selection(void *tree, hopqt_str_cb cb, void *user_data) {
    QTreeWidget *t = static_cast<QTreeWidget *>(tree);
    // Report selection on genuine clicks only. `currentItemChanged` also fires on focus/show and
    // programmatic `setCurrentItem`, which would spuriously overwrite the bound selection; `itemClicked`
    // fires solely for user clicks on a row (not the expand triangle), so the binding stays authoritative.
    QObject::connect(t, &QTreeWidget::itemClicked, t,
        [cb, user_data](QTreeWidgetItem *item, int) {
            if (!cb) return;
            if (!item) { cb(nullptr, user_data); return; }
            QString key = item->data(0, Qt::UserRole).toString();
            if (key.isNull()) { cb(nullptr, user_data); return; }
            QByteArray utf8 = key.toUtf8();
            cb(utf8.constData(), user_data);
        });
}

char *hopqt_tree_selected_key(void *tree) {
    QTreeWidget *t = static_cast<QTreeWidget *>(tree);
    QTreeWidgetItem *item = t->currentItem();
    if (!item || !item->isSelected()) return nullptr;
    QString key = item->data(0, Qt::UserRole).toString();
    if (key.isNull()) return nullptr;
    return strdup(key.toUtf8().constData());
}

void hopqt_tree_select_key(void *tree, const char *key) {
    QTreeWidget *t = static_cast<QTreeWidget *>(tree);
    if (!key) {
        t->clearSelection();
        t->setCurrentItem(nullptr);
        return;
    }
    QString want = QString::fromUtf8(key);
    QTreeWidgetItemIterator it(t);
    while (*it) {
        if ((*it)->data(0, Qt::UserRole).toString() == want) {
            t->setCurrentItem(*it);
            return;
        }
        ++it;
    }
    t->clearSelection();
    t->setCurrentItem(nullptr);
}

// --- Image (a QWidget painting a QPixmap with the right aspect mode) ---------

class HopImageWidget : public QWidget {
public:
    QPixmap pixmap;
    bool resizable = false;
    int mode = 0;  // 0=stretch 1=fit 2=fill
    QSize naturalSize() const { return pixmap.isNull() ? QSize(24, 24) : pixmap.size(); }
protected:
    void paintEvent(QPaintEvent *) override {
        if (pixmap.isNull()) return;
        QPainter p(this);
        p.setRenderHint(QPainter::SmoothPixmapTransform, true);
        QRect bounds = rect();
        auto centered = [&](QSize s) {
            return QRect(bounds.center().x() - s.width() / 2, bounds.center().y() - s.height() / 2,
                         s.width(), s.height());
        };
        if (!resizable) {
            p.drawPixmap(centered(pixmap.size()), pixmap);
        } else if (mode == 0) {
            p.drawPixmap(bounds, pixmap);  // stretch
        } else if (mode == 1) {
            p.drawPixmap(centered(pixmap.size().scaled(bounds.size(), Qt::KeepAspectRatio)), pixmap);  // fit
        } else {
            p.setClipRect(bounds);  // fill (cover + clip)
            p.drawPixmap(centered(pixmap.size().scaled(bounds.size(), Qt::KeepAspectRatioByExpanding)), pixmap);
        }
    }
};

void *hopqt_imageview_new(void) { return new HopImageWidget(); }

void hopqt_imageview_set_file(void *view, const char *path) {
    HopImageWidget *w = static_cast<HopImageWidget *>(view);
    w->pixmap.load(QString::fromUtf8(path));
    w->update();
}

void hopqt_imageview_set_data(void *view, const unsigned char *data, int len) {
    HopImageWidget *w = static_cast<HopImageWidget *>(view);
    QPixmap pm;
    pm.loadFromData(data, (uint)len);
    w->pixmap = pm;
    w->update();
}

void hopqt_imageview_set_icon(void *view, const char *name) {
    HopImageWidget *w = static_cast<HopImageWidget *>(view);
    QIcon icon = QIcon::fromTheme(QString::fromUtf8(name));
    if (icon.isNull()) icon = QIcon::fromTheme(QStringLiteral("image-x-generic"));
    w->pixmap = icon.pixmap(64, 64);
    w->update();
}

void hopqt_imageview_set_mode(void *view, int resizable, int mode) {
    HopImageWidget *w = static_cast<HopImageWidget *>(view);
    w->resizable = (resizable != 0);
    w->mode = mode;
    w->update();
}

void hopqt_image_natural_size(void *view, int *out_w, int *out_h) {
    QSize s = static_cast<HopImageWidget *>(view)->naturalSize();
    *out_w = s.width();
    *out_h = s.height();
}

// --- Switch (Toggle: QCheckBox) + password line edit (SecureField) ----------

void *hopqt_switch_new(void) { return new QCheckBox(); }

void hopqt_switch_set_checked(void *box, int on) {
    QCheckBox *cb = static_cast<QCheckBox *>(box);
    QSignalBlocker block(cb);  // don't re-fire toggled for the state we're reflecting
    cb->setChecked(on != 0);
}

int hopqt_switch_checked(void *box) {
    return static_cast<QCheckBox *>(box)->isChecked() ? 1 : 0;
}

void hopqt_switch_connect(void *box, hopqt_int_cb cb, void *user_data) {
    QCheckBox *checkbox = static_cast<QCheckBox *>(box);
    QObject::connect(checkbox, &QCheckBox::toggled, checkbox,
                     [cb, user_data](bool on) { if (cb) cb(on ? 1 : 0, user_data); });
}

void hopqt_lineedit_set_password(void *lineedit, int on) {
    static_cast<QLineEdit *>(lineedit)->setEchoMode(on ? QLineEdit::Password : QLineEdit::Normal);
}

// --- Tabbed container (TabView: QTabWidget) ---------------------------------

void *hopqt_tabwidget_new(void) { return new QTabWidget(); }

void hopqt_tabwidget_add(void *tabs, void *page, const char *label) {
    static_cast<QTabWidget *>(tabs)->addTab(static_cast<QWidget *>(page), QString::fromUtf8(label));
}

void hopqt_tabwidget_set_tab_text(void *tabs, int index, const char *label) {
    QTabWidget *tw = static_cast<QTabWidget *>(tabs);
    if (index >= 0 && index < tw->count()) tw->setTabText(index, QString::fromUtf8(label));
}

void hopqt_tabwidget_set_current(void *tabs, int index) {
    static_cast<QTabWidget *>(tabs)->setCurrentIndex(index);
}

int hopqt_tabwidget_current(void *tabs) {
    return static_cast<QTabWidget *>(tabs)->currentIndex();
}

void hopqt_tabwidget_connect(void *tabs, hopqt_int_cb cb, void *user_data) {
    QTabWidget *tw = static_cast<QTabWidget *>(tabs);
    QObject::connect(tw, &QTabWidget::currentChanged, tw,
                     [cb, user_data](int index) { if (cb) cb(index, user_data); });
}

void hopqt_tabwidget_remove(void *tabs, void *page) {
    QTabWidget *tw = static_cast<QTabWidget *>(tabs);
    int index = tw->indexOf(static_cast<QWidget *>(page));
    if (index >= 0) tw->removeTab(index);
}

} // extern "C"

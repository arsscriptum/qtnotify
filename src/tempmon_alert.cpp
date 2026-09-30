/*
 * tempmon_alert.cpp
 *
 * Small Qt5 GUI app that pops a critical message box for a temperature
 * alert. Meant to be called by tempmon.sh in addition to (or instead of)
 * the wall broadcast, when a graphical session is actually available to
 * render into.
 *
 * Build (Ubuntu, Qt5, no moc needed since there is no QObject subclass):
 *   sudo apt-get install -y qtbase5-dev
 *   g++ -std=c++17 -fPIC $(pkg-config --cflags Qt5Widgets) \
 *       -o tempmon_alert tempmon_alert.cpp $(pkg-config --libs Qt5Widgets)
 *
 * Usage:
 *   ./tempmon_alert <temp_c> <threshold_c> [hostname]
 *
 * Example:
 *   ./tempmon_alert 82.4 75 delta
 *
 * Requires DISPLAY (and usually XAUTHORITY) pointed at a real X session.
 * A headless server with no logged-in graphical session has nowhere to
 * render this, wall stays the right mechanism there. See tempmon.sh for
 * how to detect an active session and target it from a root-run service.
 */

#include <QApplication>
#include <QMessageBox>
#include <QAbstractButton>
#include <QString>
#include <cstdio>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QString temp;
    QString threshold;
    QString host;
    QString message;
    QMessageBox box;

    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <temp_c> <threshold_c> [hostname]\n", argv[0]);
        return 1;
    }

    temp = argv[1];
    threshold = argv[2];
    host = (argc >= 4) ? QString(argv[3]) : QString("localhost");

    message = QString("CPU temperature %1 C exceeds threshold %2 C on %3").arg(temp, threshold, host);

    box.setIcon(QMessageBox::NoIcon);
    box.setWindowTitle("TEMPERATURE ALERT");
    box.setText(message);
    box.setStandardButtons(QMessageBox::Ok);
    box.button(QMessageBox::Ok)->setText("GOT IT");
    box.setStyleSheet(
        "QMessageBox { background-color: #cc2222; }"
        "QLabel { color: #ffffff; font-weight: bold; font-size: 14px; }"
        "QPushButton { background-color: #7a1414; color: #ffffff; padding: 6px 22px; "
        "border-radius: 3px; border: 1px solid #4a0c0c; }"
        "QPushButton:hover { background-color: #931919; }"
    );

    box.exec();

    return 0;
}

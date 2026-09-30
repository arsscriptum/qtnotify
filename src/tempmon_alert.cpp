/*
 * tempmon_alert.cpp  --  qtnotify
 *
 * Small Qt5 GUI app that pops a critical message box for a temperature
 * alert. Meant to be called by tempmon.sh (see the tempmonitor.pi5
 * project) in addition to (or instead of) the wall broadcast, when a
 * graphical session is actually available to render into.
 *
 * There is no QObject subclass here, so no moc pass is needed. The only
 * generated source is the Qt resource file for the window icon, produced
 * by rcc from assets/qtnotify.qrc, and that is optional: without it the
 * dialog simply carries no icon.
 *
 * Build (from the top of the project):
 *   sudo apt-get install -y build-essential qtbase5-dev
 *   make
 *
 * Usage:
 *   qtnotify [options] <temp_c> <threshold_c> [hostname]
 *
 * Examples:
 *   qtnotify 82.4 75 delta                 alert, waits for the user
 *   qtnotify --timeout 60 82.4 75 delta    alert, self dismisses after 60s
 *   qtnotify --normal 71.2 75 delta        recovery notice, green
 *   qtnotify --dry-run 82.4 75 delta       print the message, no GUI
 *
 * Exit codes:
 *   0   message acknowledged (or --dry-run / --help / --version)
 *   1   no display available, or the GUI could not be started
 *   2   usage error (bad or missing arguments)
 *   3   dialog closed by --timeout without being acknowledged
 *
 * Requires DISPLAY (and usually XAUTHORITY) pointed at a real X session,
 * or WAYLAND_DISPLAY for a wayland one. A headless server with no logged
 * in graphical session has nowhere to render this, wall stays the right
 * mechanism there. qtnotify-broadcast finds the active sessions on the
 * machine and runs this binary inside each of them.
 */

#include <QApplication>
#include <QMessageBox>
#include <QAbstractButton>
#include <QDateTime>
#include <QIcon>
#include <QPixmap>
#include <QString>
#include <QTimer>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define QTNOTIFY_NAME    "qtnotify"
#define QTNOTIFY_VERSION "1.0.0"

/* Exit codes, kept in sync with the header comment and tests/run_tests.sh. */
#define RC_ACK     0
#define RC_FAIL    1
#define RC_USAGE   2
#define RC_TIMEOUT 3

#define MAX_TIMEOUT_SEC 86400
#define MAX_FIELD_LEN   96

struct Options {
    QString temp;
    QString threshold;
    QString host;
    QString title;
    QString message;
    int     timeoutSec;
    bool    normal;
    bool    dryRun;

    Options() : host(QStringLiteral("localhost")), timeoutSec(0),
                normal(false), dryRun(false) {}
};

static void usage(FILE *out, const char *argv0)
{
    std::fprintf(out,
        "usage: %s [options] <temp_c> <threshold_c> [hostname]\n"
        "\n"
        "Pop a temperature alert dialog on the current graphical session.\n"
        "\n"
        "Options:\n"
        "  -t, --timeout SEC   close the dialog by itself after SEC seconds\n"
        "                      (0, the default, waits for the user), exit 3\n"
        "  -N, --normal        recovery notice (green) instead of an alert\n"
        "      --title TEXT    override the window title\n"
        "      --message TEXT  override the message body\n"
        "  -n, --dry-run       print the message to stdout, open no window\n"
        "  -h, --help          this help\n"
        "  -V, --version       version\n"
        "\n"
        "Exit codes: 0 acknowledged, 1 no display, 2 usage, 3 timed out.\n",
        argv0);
}

/* Plain decimal number, optionally signed: -12, 7, 82.4. Deliberately
 * hand rolled rather than QString::toDouble(), which also accepts hex,
 * exponents, thousands separators and surrounding whitespace. */
static bool isNumber(const QString &value)
{
    int i = 0;
    int digits = 0;
    bool dot = false;

    if (value.isEmpty()) {
        return false;
    }

    if (value.at(0) == QLatin1Char('+') || value.at(0) == QLatin1Char('-')) {
        i = 1;
    }

    for (; i < value.length(); ++i) {
        const QChar c = value.at(i);

        if (c.isDigit()) {
            ++digits;
        } else if (c == QLatin1Char('.') && !dot && digits > 0) {
            dot = true;
            digits = 0;
        } else {
            return false;
        }
    }

    return digits > 0;
}

/* Non-empty, not absurdly long, no control characters: these strings end
 * up in a window title and a label, and may come from a config file. */
static bool isPrintableField(const QString &value)
{
    if (value.isEmpty() || value.length() > MAX_FIELD_LEN) {
        return false;
    }

    for (int i = 0; i < value.length(); ++i) {
        if (!value.at(i).isPrint()) {
            return false;
        }
    }

    return true;
}

static bool parseTimeout(const QString &value, int *out)
{
    bool ok = false;
    const int seconds = value.toInt(&ok, 10);

    if (!ok || seconds < 0 || seconds > MAX_TIMEOUT_SEC) {
        return false;
    }

    *out = seconds;
    return true;
}

/* Returns the argument for an option, either from --opt=VALUE or from the
 * next argv slot. Advances *i past a consumed slot. */
static bool optionValue(int argc, char *argv[], int *i, const QString &arg,
                        QString *out)
{
    const int eq = arg.indexOf(QLatin1Char('='));

    if (eq >= 0) {
        *out = arg.mid(eq + 1);
        return !out->isEmpty();
    }

    if (*i + 1 >= argc) {
        return false;
    }

    *out = QString::fromLocal8Bit(argv[++(*i)]);
    return true;
}

/* Returns 0 to keep going, -1 when the whole job was done here (help,
 * version), or an exit code on a usage error. */
static int parseArgs(int argc, char *argv[], Options *opt)
{
    QStringList positional;
    bool noMoreOptions = false;
    QString value;

    for (int i = 1; i < argc; ++i) {
        const QString arg = QString::fromLocal8Bit(argv[i]);
        const QString name = arg.section(QLatin1Char('='), 0, 0);

        if (noMoreOptions || !arg.startsWith(QLatin1Char('-')) || arg == QLatin1String("-")) {
            positional << arg;
            continue;
        }

        if (arg == QLatin1String("--")) {
            noMoreOptions = true;
        } else if (name == QLatin1String("-h") || name == QLatin1String("--help")) {
            usage(stdout, QTNOTIFY_NAME);
            return -1;
        } else if (name == QLatin1String("-V") || name == QLatin1String("--version")) {
            std::printf("%s %s (Qt %s)\n", QTNOTIFY_NAME, QTNOTIFY_VERSION, qVersion());
            return -1;
        } else if (name == QLatin1String("-N") || name == QLatin1String("--normal")) {
            opt->normal = true;
        } else if (name == QLatin1String("-n") || name == QLatin1String("--dry-run")) {
            opt->dryRun = true;
        } else if (name == QLatin1String("-t") || name == QLatin1String("--timeout")) {
            if (!optionValue(argc, argv, &i, arg, &value)) {
                std::fprintf(stderr, "%s: %s needs a value in seconds\n",
                             QTNOTIFY_NAME, qPrintable(name));
                return RC_USAGE;
            }
            if (!parseTimeout(value, &opt->timeoutSec)) {
                std::fprintf(stderr, "%s: bad timeout '%s', expected 0..%d seconds\n",
                             QTNOTIFY_NAME, qPrintable(value), MAX_TIMEOUT_SEC);
                return RC_USAGE;
            }
        } else if (name == QLatin1String("--title")) {
            if (!optionValue(argc, argv, &i, arg, &opt->title)
                || !isPrintableField(opt->title)) {
                std::fprintf(stderr, "%s: --title needs printable text (1..%d chars)\n",
                             QTNOTIFY_NAME, MAX_FIELD_LEN);
                return RC_USAGE;
            }
        } else if (name == QLatin1String("--message")) {
            if (!optionValue(argc, argv, &i, arg, &opt->message)
                || opt->message.isEmpty()) {
                std::fprintf(stderr, "%s: --message needs text\n", QTNOTIFY_NAME);
                return RC_USAGE;
            }
        } else {
            std::fprintf(stderr, "%s: unknown option '%s'\n",
                         QTNOTIFY_NAME, qPrintable(arg));
            usage(stderr, QTNOTIFY_NAME);
            return RC_USAGE;
        }
    }

    if (positional.size() < 2) {
        std::fprintf(stderr, "%s: need <temp_c> and <threshold_c>\n", QTNOTIFY_NAME);
        usage(stderr, QTNOTIFY_NAME);
        return RC_USAGE;
    }

    if (positional.size() > 3) {
        std::fprintf(stderr, "%s: too many arguments (got %d, expected at most 3)\n",
                     QTNOTIFY_NAME, positional.size());
        usage(stderr, QTNOTIFY_NAME);
        return RC_USAGE;
    }

    opt->temp = positional.at(0);
    opt->threshold = positional.at(1);

    if (!isNumber(opt->temp)) {
        std::fprintf(stderr, "%s: temp_c '%s' is not a number\n",
                     QTNOTIFY_NAME, qPrintable(opt->temp));
        return RC_USAGE;
    }

    if (!isNumber(opt->threshold)) {
        std::fprintf(stderr, "%s: threshold_c '%s' is not a number\n",
                     QTNOTIFY_NAME, qPrintable(opt->threshold));
        return RC_USAGE;
    }

    if (positional.size() == 3) {
        opt->host = positional.at(2);
        if (!isPrintableField(opt->host)) {
            std::fprintf(stderr, "%s: hostname must be printable text (1..%d chars)\n",
                         QTNOTIFY_NAME, MAX_FIELD_LEN);
            return RC_USAGE;
        }
    }

    if (opt->title.isEmpty()) {
        opt->title = opt->normal ? QStringLiteral("TEMPERATURE NORMAL")
                                 : QStringLiteral("TEMPERATURE ALERT");
    }

    if (opt->message.isEmpty()) {
        opt->message = opt->normal
            ? QStringLiteral("CPU temperature %1 C is back under threshold %2 C on %3")
              .arg(opt->temp, opt->threshold, opt->host)
            : QStringLiteral("CPU temperature %1 C exceeds threshold %2 C on %3")
              .arg(opt->temp, opt->threshold, opt->host);
    }

    return 0;
}

/* Connect timeout for a remote DISPLAY, milliseconds. Short on purpose:
 * this runs in the alert path, a hung probe delays the warning. */
#define CONNECT_TIMEOUT_MS 2000

static bool connectWithTimeout(int fd, const struct sockaddr *addr, socklen_t len)
{
    struct pollfd pfd;
    int flags;
    int err = 0;
    socklen_t errLen = sizeof(err);

    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        return false;
    }

    if (::connect(fd, addr, len) == 0) {
        return true;
    }

    if (errno != EINPROGRESS) {
        return false;
    }

    pfd.fd = fd;
    pfd.events = POLLOUT;
    pfd.revents = 0;

    if (poll(&pfd, 1, CONNECT_TIMEOUT_MS) != 1) {
        return false;
    }

    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) < 0) {
        return false;
    }

    return err == 0;
}

/* AF_UNIX X socket, the normal local case: /tmp/.X11-unix/X<n>. */
static bool unixDisplayReachable(int number)
{
    struct sockaddr_un addr;
    const QByteArray path = QStringLiteral("/tmp/.X11-unix/X%1").arg(number).toLocal8Bit();
    bool ok;
    int fd;

    if (path.size() >= (int)sizeof(addr.sun_path)) {
        return false;
    }

    fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }

    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.constData(), sizeof(addr.sun_path) - 1);

    ok = connectWithTimeout(fd, (struct sockaddr *)&addr, sizeof(addr));
    ::close(fd);

    return ok;
}

/* Remote DISPLAY, X over TCP on port 6000 + display number. */
static bool tcpDisplayReachable(const QString &host, int number)
{
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    struct addrinfo *entry;
    bool ok = false;

    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    const QByteArray hostBytes = host.toLocal8Bit();
    const QByteArray portBytes = QString::number(6000 + number).toLocal8Bit();

    if (::getaddrinfo(hostBytes.constData(), portBytes.constData(), &hints, &result) != 0) {
        return false;
    }

    for (entry = result; entry != NULL && !ok; entry = entry->ai_next) {
        const int fd = ::socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (fd < 0) {
            continue;
        }
        ok = connectWithTimeout(fd, entry->ai_addr, entry->ai_addrlen);
        ::close(fd);
    }

    ::freeaddrinfo(result);
    return ok;
}

/* DISPLAY is [host][:unix]:<number>[.<screen>], e.g. ":0", ":0.0",
 * "localhost:10.0", "alpha:0.0", "pi.local/unix:0". */
static bool x11Reachable(const QString &display)
{
    const int colon = display.lastIndexOf(QLatin1Char(':'));
    if (colon < 0) {
        return false;
    }

    QString host = display.left(colon);
    QString number = display.mid(colon + 1).section(QLatin1Char('.'), 0, 0);
    bool ok = false;
    const int unit = number.toInt(&ok, 10);

    if (!ok || unit < 0) {
        return false;
    }

    /* "host/unix:0" and "unix:0" both mean the local socket. */
    if (host.endsWith(QLatin1String("/unix"))) {
        host.clear();
    }

    if (host.isEmpty() || host == QLatin1String("unix")) {
        return unixDisplayReachable(unit);
    }

    if (host == QLatin1String("localhost") && unixDisplayReachable(unit)) {
        return true;
    }

    return tcpDisplayReachable(host, unit);
}

static bool waylandReachable(const QString &display)
{
    struct stat st;
    QString path = display;

    if (!path.startsWith(QLatin1Char('/'))) {
        const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
        if (runtime.isEmpty()) {
            return false;
        }
        path = runtime + QLatin1Char('/') + display;
    }

    return ::stat(path.toLocal8Bit().constData(), &st) == 0;
}

/* Pre-flight check so a daemon calling us gets a clear error and exit 1
 * on stderr, instead of Qt's "could not connect to display" abort (which
 * shows up as a core dump and exit 134 in the service log). */
static bool displayAvailable(QString *reason)
{
    const QString platform = qEnvironmentVariable("QT_QPA_PLATFORM");
    const QString wayland = qEnvironmentVariable("WAYLAND_DISPLAY");
    const QString x11 = qEnvironmentVariable("DISPLAY");

    /* offscreen, minimal, linuxfb, vnc and eglfs need no display server. */
    if (!platform.isEmpty()
        && platform != QLatin1String("xcb")
        && platform != QLatin1String("wayland")) {
        return true;
    }

    if (!wayland.isEmpty() && platform != QLatin1String("xcb")) {
        if (waylandReachable(wayland)) {
            return true;
        }
        if (x11.isEmpty()) {
            *reason = QStringLiteral("wayland display '%1' has no socket").arg(wayland);
            return false;
        }
    }

    if (x11.isEmpty()) {
        *reason = QStringLiteral("no DISPLAY or WAYLAND_DISPLAY in the environment");
        return false;
    }

    if (!x11Reachable(x11)) {
        *reason = QStringLiteral("cannot reach X display '%1'").arg(x11);
        return false;
    }

    return true;
}

/* Icon comes from the compiled in Qt resource. Missing resource (built
 * without rcc) is not an error, the dialog just has no icon. */
static QIcon appIcon()
{
    static const char *const paths[] = {
        ":/icons/qtnotify-16.png",
        ":/icons/qtnotify-32.png",
        ":/icons/qtnotify-64.png",
        ":/icons/qtnotify-128.png",
        ":/icons/qtnotify-256.png"
    };
    QIcon icon;

    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
        const QPixmap pixmap(QString::fromLatin1(paths[i]));
        if (!pixmap.isNull()) {
            icon.addPixmap(pixmap);
        }
    }

    return icon;
}

static QString styleSheet(bool normal)
{
    const QString background = normal ? QStringLiteral("#1f7a33")
                                      : QStringLiteral("#cc2222");
    const QString button     = normal ? QStringLiteral("#11491f")
                                      : QStringLiteral("#7a1414");
    const QString hover      = normal ? QStringLiteral("#166028")
                                      : QStringLiteral("#931919");
    const QString border     = normal ? QStringLiteral("#0a2d13")
                                      : QStringLiteral("#4a0c0c");

    return QStringLiteral(
        "QMessageBox { background-color: %1; }"
        "QLabel { color: #ffffff; font-weight: bold; font-size: 14px; }"
        "QPushButton { background-color: %2; color: #ffffff; padding: 6px 22px; "
        "border-radius: 3px; border: 1px solid %4; }"
        "QPushButton:hover { background-color: %3; }"
    ).arg(background, button, hover, border);
}

int main(int argc, char *argv[])
{
    Options opt;
    QString reason;
    bool timedOut = false;

    const int parsed = parseArgs(argc, argv, &opt);
    if (parsed < 0) {
        return RC_ACK;          /* --help / --version, already printed */
    }
    if (parsed > 0) {
        return parsed;          /* usage error, already reported */
    }

    if (opt.dryRun) {
        std::printf("%s: %s\n", qPrintable(opt.title), qPrintable(opt.message));
        return RC_ACK;
    }

    if (!displayAvailable(&reason)) {
        std::fprintf(stderr, "%s: cannot show the dialog, %s\n",
                     QTNOTIFY_NAME, qPrintable(reason));
        std::fprintf(stderr, "%s: message was: %s\n",
                     QTNOTIFY_NAME, qPrintable(opt.message));
        return RC_FAIL;
    }

    /* Hand Qt only argv[0]: our own switches (-t, --title, ...) overlap
     * with options QApplication parses, and it must not eat them. */
    int qtArgc = 1;
    char *qtArgv[] = { argv[0], NULL };
    QApplication app(qtArgc, qtArgv);

    app.setApplicationName(QStringLiteral(QTNOTIFY_NAME));
    app.setApplicationVersion(QStringLiteral(QTNOTIFY_VERSION));
    app.setWindowIcon(appIcon());

    QMessageBox box;
    box.setIcon(QMessageBox::NoIcon);
    box.setWindowTitle(opt.title);
    box.setText(opt.message);
    box.setInformativeText(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss")));
    box.setStandardButtons(QMessageBox::Ok);
    box.button(QMessageBox::Ok)->setText(QStringLiteral("GOT IT"));
    box.setStyleSheet(styleSheet(opt.normal));

    QTimer timer;
    if (opt.timeoutSec > 0) {
        timer.setSingleShot(true);
        QObject::connect(&timer, &QTimer::timeout, &box, [&box, &timedOut]() {
            timedOut = true;
            box.done(QMessageBox::Cancel);
        });
        timer.start(opt.timeoutSec * 1000);
    }

    box.exec();

    if (timedOut) {
        std::fprintf(stderr, "%s: no acknowledgement after %d s, closed\n",
                     QTNOTIFY_NAME, opt.timeoutSec);
        return RC_TIMEOUT;
    }

    return RC_ACK;
}

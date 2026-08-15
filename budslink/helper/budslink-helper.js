#!/usr/bin/env gjs
/*
 * BudsLink companion helper (GJS).
 *
 * Daemon mode (default):
 *   Watches the BudsLink D-Bus service, mirrors device state to
 *   $XDG_RUNTIME_DIR/budslink/state.json on every change and keeps a
 *   HoldService heartbeat alive. A pidfile prevents duplicate daemons.
 *
 * One-shot modes (used by the Noctalia plugin):
 *   --state                    print current state JSON to stdout and exit
 *   --action <name> <value>    send UiAction to the first device and exit
 *   --help                     print usage and exit
 */
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const GLibUnix = imports.gi.GLibUnix;

const BUS_NAME = 'io.github.maniacx.BudsLink';
const OBJECT_PATH = '/io/github/maniacx/BudsLink';
const MANAGER_IFACE = 'io.github.maniacx.BudsLink.DeviceManager';
const DEVICE_IFACE = 'io.github.maniacx.BudsLink.Device';
const SERVICE_VERSION = '0.0.1';
const CLIENT_ID = 'BudsLink-Companion@noctalia';
const HEARTBEAT_SECS = 110;
const WRITE_DELAY_MS = 60;
const SIGTERM = 15;
const SIGUSR1 = 10;
const SIGUSR2 = 12;

const STATE_DIR = GLib.get_user_runtime_dir() + '/budslink';
const STATE_PATH = STATE_DIR + '/state.json';
const PID_PATH = STATE_DIR + '/helper.pid';

const decoder = new TextDecoder();
const encoder = new TextEncoder();

let loop = null;
let managerProxy = null;
let watchId = 0;
let writeTimer = 0;
let holdTimer = 0;

const devices = new Map();

function selfPid() {
    const [ok, bytes] = GLib.file_get_contents('/proc/self/stat');
    if (!ok)
        return 0;
    return parseInt(decoder.decode(bytes).split(' ')[0], 10) || 0;
}

function processAlive(pid) {
    if (!(pid > 0))
        return false;
    const [ok, bytes] = GLib.file_get_contents('/proc/' + pid + '/cmdline');
    return ok && decoder.decode(bytes).includes('budslink-helper');
}

function ensureStateDir() {
    try {
        Gio.File.new_for_path(STATE_DIR).make_directory_with_parents(null);
    } catch (e) {
        /* directory already exists or unwritable */
    }
}

function acquireLock() {
    try {
        const [ok, bytes] = GLib.file_get_contents(PID_PATH);
        if (ok) {
            const pid = parseInt(decoder.decode(bytes), 10);
            if (processAlive(pid))
                return false;
        }
    } catch (e) {
        /* no stale lock */
    }
    ensureStateDir();
    try {
        Gio.File.new_for_path(PID_PATH).replace_contents(
            encoder.encode(String(selfPid())),
            null,
            false,
            Gio.FileCreateFlags.NONE,
            null
        );
    } catch (e) {
        /* best effort */
    }
    return true;
}

function releaseLock() {
    try {
        Gio.File.new_for_path(PID_PATH).delete(null);
    } catch (e) {
        /* already gone */
    }
}

function renderState() {
    const list = [...devices.values()].map(d => ({
        path: d.path,
        alias: d.alias,
        config: d.config,
        state: d.state,
    }));
    return {
        connected: list.length > 0,
        updatedAt: Date.now(),
        devices: list,
    };
}

function writeState() {
    ensureStateDir();
    try {
        // Write in place (no tmp+rename) so filesystem watchers on the path
        // reliably fire on every update; the widget tolerates partial reads.
        Gio.File.new_for_path(STATE_PATH).replace_contents(
            encoder.encode(JSON.stringify(renderState())),
            null,
            false,
            Gio.FileCreateFlags.NONE,
            null
        );
    } catch (e) {
        /* best effort */
    }
}

function scheduleWrite() {
    if (writeTimer)
        return;
    writeTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, WRITE_DELAY_MS, () => {
        writeTimer = 0;
        writeState();
        return GLib.SOURCE_REMOVE;
    });
}

function readDeviceProps(dev) {
    const alias = dev.proxy.get_cached_property('Alias');
    if (alias)
        dev.alias = alias.deepUnpack();

    const config = dev.proxy.get_cached_property('Config');
    if (config) {
        try {
            dev.config = JSON.parse(config.unpack());
        } catch (e) {
            /* malformed config */
        }
    }

    const state = dev.proxy.get_cached_property('State');
    if (state) {
        try {
            dev.state = JSON.parse(state.unpack());
        } catch (e) {
            /* malformed state */
        }
    }
}

function addDevice(path) {
    if (devices.has(path))
        return;

    let proxy;
    try {
        proxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.NONE,
            null,
            BUS_NAME,
            path,
            DEVICE_IFACE,
            null
        );
    } catch (e) {
        return;
    }

    const dev = {path, proxy, alias: '', config: {}, state: {}};
    proxy.connect('g-properties-changed', () => {
        readDeviceProps(dev);
        scheduleWrite();
    });

    readDeviceProps(dev);
    devices.set(path, dev);
    scheduleWrite();
}

function removeDevice(path) {
    if (!devices.has(path))
        return;
    devices.delete(path);
    scheduleWrite();
}

function onServiceAppeared() {
    if (managerProxy)
        return;

    try {
        managerProxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.NONE,
            null,
            BUS_NAME,
            OBJECT_PATH,
            MANAGER_IFACE,
            null
        );

        const versionResult = managerProxy.call_sync(
            'ServiceVersion',
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null
        );
        const [version] = versionResult.deepUnpack();
        if (version !== SERVICE_VERSION) {
            managerProxy = null;
            scheduleWrite();
            return;
        }

        managerProxy.connect('g-signal', (proxy, sender, signalName, params) => {
            if (signalName === 'DeviceAdded') {
                const [path] = params.deepUnpack();
                addDevice(path);
            } else if (signalName === 'DeviceRemoved') {
                const [path] = params.deepUnpack();
                removeDevice(path);
            }
        });

        const listResult = managerProxy.call_sync(
            'ListDevices',
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null
        );
        const [paths] = listResult.deepUnpack();
        for (const path of paths)
            addDevice(path);

        startHeartbeat();
        scheduleWrite();
    } catch (e) {
        managerProxy = null;
        scheduleWrite();
    }
}

function onServiceVanished() {
    stopHeartbeat();
    managerProxy = null;
    devices.clear();
    scheduleWrite();
}

function holdService() {
    try {
        Gio.DBus.session.call_sync(
            BUS_NAME,
            OBJECT_PATH,
            MANAGER_IFACE,
            'HoldService',
            GLib.Variant.new('(s)', [CLIENT_ID]),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null
        );
    } catch (e) {
        /* service not available */
    }
}

function startHeartbeat() {
    holdService();
    if (holdTimer)
        GLib.source_remove(holdTimer);
    holdTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, HEARTBEAT_SECS, () => {
        holdService();
        return GLib.SOURCE_CONTINUE;
    });
}

function releaseService() {
    try {
        Gio.DBus.session.call_sync(
            BUS_NAME,
            OBJECT_PATH,
            MANAGER_IFACE,
            'ReleaseService',
            GLib.Variant.new('(s)', [CLIENT_ID]),
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null
        );
    } catch (e) {
        /* service not available */
    }
}

function stopHeartbeat() {
    if (holdTimer) {
        GLib.source_remove(holdTimer);
        holdTimer = 0;
    }
    releaseService();
}

/* --- one-shot helpers --------------------------------------------------- */

function collectDevicesSync() {
    let proxy;
    try {
        proxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.NONE,
            null,
            BUS_NAME,
            OBJECT_PATH,
            MANAGER_IFACE,
            null
        );
    } catch (e) {
        return [];
    }

    let paths = [];
    try {
        const result = proxy.call_sync(
            'ListDevices',
            null,
            Gio.DBusCallFlags.NONE,
            -1,
            null
        );
        [paths] = result.deepUnpack();
    } catch (e) {
        return [];
    }

    const out = [];
    for (const path of paths) {
        try {
            const deviceProxy = Gio.DBusProxy.new_for_bus_sync(
                Gio.BusType.SESSION,
                Gio.DBusProxyFlags.NONE,
                null,
                BUS_NAME,
                path,
                DEVICE_IFACE,
                null
            );
            const alias = deviceProxy.get_cached_property('Alias');
            let config = {};
            let state = {};
            try {
                config = JSON.parse(deviceProxy.get_cached_property('Config').unpack());
            } catch (e) {
                /* malformed config */
            }
            try {
                state = JSON.parse(deviceProxy.get_cached_property('State').unpack());
            } catch (e) {
                /* malformed state */
            }
            out.push({
                path,
                alias: alias ? alias.deepUnpack() : '',
                config,
                state,
            });
        } catch (e) {
            /* device gone */
        }
    }
    return out;
}

function firstDeviceSync() {
    const list = collectDevicesSync();
    return list.length ? list[0] : null;
}

function printStateSync() {
    const list = collectDevicesSync();
    print(JSON.stringify({
        connected: list.length > 0,
        updatedAt: Date.now(),
        devices: list,
    }));
}

function sendActionSync(action, value) {
    const device = firstDeviceSync();
    if (!device) {
        print(JSON.stringify({ok: false, error: 'no-device'}));
        return;
    }
    try {
        const deviceProxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.NONE,
            null,
            BUS_NAME,
            device.path,
            DEVICE_IFACE,
            null
        );
        deviceProxy.call_sync(
            'UiAction',
            GLib.Variant.new('(si)', [action, value]),
            Gio.DBusCallFlags.NONE,
            -1,
            null
        );
        print(JSON.stringify({ok: true}));
    } catch (e) {
        print(JSON.stringify({ok: false, error: String(e)}));
    }
}

/* --- daemon ------------------------------------------------------------- */

function daemonMain() {
    if (!acquireLock()) {
        return;
    }

    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, SIGTERM, () => {
        stopHeartbeat();
        releaseLock();
        loop?.quit();
        return GLib.SOURCE_REMOVE;
    });

    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, SIGUSR1, () => {
        if (managerProxy && devices.size) {
            const first = devices.values().next().value;
            const c = first.config;
            const s = first.state;
            if (c.toggle1Title && s.toggle1Visible !== false) {
                const buttons = [1, 2, 3, 4].filter(i => c[`toggle1Button${i}Name`]);
                if (buttons.length) {
                    const index = buttons.indexOf(s.toggle1State || 0);
                    const next = buttons[(index + 1) % buttons.length];
                    try {
                        first.proxy.call_sync(
                            'UiAction',
                            GLib.Variant.new('(si)', ['toggle1State', next]),
                            Gio.DBusCallFlags.NONE,
                            -1,
                            null
                        );
                    } catch (e) {
                        /* device gone */
                    }
                }
            }
        }
        return GLib.SOURCE_CONTINUE;
    });

    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, SIGUSR2, () => {
        if (managerProxy && devices.size) {
            const first = devices.values().next().value;
            const c = first.config;
            const s = first.state;
            const box = s.optionsBoxVisible;
            if (box) {
                const options = c[`box${box}RadioButton`] || [];
                if (options.length) {
                    const current = s[`box${box}RadioButtonState`] || 0;
                    const next = (current % options.length) + 1;
                    try {
                        first.proxy.call_sync(
                            'UiAction',
                            GLib.Variant.new('(si)', [`box${box}RadioButtonState`, next]),
                            Gio.DBusCallFlags.NONE,
                            -1,
                            null
                        );
                    } catch (e) {
                        /* device gone */
                    }
                }
            }
        }
        return GLib.SOURCE_CONTINUE;
    });

    watchId = Gio.bus_watch_name(
        Gio.BusType.SESSION,
        BUS_NAME,
        Gio.BusNameWatcherFlags.NONE,
        () => onServiceAppeared(),
        () => onServiceVanished()
    );

    writeState();

    loop = new GLib.MainLoop(null, false);
    loop.run();
}

function usage() {
    print('Usage: budslink-helper.js [--state | --action <name> <value> | --help]');
}

function main() {
    const args = (typeof ARGV !== 'undefined' ? ARGV : []);
    if (args.length === 0) {
        daemonMain();
        return;
    }
    switch (args[0]) {
        case '--state':
            printStateSync();
            break;
        case '--action':
            if (args.length < 3) {
                usage();
                return;
            }
            sendActionSync(args[1], parseInt(args[2], 10));
            break;
        case '--help':
            usage();
            break;
        default:
            usage();
    }
}

main();

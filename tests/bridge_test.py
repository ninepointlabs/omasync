"""Tests for the parts of omasync-bridge that do not need a live daemon.

Run with the system interpreter so it matches how the plugin invokes it:
    /usr/bin/python3 -I -B -m unittest discover -s tests -p '*_test.py'
"""

import importlib.util
import json
import os
import ssl
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_bridge():
    """Import bin/omasync-bridge, which has no .py extension."""
    path = os.path.join(ROOT, "bin", "omasync-bridge")
    spec = importlib.util.spec_from_loader(
        "syncthing_bridge", importlib.machinery.SourceFileLoader("syncthing_bridge", path)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridge = load_bridge()


CONFIG_TEMPLATE = """<configuration version="38">
    <folder id="docs" label="Documents" path="/home/tim/Documents"></folder>
    <options>
        <listenAddress>%(listen)s</listenAddress>
    </options>
    <gui enabled="true" tls="%(tls)s" sendBasicAuthPrompt="false">
        <address>%(address)s</address>
        <apikey>%(key)s</apikey>
    </gui>
</configuration>
"""


class ConfigDiscoveryTest(unittest.TestCase):
    def write_config(self, directory, **values):
        values.setdefault("listen", "dynamic")
        values.setdefault("tls", "false")
        values.setdefault("address", "127.0.0.1:8384")
        values.setdefault("key", "SECRETKEY")
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "config.xml"), "w") as handle:
            handle.write(CONFIG_TEMPLATE % values)

    def read_with_state_home(self, root):
        original = dict(os.environ)
        try:
            os.environ.pop("STCONFDIR", None)
            os.environ.pop("STHOMEDIR", None)
            os.environ["XDG_STATE_HOME"] = os.path.join(root, "state")
            os.environ["XDG_CONFIG_HOME"] = os.path.join(root, "config")
            return bridge.read_gui_config()
        finally:
            os.environ.clear()
            os.environ.update(original)

    def test_reads_key_and_address_from_gui_block(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_config(os.path.join(root, "state", "syncthing"))
            base, key, path = self.read_with_state_home(root)
            self.assertEqual(base, "http://127.0.0.1:8384")
            self.assertEqual(key, "SECRETKEY")
            self.assertTrue(path.endswith("config.xml"))

    def test_ignores_the_listen_address_outside_the_gui_block(self):
        # A naive scan for <address> picks up <listenAddress>dynamic and dials
        # a host called "dynamic"; only the one inside <gui> is the API.
        with tempfile.TemporaryDirectory() as root:
            self.write_config(os.path.join(root, "state", "syncthing"), listen="dynamic")
            base, _, _ = self.read_with_state_home(root)
            self.assertEqual(base, "http://127.0.0.1:8384")

    def test_wildcard_bind_is_dialled_on_loopback(self):
        for address in ("0.0.0.0:8384", ":8384"):
            with self.subTest(address=address):
                with tempfile.TemporaryDirectory() as root:
                    self.write_config(os.path.join(root, "state", "syncthing"), address=address)
                    base, _, _ = self.read_with_state_home(root)
                    self.assertEqual(base, "http://127.0.0.1:8384")

    def test_tls_gui_uses_https(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_config(os.path.join(root, "state", "syncthing"), tls="true")
            base, _, _ = self.read_with_state_home(root)
            self.assertEqual(base, "https://127.0.0.1:8384")

    def test_falls_back_to_the_legacy_config_directory(self):
        with tempfile.TemporaryDirectory() as root:
            self.write_config(os.path.join(root, "config", "syncthing"), key="LEGACY")
            base, key, _ = self.read_with_state_home(root)
            self.assertEqual(key, "LEGACY")
            self.assertEqual(base, "http://127.0.0.1:8384")

    def test_missing_and_keyless_configs_read_as_unconfigured(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(self.read_with_state_home(root), (None, None, None))
            self.write_config(os.path.join(root, "state", "syncthing"), key="")
            self.assertEqual(self.read_with_state_home(root), (None, None, None))

    def test_unparseable_config_does_not_raise(self):
        with tempfile.TemporaryDirectory() as root:
            directory = os.path.join(root, "state", "syncthing")
            os.makedirs(directory)
            with open(os.path.join(directory, "config.xml"), "w") as handle:
                handle.write("<configuration><gui>")
            self.assertEqual(self.read_with_state_home(root), (None, None, None))

    def test_explicit_confdir_wins(self):
        with tempfile.TemporaryDirectory() as root:
            explicit = os.path.join(root, "explicit")
            self.write_config(explicit, key="EXPLICIT")
            self.write_config(os.path.join(root, "state", "syncthing"), key="STATE")
            original = dict(os.environ)
            try:
                os.environ["STCONFDIR"] = explicit
                _, key, _ = bridge.read_gui_config()
            finally:
                os.environ.clear()
                os.environ.update(original)
            self.assertEqual(key, "EXPLICIT")


class ServiceEnvironmentTest(unittest.TestCase):
    def test_run_forwards_the_session_bus_variables(self):
        # Without these, `systemctl --user` cannot reach the user manager and
        # every unit reads as "unknown".
        original = dict(os.environ)
        try:
            os.environ["XDG_RUNTIME_DIR"] = "/run/user/4242"
            os.environ["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/run/user/4242/bus"
            code, out, _ = bridge.run(
                [sys.executable, "-c",
                 "import json,os;print(json.dumps(dict(os.environ)))"]
            )
        finally:
            os.environ.clear()
            os.environ.update(original)
        self.assertEqual(code, 0)
        child = json.loads(out)
        self.assertEqual(child["XDG_RUNTIME_DIR"], "/run/user/4242")
        self.assertEqual(child["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/user/4242/bus")
        self.assertEqual(child["PATH"], "/usr/bin:/bin")

    def test_run_reports_a_missing_program_without_raising(self):
        code, _, err = bridge.run(["/nonexistent/program"])
        self.assertEqual(code, 1)
        self.assertTrue(err)

    def test_autostart_never_couples_to_start_or_stop(self):
        # "Start at login" must not stop a running daemon, so the enable and
        # disable verbs must stay free of --now.
        with open(os.path.join(ROOT, "bin", "omasync-bridge")) as handle:
            source = handle.read()
        body = source.split("def service_action", 1)[1].split("def post", 1)[0]
        # The comment above the verbs explains why --now is absent, so the
        # check has to look at code lines only.
        code = "\n".join(
            line for line in body.splitlines() if not line.strip().startswith("#")
        )
        self.assertIn('"enable": ["enable"]', code)
        self.assertIn('"disable": ["disable"]', code)
        self.assertNotIn("--now", code)

    def test_adopt_shuts_down_the_stray_daemon_before_starting_the_unit(self):
        calls = []
        api_calls = []
        # The stray copy answers until it has been asked to shut down.
        state = {"up": True}

        def fake_api(base, key, path, method="GET", body=None, timeout=None):
            api_calls.append((method, path))
            if path == "/rest/system/shutdown":
                state["up"] = False
                return {}, None
            return ({}, None) if state["up"] else (None, "connection refused")

        def fake_run(argv, timeout=15):
            calls.append(argv[2:])
            return 0, "", ""

        emitted = []
        patches = {
            "api": fake_api,
            "run": fake_run,
            "unit_exists": lambda: True,
            "read_gui_config": lambda: ("http://127.0.0.1:8384", "k", None),
            "service_state": lambda: {"running": True},
            "emit": lambda payload: (emitted.append(payload), (_ for _ in ()).throw(SystemExit(0))),
        }
        originals = {name: getattr(bridge, name) for name in patches}
        original_sleep = bridge.time.sleep
        try:
            for name, value in patches.items():
                setattr(bridge, name, value)
            bridge.time.sleep = lambda _seconds: None
            with self.assertRaises(SystemExit):
                bridge.adopt()
        finally:
            for name, value in originals.items():
                setattr(bridge, name, value)
            bridge.time.sleep = original_sleep

        self.assertIn(("POST", "/rest/system/shutdown"), api_calls)
        self.assertEqual(calls, [["reset-failed", bridge.UNIT], ["start", bridge.UNIT]])
        self.assertEqual(emitted[-1]["ok"], True)
        self.assertEqual(emitted[-1]["action"], "adopt")


class OfferedFolderPathTest(unittest.TestCase):
    """The label on an offered share is chosen by the remote device."""

    def test_separators_and_traversal_never_leave_one_component(self):
        for label in (
            "/etc",
            "../../.config/systemd/user",
            "..",
            "...",
            "sub/dir",
            "back\\slash",
            ".hidden",
            "  ",
        ):
            name = bridge.safe_dirname(label, "fallback-id")
            self.assertNotIn("/", name, label)
            self.assertNotIn("\\", name, label)
            self.assertFalse(name.startswith("."), label)
            self.assertTrue(name, label)

    def test_ordinary_labels_are_left_alone(self):
        self.assertEqual(bridge.safe_dirname("Family Photos", "abcd-1234"), "Family Photos")
        self.assertEqual(bridge.safe_dirname("", "abcd-1234"), "abcd-1234")
        self.assertEqual(bridge.safe_dirname("", ""), "folder")
        self.assertEqual(len(bridge.safe_dirname("x" * 300, "")), 64)

    def test_accept_folder_stays_under_sync(self):
        posted = []

        def fake_api(base, key, path, method="GET", body=None, timeout=None):
            if method == "GET":
                return None, "HTTP 404 on %s" % path
            posted.append((path, body))
            return {}, None

        originals = {name: getattr(bridge, name) for name in ("api", "read_gui_config", "emit")}
        try:
            bridge.api = fake_api
            bridge.read_gui_config = lambda: ("http://127.0.0.1:8384", "k", None)
            bridge.emit = lambda payload: (_ for _ in ()).throw(SystemExit(0))
            with self.assertRaises(SystemExit):
                bridge.accept_folder("shared", "../../.config/autostart", "DEVICE")
        finally:
            for name, value in originals.items():
                setattr(bridge, name, value)

        path = posted[-1][1]["path"]
        expected_root = os.path.join(os.path.expanduser("~"), "Sync")
        self.assertEqual(os.path.dirname(path), expected_root)
        self.assertNotIn(os.path.basename(path), (".", ".."))
        self.assertEqual(os.path.realpath(os.path.dirname(path)),
                         os.path.realpath(expected_root))


OPENSSL = "/usr/bin/openssl"


@unittest.skipUnless(os.path.isfile(OPENSSL), "openssl is needed to mint a test certificate")
class GuiTlsTest(unittest.TestCase):
    """A TLS GUI is reached by pinning Syncthing's own certificate."""

    def config_root(self, certificate=None):
        """A config directory, optionally holding an https-cert.pem."""
        root = tempfile.mkdtemp()
        directory = os.path.join(root, "state", "syncthing")
        os.makedirs(directory)
        with open(os.path.join(directory, "config.xml"), "w") as handle:
            handle.write(CONFIG_TEMPLATE % {
                "listen": "dynamic", "tls": "true",
                "address": "127.0.0.1:8384", "key": "SECRETKEY",
            })
        path = os.path.join(directory, "https-cert.pem")
        if certificate == "real":
            subprocess.run(
                [OPENSSL, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", os.path.join(directory, "https-key.pem"),
                 "-out", path, "-days", "1", "-subj", "/CN=syncthing"],
                check=True, capture_output=True,
            )
        elif certificate == "junk":
            with open(path, "w") as handle:
                handle.write("not a certificate\n")
        return root

    def context_for(self, base, certificate=None):
        root = self.config_root(certificate)
        original = dict(os.environ)
        try:
            os.environ.pop("STCONFDIR", None)
            os.environ.pop("STHOMEDIR", None)
            os.environ["XDG_STATE_HOME"] = os.path.join(root, "state")
            os.environ["XDG_CONFIG_HOME"] = os.path.join(root, "config")
            return bridge.gui_tls_context(base)
        finally:
            os.environ.clear()
            os.environ.update(original)

    def test_plain_http_needs_no_context(self):
        self.assertIsNone(self.context_for("http://127.0.0.1:8384", "real"))

    def test_https_pins_syncthings_own_certificate(self):
        context = self.context_for("https://127.0.0.1:8384", "real")
        self.assertIsNotNone(context)
        # Still verifying -- against that one certificate rather than the
        # system trust store, which cannot vouch for a self-signed GUI.
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        # The generated certificate names "syncthing", not 127.0.0.1.
        self.assertFalse(context.check_hostname)

    def test_https_without_a_certificate_keeps_default_verification(self):
        self.assertIsNone(self.context_for("https://127.0.0.1:8384"))

    def test_an_unreadable_certificate_is_never_trusted(self):
        self.assertIsNone(self.context_for("https://127.0.0.1:8384", "junk"))


if __name__ == "__main__":
    unittest.main()

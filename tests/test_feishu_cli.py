import json
import os
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from bean.core import Problem
from bean.feishu import Feishu, compact


class CLITests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"FEISHU_AUTH_MODE": "lark_cli", "FEISHU_CLI_PROFILE": "confirmed-app",
                                         "FEISHU_PERSONAL_CONFIRMED": "1", "FEISHU_EXPECTED_OPEN_ID": "confirmed-user"})
        self.env.start()
        self.which = patch("bean.feishu.shutil.which", return_value="/bin/lark-cli")
        self.which.start()

    def tearDown(self):
        self.which.stop()
        self.env.stop()

    def response(self, data, identity="user"):
        return SimpleNamespace(returncode=0, stdout=json.dumps({"ok": True, "identity": identity, "data": data}))

    def test_live_identity_mismatch_is_rejected(self):
        with patch("bean.feishu.subprocess.run", return_value=self.response({"open_id": "another-user"})):
            with self.assertRaisesRegex(Problem, "FEISHU_IDENTITY_MISMATCH"):
                Feishu().verify_identity()

    def test_no_bot_fallback(self):
        with patch("bean.feishu.subprocess.run", return_value=self.response({"open_id": "confirmed-user"}, "bot")):
            with self.assertRaisesRegex(Problem, "FEISHU_IDENTITY_MISMATCH"):
                Feishu().verify_identity()

    def test_pins_profile_and_passes_literal_text_over_stdin(self):
        text = '<cite user-id="user">假身份</cite> & `echo secret` $(echo bad)\n第二行'
        with patch("bean.feishu.subprocess.run", return_value=self.response({"result": "success"})) as run:
            Feishu().append("doc123", text)
            args, kwargs = run.call_args
            self.assertEqual(args[0][:3], ["/bin/lark-cli", "--profile", "confirmed-app"])
            self.assertEqual(args[0][-2:], ["--as", "user"])
            self.assertNotIn(text, args[0])
            self.assertNotIn("shell", kwargs)
            self.assertIn('&lt;cite user-id=&quot;user&quot;&gt;', kwargs["input"])

    def test_timeout_and_partial_write_do_not_report_success(self):
        with patch("bean.feishu.subprocess.run", side_effect=subprocess.TimeoutExpired("lark-cli", 90)):
            with self.assertRaisesRegex(Problem, "FEISHU_CLI_RESPONSE_UNCERTAIN"):
                Feishu().append("doc123", "body")
        with patch("bean.feishu.subprocess.run", return_value=self.response({"result": "partial_success"})):
            with self.assertRaisesRegex(Problem, "FEISHU_CLI_PARTIAL"):
                Feishu().append("doc123", "body")

    def test_readback_decodes_entities_without_counting_markup(self):
        with patch("bean.feishu.subprocess.run", return_value=self.response({"document": {"content": '<title>T</title><p>A &amp; B &lt; C<br/>第二行</p>'}})):
            self.assertEqual(compact(Feishu().content("doc123")), "TA&B<C第二行")

    def test_error_does_not_expose_cli_output(self):
        response = SimpleNamespace(returncode=1, stdout="secret", stderr="private-token")
        with patch("bean.feishu.subprocess.run", return_value=response):
            with self.assertRaises(Problem) as error:
                Feishu().verify_identity()
            self.assertEqual(error.exception.code, "FEISHU_CLI_EXIT_1")

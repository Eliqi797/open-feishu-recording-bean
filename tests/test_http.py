import hashlib
import http.client
import json
import io
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
import wave
from pathlib import Path

from bean.core import Store
from bean.server import App


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name), reserve_bytes=0)
        self.app = App(("127.0.0.1", 0), self.store)
        self.thread = threading.Thread(target=self.app.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.app.shutdown()
        self.app.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, method, path, body=None, headers=None, auth=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.app.server_port)
        h = {"Authorization": "Bearer " + self.app.token} if auth else {}
        h.update(headers or {})
        conn.request(method, path, body=body, headers=h)
        res = conn.getresponse()
        out = res.status, dict(res.getheaders()), res.read()
        conn.close()
        return out

    def uploaded(self, content=None, mime="audio/wav"):
        content = content if content is not None else b"RIFF audio test payload"
        sha = hashlib.sha256(content).hexdigest()
        status, _, raw = self.request("POST", "/api/uploads", json.dumps({"device_id": "test", "source_id": "1", "title": "HTTP", "size": len(content), "sha256": sha, "mime": mime}))
        self.assertEqual(status, 200)
        session = json.loads(raw)
        self.assertEqual(self.request("PUT", f"/api/uploads/{session['upload_id']}/chunks/0", content, {"X-Chunk-SHA256": sha})[0], 200)
        self.assertEqual(self.request("POST", f"/api/uploads/{session['upload_id']}/complete", "{}")[0], 200)
        return session["recording_id"], content

    def test_protected_audio_and_byte_ranges(self):
        rid, payload = self.uploaded()
        path = f"/api/recordings/{rid}/audio"
        self.assertEqual(self.request("GET", path, auth=False)[0], 401)
        status, headers, body = self.request("GET", path, headers={"Range": "bytes=5-9"})
        self.assertEqual(status, 206)
        self.assertEqual(body, payload[5:10])
        self.assertEqual(headers["Content-Range"], f"bytes 5-9/{len(payload)}")
        self.assertEqual(self.request("GET", path, headers={"Range": "bytes=-4"})[2], payload[-4:])
        self.assertEqual(self.request("GET", path, headers={"Range": "bytes=999-"})[0], 416)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is installed by the user")
    def test_protected_compatible_audio_is_seekable_and_preserves_original(self):
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(b"\0\0" * 16000)
        rid, original = self.uploaded(output.getvalue())
        path = f"/api/recordings/{rid}/audio?format=mp3"
        self.assertEqual(self.request("GET", path, auth=False)[0], 401)
        status, headers, mp3 = self.request("GET", path)
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "audio/mpeg")
        self.assertGreater(len(mp3), 100)
        self.assertEqual(headers["Accept-Ranges"], "bytes")
        origin = f"http://127.0.0.1:{self.app.server_port}"
        login = self.request("POST", "/api/login", json.dumps({"token": self.app.token}),
                             {"Origin": origin}, auth=False)
        cookie = login[1]["Set-Cookie"].split(";", 1)[0]
        self.assertEqual(self.request("GET", path, headers={"Cookie": cookie}, auth=False)[0], 200)
        status, range_headers, chunk = self.request("GET", path, headers={"Range": "bytes=5-19"})
        self.assertEqual(status, 206)
        self.assertEqual(chunk, mp3[5:20])
        self.assertEqual(range_headers["Content-Range"], f"bytes 5-19/{len(mp3)}")
        self.assertEqual((self.store.root / "audio" / rid).read_bytes(), original)
        cache = list((self.store.root / "playback-cache").glob("*.mp3"))
        self.assertEqual(len(cache), 1)
        self.assertEqual(self.request("GET", path.replace("mp3", "wav"))[0], 400)
        source = self.store.root / "audio" / rid
        source.write_bytes(b"X" + original[1:])
        os.utime(source, ns=(cache[0].stat().st_mtime_ns + 1, cache[0].stat().st_mtime_ns + 1))
        self.assertEqual(self.request("GET", path)[0], 409)

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is installed by the user")
    def test_compatible_audio_conversion_failure_does_not_cache_output(self):
        rid, _ = self.uploaded()
        path = f"/api/recordings/{rid}/audio?format=mp3"
        self.assertEqual(self.request("GET", path)[0], 422)
        self.assertFalse(list((self.store.root / "playback-cache").glob("*.mp3")))

    @unittest.skipUnless(shutil.which("ffmpeg"), "FFmpeg is installed by the user")
    def test_ogg_opus_archive_can_be_played_as_mp3(self):
        ogg = subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                              "-i", "anullsrc=r=48000:cl=mono", "-t", "1", "-c:a", "libopus", "-f", "ogg", "pipe:1"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
        self.assertTrue(ogg.startswith(b"OggS"))
        rid, _ = self.uploaded(ogg, mime="audio/ogg")
        status, headers, body = self.request("GET", f"/api/recordings/{rid}/audio?format=mp3")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "audio/mpeg")
        self.assertGreater(len(body), 100)

    def test_reject_cross_origin_and_dns_rebinding(self):
        self.assertEqual(self.request("GET", "/api/recordings", headers={"Host": "evil.example"})[0], 403)
        self.assertEqual(self.request("POST", "/api/uploads", "{}", {"Origin": "https://evil.example"})[0], 403)

    def test_cookie_login_and_logout(self):
        origin = f"http://127.0.0.1:{self.app.server_port}"
        status, headers, _ = self.request("POST", "/api/login", json.dumps({"token": self.app.token}), {"Origin": origin}, auth=False)
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertEqual(self.request("GET", "/api/recordings", headers={"Cookie": cookie}, auth=False)[0], 200)
        self.assertEqual(self.request("POST", "/api/logout", "{}", {"Cookie": cookie}, auth=False)[0], 403)
        self.assertEqual(self.request("POST", "/api/logout", "{}", {"Cookie": cookie, "Origin": origin}, auth=False)[0], 200)
        self.assertEqual(self.request("GET", "/api/recordings", headers={"Cookie": cookie}, auth=False)[0], 401)

    def test_live_routes_require_auth_and_validate_chunk(self):
        metadata = json.dumps({'device_id': 'd3200', 'source_id': 'live-capture', 'title': 'Live'})
        self.assertEqual(self.request('POST', '/api/live', metadata, auth=False)[0], 401)
        status, _, raw = self.request('POST', '/api/live', metadata)
        self.assertEqual(status, 200)
        sid = json.loads(raw)['session_id']
        base = '/api/live/' + sid
        audio = b'OggS' + bytes(160)
        headers = {'X-Chunk-SHA256': hashlib.sha256(audio).hexdigest(), 'X-Audio-Duration-Ms': '20000'}
        for method, path, body in [('GET', base, None), ('PUT', base + '/segments/0', audio),
                                   ('POST', base + '/segments/0/retry', '{}'), ('POST', base + '/finish', '{}')]:
            self.assertEqual(self.request(method, path, body, headers, auth=False)[0], 401)
        self.assertEqual(self.request('PUT', base + '/segments/0', audio)[0], 400)
        self.assertEqual(self.request('PUT', base + '/segments/0', audio, headers)[0], 200)
        self.assertEqual(self.request('PUT', base + '/segments/0', audio, headers)[0], 200)
        state = json.loads(self.request('GET', base)[2])
        self.assertEqual(state['received_ms'], 20000)
        self.assertEqual(len(state['segments']), 1)
        self.assertEqual(self.request('POST', base + '/finish', '{}')[0], 409)

    def test_settings_auth_revision_redaction_and_secret_clear(self):
        self.assertEqual(self.request('GET','/api/settings',auth=False)[0],401)
        self.assertEqual(self.request('POST','/api/settings','{}',auth=False)[0],401)
        status,_,raw=self.request('POST','/api/settings',json.dumps({'revision':0,'values':{'NVIDIA_API_KEY':'never-return-this'}}))
        self.assertEqual(status,200);self.assertNotIn(b'never-return-this',raw)
        self.assertTrue(json.loads(raw)['secrets_configured']['NVIDIA_API_KEY'])
        self.assertNotIn(b'never-return-this',self.request('GET','/api/settings')[2])
        self.assertEqual(self.request('POST','/api/settings',json.dumps({'revision':0,'values':{}}))[0],409)
        self.assertEqual(self.request('POST','/api/settings',json.dumps({'revision':1,'clear_secrets':[{}]}))[0],400)

    def test_secrets_not_in_capability_response(self):
        status, _, body = self.request("GET", "/api/capabilities")
        self.assertEqual(status, 200)
        self.assertNotIn(self.app.token.encode(), body)

    def test_pipeline_pause_reference_requires_auth_and_preserves_source(self):
        rid,_=self.uploaded();base=f'/api/recordings/{rid}'
        self.assertEqual(self.request('POST',base+'/pipeline','{}',auth=False)[0],401)
        self.assertEqual(self.request('POST',base+'/pipeline','{}')[0],200)
        self.assertEqual(self.request('POST',base+'/pause','{}')[0],200)
        self.assertEqual(self.request('POST',base+'/reference',json.dumps({'text':'reference'}))[0],400)
        self.assertEqual(self.request('POST',base+'/reference',json.dumps({'source':'manual-reference-not-asr','text':'参考文字'}))[0],200)
        status,_,raw=self.request('GET',base+'/result/asr')
        self.assertEqual(json.loads(raw)['source'],'manual-reference-not-asr')
        self.assertEqual(self.request('GET','/api/diagnostics')[0],200)


if __name__ == "__main__":
    unittest.main()

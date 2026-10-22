import contextlib
import hashlib
import json
import pathlib
import re
import secrets
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest


PROBE = pathlib.Path(sys.argv.pop(1)).resolve()


class Probe:
    def __init__(self, *arguments):
        self.events = []
        self.output = []
        self.condition = threading.Condition()
        self.process = subprocess.Popen([str(PROBE), *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        try:
            self.port = self.wait(lambda event: event.get("event") == "ready", timeout=15)["port"]
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            self.output.append(line.strip())
            try:
                event = json.loads(line)
            except (ValueError, TypeError):
                continue
            with self.condition:
                self.events.append(event)
                self.condition.notify_all()

    def mark(self):
        with self.condition:
            return len(self.events)

    def wait(self, predicate, since=0, timeout=10):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for event in self.events[since:]:
                    if predicate(event):
                        return event
                    if event.get("event") == "fatal":
                        raise AssertionError(f"SIPProbe failed: {event}")
                if self.process.poll() is not None:
                    raise AssertionError(f"SIPProbe exited: {self.output[-18:]}")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f"SIPProbe timed out. Recent output: {self.output[-18:]}")
                self.condition.wait(min(remaining, 0.1))

    def command(self, action, expected=0, **arguments):
        marker = self.mark()
        self.process.stdin.write(json.dumps({"action": action, **arguments}) + "\n")
        self.process.stdin.flush()
        response = self.wait(lambda event: event.get("event") == "command" and event.get("action") == action, since=marker)
        if expected is not None and response["status"] != expected:
            raise AssertionError(f"Command {action} failed: {response}")
        return response

    def statistics(self):
        marker = self.mark()
        self.command("stats")
        return self.wait(lambda event: event.get("event") == "stats", since=marker)

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write('{"action":"quit"}\n')
                self.process.stdin.flush()
                self.process.wait(timeout=8)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        self.process.stdin.close()
        self.reader.join(timeout=2)
        self.process.stdout.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class Registrar:
    def __init__(self, transport="udp", password="loopback-test-only", tls_context=None):
        self.password = password
        self.nonce = secrets.token_hex(16)
        self.challenges = 0
        self.registrations = 0
        self.unregistrations = 0
        self.requests = 0
        self.authenticated_users = set()
        owner = self

        class DatagramHandler(socketserver.BaseRequestHandler):
            def handle(self):
                packet, connection = self.request
                response = owner.handle(packet)
                if response:
                    connection.sendto(response, self.client_address)

        class StreamHandler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(2)
                buffer = b""
                while True:
                    try:
                        block = self.request.recv(65536)
                        if not block:
                            return
                        buffer += block
                        while b"\r\n\r\n" in buffer:
                            header, body = buffer.split(b"\r\n\r\n", 1)
                            if not header:
                                buffer = body
                                continue
                            match = re.search(rb"(?im)^Content-Length:\s*(\d+)", header)
                            length = int(match.group(1)) if match else 0
                            if len(body) < length:
                                break
                            response = owner.handle(header + b"\r\n\r\n" + body[:length])
                            buffer = body[length:]
                            if response:
                                self.request.sendall(response)
                    except (OSError, ssl.SSLError):
                        return

        class DatagramServer(socketserver.ThreadingUDPServer):
            daemon_threads = True
            allow_reuse_address = True

        class StreamServer(socketserver.ThreadingTCPServer):
            daemon_threads = True
            allow_reuse_address = True

            def get_request(self):
                connection, address = super().get_request()
                if tls_context:
                    connection.settimeout(5)
                    try:
                        connection = tls_context.wrap_socket(connection, server_side=True)
                    except BaseException:
                        connection.close()
                        raise
                return connection, address

            def handle_error(self, request, client_address):
                pass

        server_type, handler_type = (DatagramServer, DatagramHandler) if transport == "udp" else (StreamServer, StreamHandler)
        self.server = server_type(("127.0.0.1", 0), handler_type)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def handle(self, packet):
        message = packet.decode("utf-8", errors="replace")
        lines = message.split("\r\n")
        if not lines or not lines[0].startswith("REGISTER "):
            return None
        self.requests += 1
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers.setdefault(key.lower(), value.strip())
        authorization = headers.get("authorization", "")
        fields = dict((key.lower(), quoted or plain) for key, quoted, plain in
                      re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]+))', authorization))
        authenticated = False
        if fields.get("nonce") == self.nonce and fields.get("realm") == "sipdesk.test":
            digest = lambda text: hashlib.md5(text.encode()).hexdigest()
            first = digest(f'{fields.get("username", "")}:sipdesk.test:{self.password}')
            second = digest(f'REGISTER:{fields.get("uri", "")}')
            expected = digest(f'{first}:{self.nonce}:{fields.get("nc", "")}:{fields.get("cnonce", "")}:{fields.get("qop", "")}:{second}')
            authenticated = secrets.compare_digest(expected, fields.get("response", ""))
        if authenticated:
            self.authenticated_users.add(fields["username"])
            expires = 0 if headers.get("expires") == "0" or "expires=0" in headers.get("contact", "") else 300
            if expires:
                self.registrations += 1
            else:
                self.unregistrations += 1
            status = "200 OK"
            extra = [f'Contact: {headers.get("contact", "")}', f"Expires: {expires}"]
        else:
            self.challenges += 1
            status = "401 Unauthorized"
            extra = [f'WWW-Authenticate: Digest realm="sipdesk.test", nonce="{self.nonce}", algorithm=MD5, qop="auth"']
        to_header = headers.get("to", "")
        if ";tag=" not in to_header:
            to_header += ";tag=sipdesk-fixture"
        response = [f"SIP/2.0 {status}", f'Via: {headers.get("via", "")}', f'From: {headers.get("from", "")}',
                    f"To: {to_header}", f'Call-ID: {headers.get("call-id", "")}', f'CSeq: {headers.get("cseq", "")}',
                    *extra, "Content-Length: 0", "", ""]
        return "\r\n".join(response).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)


def call_state(state):
    return lambda event: event.get("event") == "sip" and event.get("type") == 3 and event.get("state") == state


def media_state(state):
    return lambda event: event.get("event") == "sip" and event.get("type") == 4 and event.get("media_state") == state


class LoopbackTests(unittest.TestCase):
    def test_digest_registration_udp_and_tcp_and_unregister(self):
        for transport in ("udp", "tcp"):
            with self.subTest(transport=transport), Registrar(transport) as registrar:
                with Probe("--transport", transport, "--registrar-port", str(registrar.port)) as phone:
                    phone.wait(lambda event: event.get("type") == 1 and event.get("registered") == 1)
                    self.assertGreaterEqual(registrar.challenges, 1)
                    self.assertGreaterEqual(registrar.registrations, 1)
                    self.assertIn("alice", registrar.authenticated_users)
                    phone.command("disconnect")
                    deadline = time.monotonic() + 5
                    while not registrar.unregistrations and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertGreaterEqual(registrar.unregistrations, 1)

    def test_wrong_password_does_not_register(self):
        with Registrar(password="not-the-probe-password") as registrar:
            with Probe("--registrar-port", str(registrar.port)) as phone:
                failure = phone.wait(lambda event: event.get("type") == 1 and event.get("code") in (401, 171100))
                self.assertEqual(failure["registered"], 0)
                self.assertEqual(registrar.registrations, 0)

    def test_call_audio_dtmf_hold_busy_and_hangup(self):
        for transport in ("udp", "tcp"):
            with self.subTest(transport=transport), contextlib.ExitStack() as stack:
                caller = stack.enter_context(Probe("--user", "alice", "--transport", transport))
                callee = stack.enter_context(Probe("--user", "bob", "--transport", transport))
                caller_marker, callee_marker = caller.mark(), callee.mark()
                caller.command("dial", port=callee.port)
                incoming = callee.wait(lambda event: event.get("type") == 2, since=callee_marker)
                self.assertEqual(incoming["incoming"], 1)
                time.sleep(0.25)
                self.assertFalse(any(event.get("state") == 5 for event in callee.events[callee_marker:]))
                callee.command("answer")
                caller_connected = caller.wait(call_state(5), since=caller_marker)
                callee.wait(call_state(5), since=callee_marker)
                caller.command("tone")
                callee.command("tone")
                time.sleep(1.2)
                for phone in (caller, callee):
                    statistics = phone.statistics()
                    self.assertGreater(statistics["tx"], 20)
                    self.assertGreater(statistics["rx"], 20)
                    self.assertIn(statistics["codec"], ("PCMU", "PCMA", "G722"))
                caller.command("mute", enabled=True)
                marker = caller.mark()
                caller.command("recover_audio")
                recovered = caller.wait(lambda event: event.get("type") == 8, since=marker)
                self.assertEqual(recovered["token"], caller_connected["token"])
                self.assertEqual(recovered["state"], 5)
                self.assertEqual(caller.statistics()["input_level"], 0)
                caller.command("mute", enabled=False)
                for info_mode, digit in ((False, "5"), (True, "#")):
                    marker = callee.mark()
                    caller.command("dtmf", digits=digit, info=info_mode)
                    callee.wait(lambda event: event.get("type") == 5 and event.get("message") == digit, since=marker)
                invalid = caller.command("dtmf", digits="+", expected=None)
                self.assertNotEqual(invalid["status"], 0)
                marker = caller.mark()
                caller.command("hold", enabled=True)
                caller.wait(media_state(2), since=marker)
                marker = caller.mark()
                caller.command("hold", enabled=False)
                caller.wait(media_state(1), since=marker)
                deadline = time.monotonic() + 5
                while caller.statistics()["rx"] == 0 and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertGreater(caller.statistics()["rx"], 0)
                third = stack.enter_context(Probe("--user", "charlie", "--transport", transport))
                third.command("dial", port=callee.port)
                rejected = third.wait(call_state(6))
                self.assertEqual(rejected["code"], 486)
                self.assertEqual(caller_connected["token"], caller.wait(call_state(5), since=caller_marker)["token"])
                caller_marker, callee_marker = caller.mark(), callee.mark()
                caller.command("hangup")
                caller.wait(call_state(6), since=caller_marker)
                callee.wait(call_state(6), since=callee_marker)

    def test_cancel_ringing_and_decline(self):
        with Probe("--user", "alice") as caller, Probe("--user", "bob") as callee:
            old_token = 0
            for reject in (False, True):
                caller_marker, callee_marker = caller.mark(), callee.mark()
                caller.command("dial", port=callee.port)
                incoming = callee.wait(lambda event: event.get("type") == 2, since=callee_marker)
                self.assertGreater(incoming["token"], old_token)
                old_token = incoming["token"]
                if reject:
                    callee.command("reject")
                else:
                    caller.command("hangup")
                ended = caller.wait(call_state(6), since=caller_marker)
                callee.wait(call_state(6), since=callee_marker)
                self.assertEqual(ended["code"], 603 if reject else 487)

    def test_ipv6_loopback(self):
        with Probe("--ipv6", "--user", "alice") as caller, Probe("--ipv6", "--user", "bob") as callee:
            caller.command("dial", port=callee.port)
            callee.wait(lambda event: event.get("type") == 2)
            callee.command("answer")
            caller.wait(call_state(5))
            callee.wait(call_state(5))
            time.sleep(0.5)
            self.assertGreater(caller.statistics()["rx"], 0)
            caller.command("hangup")
            callee.wait(call_state(6))

    def test_tls_rejects_untrusted_certificate(self):
        with tempfile.TemporaryDirectory(prefix="SIPDesk-TLS-Test-") as temporary:
            directory = pathlib.Path(temporary)
            configuration = directory / "openssl.cnf"
            configuration.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=127.0.0.1\n[extensions]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\n")
            certificate, key = directory / "certificate.pem", directory / "key.pem"
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-config", str(configuration), "-out", str(certificate), "-keyout", str(key)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            with Registrar("tls", tls_context=context) as registrar:
                with Probe("--transport", "tls", "--registrar-port", str(registrar.port)) as phone:
                    failure = phone.wait(lambda event: event.get("type") in (1, 6) and "cert" in event.get("message", "").lower(), timeout=15)
                    self.assertNotEqual(failure["code"], 0)
                    self.assertFalse(any(event.get("registered") == 1 for event in phone.events))
                    self.assertEqual(registrar.requests, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

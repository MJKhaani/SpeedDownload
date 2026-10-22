"""Check the installed native host's client-only status and bounded allowlist."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import uuid

host = str(Path(sys.argv[1]).resolve())
origin = 'chrome-extension://fcjiipabggcamlocakedfideaamdgknn/'

def send(message, caller=origin):
    encoded = json.dumps(message).encode()
    result = subprocess.run([host, caller], input=struct.pack('<I', len(encoded)) + encoded,
        capture_output=True, check=True, timeout=10)
    length = struct.unpack('<I', result.stdout[:4])[0]
    return json.loads(result.stdout[4:4 + length])

status = send({'version': 1, 'action': 'status'})
assert status == {'version': 1, 'ok': True, 'client_available': True}, status
for message in [
    {'version': 1, 'action': 'engine.status', 'url': 'https://example.test/file', 'idempotency_key': str(uuid.uuid4())},
    {'version': 1, 'action': 'add', 'url': 'file:///etc/passwd', 'idempotency_key': str(uuid.uuid4())},
    {'version': 1, 'action': 'batch', 'urls': ['https://example.test/file'] * 101, 'idempotency_key': str(uuid.uuid4())},
    {'version': 1, 'action': 'add', 'url': 'https://user:password@example.test/file', 'idempotency_key': str(uuid.uuid4())},
]:
    assert send(message)['ok'] is False
assert send({'version': 1, 'action': 'status'}, 'chrome-extension://untrusted/')['ok'] is False
print('PASS: client-only native host status, no engine methods, URL/batch validation, and caller allowlist')

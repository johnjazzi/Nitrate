"""GET-only retrieval of PR 74's existing Cloud failure evidence."""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

import cloud_monitor as cm

API = 'https://api.appstoreconnect.apple.com'
RUN = '13e3c15b-c5ca-4f80-9298-cbe235b6c6e6'
SHA = 'aad62444ecb23c26dfcaab510b02cc37123a82d1'
OUT = Path('cloud-failure-evidence')
MAX_BYTES = 400 * 1024 * 1024


def safe_url(url):
    p = urlsplit(url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password or p.port not in (None, 443):
        raise ValueError('Unsafe artifact transport')
    return url


class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        safe_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def strip_urls(value):
    if isinstance(value, dict):
        return {k: strip_urls(v) for k, v in value.items() if k not in ('downloadUrl', 'links')}
    if isinstance(value, list):
        return [strip_urls(v) for v in value]
    return value


def main():
    redactor = cm.Redactor()
    key_id, issuer_id, key = cm.load_credentials(os.environ, redactor)
    tokens = cm.JwtTokenProvider(key_id, issuer_id, key, cm.SystemClock(), redactor=redactor)
    client = cm.UrllibHttpClient()

    def get(path):
        url = path if path.startswith('https://') else API + path
        cm.validate_api_url(url, 'api.appstoreconnect.apple.com')
        response = client.request('GET', url, headers={'Authorization': 'Bearer ' + tokens.token()}, timeout=45)
        if response.status != 200:
            raise RuntimeError('ASC GET status ' + str(response.status))
        return response.json()

    def all_items(path):
        result = []
        for _ in range(10):
            page = get(path)
            result.extend(page['data'])
            path = page.get('links', {}).get('next')
            if not path:
                return result
        raise ValueError('Unexpected pagination depth')

    OUT.mkdir(exist_ok=True)
    run = get('/v1/ciBuildRuns/' + RUN)['data']
    assert run['attributes']['sourceCommit']['commitSha'] == SHA
    assert run['attributes']['completionStatus'] == 'SUCCEEDED'
    actions = all_items('/v1/ciBuildRuns/' + RUN + '/actions?limit=200')
    metadata = {'run': run, 'actions': actions, 'artifacts': []}
    workflow = run.get('relationships', {}).get('workflow', {}).get('data')
    if workflow:
        metadata['workflow'] = get('/v1/ciWorkflows/' + workflow['id'] + '?include=xcodeVersion,macOsVersion')
    opener = urllib.request.build_opener(HTTPSOnly())
    downloaded = 0
    for action in actions:
        assert re.fullmatch(r'[0-9a-f-]{36}', action['id'])
        artifacts = all_items('/v1/ciBuildActions/' + action['id'] + '/artifacts?limit=200')
        for artifact in artifacts:
            attrs = artifact['attributes']
            metadata['artifacts'].append(strip_urls(artifact))
            if attrs['fileType'] not in ('LOG_BUNDLE', 'RESULT_BUNDLE'):
                continue
            size = attrs.get('fileSize') or 0
            if size > MAX_BYTES:
                raise ValueError('Diagnostic artifact exceeds size cap')
            name = Path(attrs['fileName']).name
            if name in ('', '.', '..') or '/' in name or '\\' in name:
                raise ValueError('Invalid artifact basename')
            target = OUT / (artifact['id'] + '-' + name)
            # No Authorization header is ever sent to the presigned URL.
            with opener.open(safe_url(attrs['downloadUrl']), timeout=120) as response, target.open('wb') as dest:
                count = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    count += len(chunk)
                    if count > MAX_BYTES:
                        raise ValueError('Diagnostic artifact exceeds size cap')
                    dest.write(chunk)
            downloaded += 1
            print(attrs['fileType'], target.name, count, 'bytes')
    (OUT / 'metadata.json').write_text(redactor(json.dumps(strip_urls(metadata), indent=2)))
    if not downloaded:
        raise ValueError('No diagnostic artifacts available')
    print('Retrieved existing failed run; no Cloud build was launched.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Exception text may contain a presigned URL or token. Never print it.
        print('Evidence retrieval failed:', type(error).__name__, file=sys.stderr)
        sys.exit(1)

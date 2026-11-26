"""Pin read-only official repository references for the EPUB CSS comparison."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.request import Request, urlopen

OUT = Path(__file__).resolve().parents[1] / 'build/research/epub-css-engines-2026-10/upstream'
REPOS = ['readium/css', 'readium/kotlin-toolkit', 'readium/swift-toolkit',
         'edrlab/thorium-reader', 'johnfactotum/foliate-js', 'readest/readest',
         'Anxcye/anx-reader', 'vivliostyle/vivliostyle.js', 'futurepress/epub.js']


def get(url):
    request = Request(url, headers={'User-Agent':'LiteTale-EPUB-CSS-Research',
                                   'Accept':'application/vnd.github+json' if 'api.github.com' in url else '*/*'})
    with urlopen(request, timeout=25) as response:
        data = response.read(2 * 1024 * 1024 + 1)
        assert len(data) <= 2 * 1024 * 1024
        return data


def inspect(repo):
    folder = OUT / repo.replace('/', '__')
    folder.mkdir(parents=True, exist_ok=True)
    record = {'repository':repo, 'url':f'https://github.com/{repo}',
              'scope':'Read-only official source snapshot; not an executed application'}
    try:
        # Public API quota is exhausted on this network. Resolve immutable HEAD
        # with read-only Git transport, without credentials or repository writes.
        env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
        refs = subprocess.run(['git','-c','credential.helper=','-c','core.askPass=',
                               'ls-remote','--symref',f'https://github.com/{repo}.git','HEAD'],
                              capture_output=True, text=True, timeout=35, env=env, check=True).stdout
        branch = re.search(r'ref: refs/heads/(\S+)\s+HEAD', refs).group(1)
        sha = re.search(r'^([a-f0-9]{40})\s+HEAD', refs, re.M).group(1)
        record.update({'branch':branch,'commit':sha,
                       'identityMethod':'git ls-remote --symref (public read-only)',
                       'metadataLimitation':'GitHub API returned HTTP403 quota exceeded; license read from snapshot file',
                       'files':[], 'missingFiles':[]})
        files = ['README.md','LICENSE','.gitmodules']
        if repo == 'readest/readest':
            files += ['apps/readest-app/docs/architecture.md']
        if repo == 'johnfactotum/foliate-js':
            files += ['epub.js','paginator.js','fixed-layout.js','view.js']
        for file in files:
            url = f'https://raw.githubusercontent.com/{repo}/{sha}/{file}'
            try:
                data = get(url)
                target = folder / file
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                record['files'].append({'path':file,'url':url,'bytes':len(data),
                                        'sha256':hashlib.sha256(data).hexdigest()})
            except Exception as error:
                record['missingFiles'].append({'path':file,'error':str(error)})
    except Exception as error:
        record['error'] = str(error)
    (folder / 'identity.json').write_text(json.dumps(record, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return record


if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as executor:
        records = list(executor.map(inspect, REPOS))
    (OUT / 'index.json').write_text(json.dumps(records, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    for record in records:
        print(json.dumps({k:record.get(k) for k in ('repository','branch','commit','error')}, ensure_ascii=False))

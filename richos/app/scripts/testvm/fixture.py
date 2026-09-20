#!/usr/bin/env python3
"""Make a disposable named fixture from a supplied synthetic QA home."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def prepare(source,dest,kind):
    source=Path(source).resolve();dest=Path(dest).resolve()
    if dest.exists() or source==dest or source in dest.parents:
        raise ValueError('destination must be new and outside the source fixture')
    # Never edit through links copied out of a source home. Per-install trees
    # are excluded before traversal, including keychains and Claude credentials.
    excluded={Path('Library/Keychains'),Path('Applications'),Path('.claude'),Path('Library/Application Support/com.richos.app/phone')}
    def ignore(directory,names):
        relative=Path(directory).relative_to(source)
        # The pinned engine is supplied separately by run.sh. Retired installed
        # runtimes contain legitimate symlinks and are not conversation history.
        installed_engine=Path('Library/Application Support/RichOS')
        skipped=[name for name in names if relative/name in excluded or
                 (relative==installed_engine and (name=='engine' or name.startswith('engine.previous.')))]
        for name in names:
            if name not in skipped and (Path(directory)/name).is_symlink():
                raise ValueError('fixture contains a link outside excluded install state: '+str(relative/name))
        return skipped
    try:
        shutil.copytree(source,dest,ignore=ignore)
    except Exception:
        if dest.exists():shutil.rmtree(dest)
        raise
    data=dest/'Library/Application Support/com.richos.app'
    ledger=data/'conversation-ledger.jsonl'
    before=hashlib.sha256(ledger.read_bytes()).hexdigest()
    if kind=='delta':
        rows=[json.loads(x) for x in ledger.read_text().splitlines() if x]
        created=[x for x in rows if x.get('event')=='ThreadCreated' and x.get('entity_id') and x.get('person_id')]
        if len(created)<2:raise ValueError('delta fixture needs two bound synthetic threads in the source')
        keep=[]
        for row,title in zip(created[:2],('Scenario A','Scenario B')):
            keep.append({**row,'title':title})
        ledger.write_text(''.join(json.dumps(x)+'\n' for x in keep))
        (data/'intake.jsonl').write_text('')
        # Runtime journals can resurrect old work even with an empty ledger.
        for name in ('engine-state','coordination','ecs','machinery','voice-scratch','launches.json'):
            path=data/name
            if path.is_dir():shutil.rmtree(path)
            elif path.exists():path.unlink()
        for relative in ('Library/WebKit/com.richos.app','Library/Caches/com.richos.app','Library/HTTPStorages/com.richos.app'):
            path=dest/relative
            if path.is_dir():shutil.rmtree(path)
        nav=data/'navigation.json'
        if nav.exists():
            value=json.loads(nav.read_text())
            for key in ('pinned_threads','archived_threads'):value[key]=[]
            value['renamed_threads']={}
            nav.write_text(json.dumps(value))
    # These are per-install secrets and update state, not conversation fixtures.
    for path in (data/'phone',dest/'Library/Keychains',dest/'Applications',dest/'.claude'):
        if path.is_symlink():path.unlink()
        elif path.exists():shutil.rmtree(path)
    result={'kind':kind,'source_ledger_sha256':before,'ledger_sha256':hashlib.sha256(ledger.read_bytes()).hexdigest()}
    (dest/'fixture.json').write_text(json.dumps(result,indent=2))
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--kind',choices=['delta','long-history'],required=True)
    a=p.parse_args()
    try:print(json.dumps(prepare(a.source,a.out,a.kind)))
    except (ValueError,OSError) as exc:p.exit(2,str(exc)+'\n')

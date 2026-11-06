#!/usr/bin/env python3
"""Prepare approved, pinned recordings. No synthesis or pitch shifting here.

Run with the existing MRT environment's numpy/soundfile/scipy, but this script
does not import a model, use the GPU, record audio, or access an audio device.
Sources are downloaded separately; download-manifest.json pins URLs and hashes.
"""
from pathlib import Path
import argparse, hashlib, json, math, shutil
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'dist/qa/keywoo-2.6/source'
OUT = ROOT / 'Sources/KeyDance/Resources/KeyboardSounds'
QA = ROOT / 'dist/qa/keywoo-2.6'
RATE = 48000
PACKS = ['red', 'blue', 'brown', 'black', 'oreo', 'purple', 'topre']
NAMES = {'red':'Cherry MX Red · ABS', 'blue':'Cherry MX Blue · ABS',
         'brown':'Cherry MX Brown · PBT', 'black':'Cherry MX Black · PBT',
         'oreo':'Everglide Oreo', 'purple':'Everglide Crystal Purple',
         'topre':'Topre Purple Hybrid · PBT', 'panda':'Holy Panda',
         'bluePBT':'Cherry MX Blue · PBT', 'brownABS':'Cherry MX Brown · ABS',
         'blackABS':'Cherry MX Black · ABS'}
CURATED = json.loads(Path(__file__).with_name('keyboard-recorded-takes.json').read_text())
NAMES.update({key: pack['title'] for key, pack in CURATED['packs'].items()})
MAC = {
 0:'KeyA',1:'KeyS',2:'KeyD',3:'KeyF',4:'KeyH',5:'KeyG',6:'KeyZ',7:'KeyX',8:'KeyC',9:'KeyV',
 11:'KeyB',12:'KeyQ',13:'KeyW',14:'KeyE',15:'KeyR',16:'KeyY',17:'KeyT',18:'Digit1',19:'Digit2',
 20:'Digit3',21:'Digit4',22:'Digit6',23:'Digit5',24:'Equal',25:'Digit9',26:'Digit7',27:'Minus',
 28:'Digit8',29:'Digit0',30:'BracketRight',31:'KeyO',32:'KeyU',33:'BracketLeft',34:'KeyI',35:'KeyP',
 36:'Enter',37:'KeyL',38:'KeyJ',39:'Quote',40:'KeyK',41:'Semicolon',42:'Backslash',43:'Comma',
 44:'Slash',45:'KeyN',46:'KeyM',47:'Period',48:'Tab',49:'Space',50:'Backquote',51:'Backspace',
 53:'Escape',54:'MetaRight',55:'MetaLeft',56:'ShiftLeft',57:'CapsLock',58:'AltLeft',59:'ControlLeft',
 60:'ShiftRight',61:'AltRight',62:'ControlRight',63:'ControlLeft',65:'NumpadDecimal',67:'NumpadMultiply',
 69:'NumpadAdd',71:'NumLock',75:'NumpadDivide',76:'NumpadEnter',78:'NumpadSubtract',81:'Equal',
 82:'Numpad0',83:'Numpad1',84:'Numpad2',85:'Numpad3',86:'Numpad4',87:'Numpad5',88:'Numpad6',
 89:'Numpad7',91:'Numpad8',92:'Numpad9',96:'F5',97:'F6',98:'F7',99:'F3',100:'F8',101:'F9',
 103:'F11',109:'F10',111:'F12',114:'Insert',115:'Home',116:'PageUp',117:'Delete',118:'F4',119:'End',
 120:'F2',121:'PageDown',122:'F1',123:'ArrowLeft',124:'ArrowRight',125:'ArrowDown',126:'ArrowUp'
}

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):
    samples, rate = sf.read(path, dtype='float64', always_2d=True)
    if samples.shape[1] == 1: samples = np.repeat(samples, 2, axis=1)
    if samples.shape[1] != 2 or not np.isfinite(samples).all(): raise ValueError(path)
    if rate != RATE:
        common = math.gcd(rate,RATE)
        samples = resample_poly(samples,RATE//common,rate//common,axis=0)
    return samples

def envelope(samples):
    mono = np.sqrt(np.mean(samples * samples,axis=1))
    return np.sqrt(np.convolve(mono*mono,np.ones(48)/48,mode='same'))

def split_if_clear(samples):
    """Conservative physical-contact split, never a mathematical half cut.

    Both contacts must have energy above the floor, separated by a >=6ms
    quiet valley. The late contact must occur after 55% of the source window,
    excluding switch click/pretravel inside the initial actuation cluster.
    Ambiguous windows remain complete one-shots and have no separate key-up.
    """
    env = envelope(samples); n = len(env)
    early = int(np.argmax(env[:int(n*.5)]))
    late_start = int(n*.55); late = late_start + int(np.argmax(env[late_start:]))
    peaks = (float(env[early]),float(env[late])); maximum = float(env.max())
    result = {'method':'complete-one-shot','sourceFrames':n,'earlyPeak':peaks[0],'latePeak':peaks[1]}
    if late-early < RATE*.025 or min(peaks) < maximum*.04: return [samples],result
    left=early+int(RATE*.004);right=late-int(RATE*.004)
    if right<=left:return [samples],result
    threshold=min(peaks)*.20
    quiet=env[left:right] < threshold
    boundaries=np.flatnonzero(np.diff(np.r_[False,quiet,False])).reshape(-1,2)
    if not len(boundaries):return [samples],result
    best=max(boundaries,key=lambda pair:pair[1]-pair[0])
    gap=int(best[1]-best[0]); cut=left+int((best[0]+best[1])/2)
    total=float(np.sum(samples*samples));e1=float(np.sum(samples[:cut]**2));e2=total-e1
    if gap < RATE*.006 or min(e1,e2) < total*.012: return [samples],result
    result.update(method='two-contacts-with-quiet-gap',splitFrame=cut,quietGapFrames=gap,
                  firstEnergyFraction=e1/total,secondEnergyFraction=e2/total)
    return [samples[:cut],samples[cut:]],result

def trim(samples, fade_out_ms=1.5):
    env=envelope(samples);peak=float(env.max())
    # A low tail threshold is inappropriate for onset alignment: room noise in
    # a long valley can exceed it, delaying the contact by tens of milliseconds.
    onset_threshold=min(peak*.5,max(peak*.12,float(np.quantile(env,.2))*4,1e-6))
    active=np.flatnonzero(env>onset_threshold)
    if not len(active):raise ValueError('silent source clip')
    start=max(0,int(active[0])-int(RATE*.0005))
    tail_active=np.flatnonzero(env>max(peak*.012,1e-6))
    end=min(len(samples),int(tail_active[-1])+int(RATE*.004)+1)
    # Verify again after the tiny fade: a marginal room-noise peak at the cut
    # must not masquerade as the onset, leaving the real contact 30–50ms later.
    for alignment_pass in range(5):
        result=samples[start:end].copy()
        fade_in=min(len(result),int(RATE*.0003));fade_out=min(len(result),round(RATE*fade_out_ms/1000))
        result[:fade_in]*=np.linspace(0,1,fade_in)[:,None]
        result[-fade_out:]*=np.linspace(1,0,fade_out)[:,None]
        processed_env=envelope(result)
        contact=np.flatnonzero(processed_env>float(processed_env.max())*.12)
        if int(contact[0]) <= RATE*.002:break
        start += max(1,int(contact[0])-int(RATE*.0005))
    else:raise ValueError('could not align reliable contact')
    return result,{'trimStartFrames':start,'trimEndFrames':len(samples)-end,
                  'contactOnsetFrames':int(contact[0]),'onsetThreshold':onset_threshold,
                  'alignmentPasses':alignment_pass+1}

def curated_key_mappings(pack, audio, add):
    pairs = {}
    for role, takes in pack['takes'].items():
        pair = {'down': [], 'up': [], 'sourceKey': role}
        for take in takes:
            file = take['file']
            samples, source_rate = audio[file]
            start, end = take['windowMs']
            window = samples[round(start*RATE/1000):round(end*RATE/1000)]
            if len(window) != round(end*RATE/1000)-round(start*RATE/1000):
                raise ValueError(f'Incomplete window in {file}: {start}–{end} ms')
            if pack.get('splitContacts'):
                contacts, detail = split_if_clear(window)
                if len(contacts) != 2:
                    raise ValueError(f'Cannot confirm two contacts in {file}: {start}–{end} ms')
            else:
                contacts, detail = [window], {'method': 'curated-physical-one-shot'}
            for edge, contact in zip(('down', 'up'), contacts):
                description = {'sourceFile': file, 'sourceStartMS': start, 'sourceEndMS': end,
                               'sourceSampleRate': source_rate, 'sourceKey': take['sourceKey'],
                               'mappingRole': role, 'edge': edge, **detail}
                pair[edge].append(add(contact, description, take.get('fadeOutMS', 1.5)))
        pairs[role] = pair
    generic = pairs['ordinary']
    special = {'Space': 'space', 'Enter': 'enter', 'NumpadEnter': 'enter',
               'Backspace': 'backspace', 'Delete': 'backspace'}
    keys = {key: pairs.get(special.get(key), generic) for key in MAC.values()}
    return keys, generic

def prepare(selected=None, merge=False):
    OUT.mkdir(parents=True,exist_ok=True)
    previous=json.loads((OUT/'manifest.json').read_text()) if merge else None
    all_packs=dict(previous['packs']) if previous else {};reports={}
    selected = selected or PACKS+['panda']
    incoming_sources = []
    if any(style not in CURATED['packs'] for style in selected):
        incoming_sources.extend(json.loads((SOURCE/'download-manifest.json').read_text()))
    for style in selected:
        clips=[];clip_records=[];keys={};report={};cache={}
        def add(samples,description,fade_out_ms=1.5):
            samples,trim_info=trim(samples,fade_out_ms)
            if fade_out_ms != 1.5: trim_info['fadeOutMS']=fade_out_ms
            clip_id=len(clips);clips.append(samples)
            clip_records.append(dict(description,**trim_info))
            return clip_id
        curated = CURATED['packs'].get(style)
        if curated:
            files = sorted({take['file'] for takes in curated['takes'].values() for take in takes})
            audio = {}
            for file in files:
                source = CURATED['sources'][file]
                path = SOURCE/file
                if path.stat().st_size != source['bytes'] or sha(path) != source['sha256']:
                    raise ValueError(f'Recording source hash mismatch: {path}')
                incoming_sources.append(dict(source, file=file))
                audio[file] = (read(path), sf.info(path).samplerate)
            keys, curated_fallback = curated_key_mappings(curated, audio, add)
        elif style!='panda':
            folder=SOURCE/style;config=json.loads((folder/'config.json').read_text())
            source=read(folder/config['audio_file'])
            source_rate=sf.info(folder/config['audio_file']).samplerate
            for name,definition in config['definitions'].items():
                timing=definition['timing'];start=min(pair[0] for pair in timing);end=max(pair[1] for pair in timing)
                identifier=(start,end)
                if identifier not in cache:
                    raw=source[round(start*RATE/1000):round(end*RATE/1000)]
                    parts,detail=split_if_clear(raw)
                    common={'sourceFile':config['audio_file'],'sourceStartMS':start,'sourceEndMS':end,
                            'sourceSampleRate':source_rate,'sourceKey':name}
                    down=add(parts[0],dict(common,edge='down',**detail))
                    up=add(parts[1],dict(common,edge='up',**detail)) if len(parts)==2 else None
                    cache[identifier]={'down':[down],'up':[] if up is None else [up]}
                    report[name]=detail
                keys[name]=cache[identifier]
        else:
            generic_down=[]
            for variant in range(5):
                path=SOURCE/'panda/press'/f'GENERIC_R{variant}.mp3'
                generic_down.append(add(read(path),{'sourceFile':str(path.relative_to(SOURCE/'panda')),'edge':'down','method':'upstream-separate-recording'}))
            path=SOURCE/'panda/release/GENERIC.mp3'
            generic_up=add(read(path),{'sourceFile':str(path.relative_to(SOURCE/'panda')),'edge':'up','method':'upstream-separate-recording'})
            for name in MAC.values():keys[name]={'down':generic_down,'up':[generic_up]}
            for name,file in [('Space','SPACE'),('Enter','ENTER'),('Backspace','BACKSPACE')]:
                pair={}
                for edge,phase in [('down','press'),('up','release')]:
                    path=SOURCE/'panda'/phase/(file+'.mp3')
                    pair[edge]=[add(read(path),{'sourceFile':str(path.relative_to(SOURCE/'panda')),'edge':edge,'method':'upstream-separate-recording'})]
                keys[name]=pair
            report={'method':'upstream-separate-recordings','genericVariants':5,
                    'dedicatedKeys':['Space','Enter','Backspace'],'genericFallback':['Tab','Modifiers','Other']}
        # One gain per keyboard: keep all original key and return relationships.
        ordinary=[float(np.max(np.abs(clips[pair['down'][0]]))) for name,pair in keys.items() if name.startswith('Key')]
        all_peak=max(float(np.max(np.abs(clip))) for clip in clips)
        median=float(np.median(ordinary)); gain=min(4.0,.19/max(median,1e-9),.31/max(all_peak,1e-9))
        offset=0;index=[]
        for clip,record in zip(clips,clip_records):
            index.append({'startFrame':offset,'frames':len(clip),'provenance':record});offset+=len(clip)
        pcm=np.concatenate(clips)*gain
        folder=OUT/style;folder.mkdir(exist_ok=True)
        wav=folder/'samples.wav';sf.write(wav,pcm,RATE,subtype='PCM_16')
        fallback_names=[n for n in ['KeyA','KeyS','KeyD'] if keys[n]['up']]
        if not fallback_names:fallback_names=['KeyA','KeyS','KeyD']
        # Keep the same down/up variant identity. Do not pair a complete one-shot
        # from one key with the release from a different key by modulo accident.
        generic={'down':[keys[n]['down'][0] for n in fallback_names],
                 'up':[keys[n]['up'][0] for n in fallback_names if keys[n]['up']]}
        if style=='panda':generic={'down':generic_down,'up':[generic_up]}
        if curated: generic=curated_fallback
        mac={}
        for code,name in MAC.items():
            fallback='Enter' if name=='NumpadEnter' else 'ControlLeft' if name in ['MetaLeft','MetaRight'] else 'KeyA'
            pair=keys.get(name,keys.get(fallback,generic))
            mac[str(code)]={'down':pair['down'],'up':pair['up'],
                            'sourceKey':pair.get('sourceKey',name if name in keys else fallback)}
        pack={'title':NAMES[style],'sampleRate':RATE,'channels':2,'file':style+'/samples.wav',
              'sha256':sha(wav),'frames':len(pcm),'gain':gain,'sourceMedianPeak':median,'sourceMaximumPeak':all_peak,
              'outputMaximumPeak':float(np.max(np.abs(pcm))),'clips':index,'keys':mac,'fallback':generic,
              'separateReleaseKeys':sum(bool(v['up']) for v in mac.values()),'mappedKeys':len(mac)}
        if curated:
            pack.update({key: curated[key] for key in ('titleZh', 'category')})
        all_packs[style]=pack;reports[style]=report
        print(style,'clips',len(clips),'mapped',len(mac),'separate-up',pack['separateReleaseKeys'],
              'gain',round(gain,3),'peak',round(pack['outputMaximumPeak'],3),'MB',round(wav.stat().st_size/1e6,2))
    source_rows=previous['sources']+incoming_sources if previous else incoming_sources
    # Re-running an incremental build must not duplicate provenance or discard
    # previously approved packs that live in another pinned source folder.
    sources=list({(row['url'],row['file']):row for row in source_rows}.values())
    manifest={'schema':1,'sampleRate':RATE,'packs':all_packs,
              'processing':['48kHz polyphase resampling','stereo preserved; mono duplicated','quiet leading/trailing trim',
                            '0.3ms/1.5ms edge fades','one gain per keyboard; no per-key normalization',
                            'no synthesis, pitch shift, EQ, compression, or source-model relabeling'],
              'sources':sources}
    (OUT/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
    (QA/'waveform-split-report.json').write_text(json.dumps(reports,indent=2)+'\n')
    for name in ['Mechvibes-LICENSE','kbsim-LICENSE.md']:
        if (SOURCE/name).exists():shutil.copy2(SOURCE/name,OUT/name)
    (OUT/'SOURCE-FILES.json').write_text(json.dumps(sources,indent=2,ensure_ascii=False)+'\n')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=SOURCE)
    parser.add_argument('--qa',type=Path,default=QA)
    parser.add_argument('--packs',nargs='+',choices=list(NAMES))
    parser.add_argument('--merge',action='store_true',help='Preserve other packs (the default); retained for existing build commands.')
    parser.add_argument('--replace-manifest',action='store_true',help='Explicitly replace the catalogue with only the selected source packs.')
    arguments=parser.parse_args()
    SOURCE=arguments.source.resolve();QA=arguments.qa.resolve();QA.mkdir(parents=True,exist_ok=True)
    prepare(arguments.packs,not arguments.replace_manifest)

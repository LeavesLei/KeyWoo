import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import warnings
import zipfile

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pack_assets', REPO/'scripts/pack-assets.py')
pack = importlib.util.module_from_spec(spec); spec.loader.exec_module(pack)
prepare = pack.safety

class AssetScriptsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='keywoo-asset-tests-')
        self.base = Path(self.tmp.name)
        self.source = self.base/'source'; self.source.mkdir()
        self.output = self.base/'parts'
        self.target = self.base/'target'; self.target.mkdir()
        self.paths = list(prepare.ICONS)+[prepare.AUDIO_ROOTS[0]+'red/samples.wav', prepare.AUDIO_ROOTS[1]+'song.wav']
        for i, relative in enumerate(self.paths):
            p=self.source/relative; p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(b'fixture-'+bytes([i])+hashlib.sha512(str(i).encode()).digest()*40)
        text=self.source/'Sources/KeyDance/Resources/KeyboardSounds/LICENSE'; text.write_text('Original license text, never in ZIP')
        script=self.source/'scripts/code.py';script.parent.mkdir();script.write_text('unmodified code')
        pack.pack(self.source,self.output,part_size=512)
        self.manifest=json.loads((self.output/'manifest.json').read_text())
    def tearDown(self): self.tmp.cleanup()
    def save_manifest(self): (self.output/'manifest.json').write_text(json.dumps(self.manifest))
    def archive_bytes(self): return b''.join((self.output/p['file']).read_bytes() for p in self.manifest['parts'])
    def replace_archive(self, data):
        parts=[]
        for i in range(0,len(data),512):
            name='keywoo-assets-%03d.part'%(i//512+1);part=data[i:i+512];(self.output/name).write_bytes(part)
            parts.append(dict(file=name,bytes=len(part),sha256=hashlib.sha256(part).hexdigest()))
        self.manifest['parts']=parts
        self.manifest['archive']=dict(format='zip',bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        self.save_manifest()
    def rewrite_zip(self, mutator):
        source=zipfile.ZipFile(io.BytesIO(self.archive_bytes())); dest=io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore',UserWarning)
            with zipfile.ZipFile(dest,'w',compression=zipfile.ZIP_DEFLATED) as output:
                for i,item in enumerate(source.infolist()):
                    name, mode, data=mutator(i,item.filename,item.external_attr,source.read(item))
                    info=zipfile.ZipInfo(name,(1980,1,1,0,0,0));info.external_attr=mode
                    output.writestr(info,data)
        self.replace_archive(dest.getvalue())
    def assert_empty_target(self): self.assertEqual(list(self.target.rglob('*')),[])

    def test_deterministic_archive_fixed_metadata_and_whitelist(self):
        for p in self.source.rglob('*'):
            if p.is_file(): os.utime(p,(1_700_000_000,1_700_000_000))
        second=self.base/'second';pack.pack(self.source,second,part_size=512)
        self.assertEqual((self.output/'manifest.json').read_bytes(),(second/'manifest.json').read_bytes())
        for part in self.manifest['parts']:
            self.assertEqual((self.output/part['file']).read_bytes(),(second/part['file']).read_bytes())
        with zipfile.ZipFile(io.BytesIO(self.archive_bytes())) as archive:
            self.assertEqual(sorted(archive.namelist()),sorted(self.paths))
            for entry in archive.infolist():
                self.assertEqual(entry.date_time,(1980,1,1,0,0,0));self.assertEqual(entry.external_attr>>16,stat.S_IFREG|0o644)

    def test_roundtrip_then_fast_skip_without_parts_preserves_text(self):
        code=self.target/'scripts/code.py';code.parent.mkdir();code.write_text('preserved code')
        license_file=self.target/'Sources/KeyDance/Resources/KeyboardSounds/LICENSE';license_file.parent.mkdir(parents=True);license_file.write_text('preserved license')
        result=prepare.prepare(self.target,self.output)
        self.assertEqual(result['status'],'prepared');self.assertEqual(result['replaced'],len(self.paths))
        for relative in self.paths:self.assertEqual((self.target/relative).read_bytes(),(self.source/relative).read_bytes())
        for part in self.manifest['parts']:(self.output/part['file']).unlink()
        self.assertEqual(prepare.prepare(self.target,self.output)['status'],'verified')
        self.assertEqual(code.read_text(),'preserved code');self.assertEqual(license_file.read_text(),'preserved license')

    def test_corrupt_part_fails_before_any_destination_replacement(self):
        existing=self.target/self.paths[0];existing.parent.mkdir(parents=True);existing.write_bytes(b'keep this failed-build source')
        p=self.output/self.manifest['parts'][0]['file'];data=bytearray(p.read_bytes());data[len(data)//2]^=1;p.write_bytes(data)
        with self.assertRaisesRegex(prepare.AssetError,'part checksum'):prepare.prepare(self.target,self.output)
        self.assertEqual(existing.read_bytes(),b'keep this failed-build source')
        self.assertFalse((self.target/self.paths[1]).exists())

    def test_complete_zip_hash_is_checked_independently(self):
        self.manifest['archive']['sha256']='0'*64;self.save_manifest()
        with self.assertRaisesRegex(prepare.AssetError,'Complete asset ZIP'):prepare.prepare(self.target,self.output)
        self.assert_empty_target()

    def test_extracted_file_hash_is_checked_before_any_install(self):
        self.manifest['files'][1]['sha256']='0'*64;self.save_manifest()
        with self.assertRaisesRegex(prepare.AssetError,'Extracted asset checksum'):prepare.prepare(self.target,self.output)
        self.assert_empty_target()

    def test_zip_cannot_replace_code_even_with_valid_outer_hashes(self):
        self.rewrite_zip(lambda i,n,m,d:('scripts/evil.py',m,d) if i==0 else(n,m,d))
        with self.assertRaisesRegex(prepare.AssetError,'whitelist'):prepare.prepare(self.target,self.output)
        self.assert_empty_target()

    def test_zip_slip_is_rejected_before_extraction(self):
        self.rewrite_zip(lambda i,n,m,d:('../escaped.wav',m,d) if i==0 else(n,m,d))
        with self.assertRaises(prepare.AssetError):prepare.prepare(self.target,self.output)
        self.assertFalse((self.base/'escaped.wav').exists());self.assert_empty_target()

    def test_zip_symlink_is_rejected_before_extraction(self):
        self.rewrite_zip(lambda i,n,m,d:(n,(stat.S_IFLNK|0o777)<<16,d) if i==0 else(n,m,d))
        with self.assertRaisesRegex(prepare.AssetError,'links'):prepare.prepare(self.target,self.output)
        self.assert_empty_target()

    def test_duplicate_zip_entries_are_rejected(self):
        first=self.manifest['files'][0]['path']
        self.rewrite_zip(lambda i,n,m,d:(first,m,d) if i==1 else(n,m,d))
        with self.assertRaisesRegex(prepare.AssetError,'duplicate'):prepare.prepare(self.target,self.output)
        self.assert_empty_target()

    @unittest.skipUnless(hasattr(os,'symlink'),'symlinks unavailable')
    def test_target_parent_and_part_symlinks_are_rejected(self):
        outside=self.base/'outside';outside.mkdir();(self.target/'Sources').symlink_to(outside,target_is_directory=True)
        with self.assertRaisesRegex(prepare.AssetError,'symlink'):prepare.prepare(self.target,self.output)
        self.assertEqual(list(outside.iterdir()),[])
        (self.target/'Sources').unlink()
        p=self.output/self.manifest['parts'][0]['file'];real=self.base/'saved.part';p.rename(real);p.symlink_to(real)
        with self.assertRaisesRegex(prepare.AssetError,'regular file'):prepare.prepare(self.target,self.output)
        self.assert_empty_target()

    @unittest.skipUnless(hasattr(os,'symlink'),'symlinks unavailable')
    def test_packer_refuses_input_links(self):
        path=self.source/self.paths[1];real=self.base/'real.wav';path.rename(real);path.symlink_to(real)
        with self.assertRaises(prepare.AssetError):pack.pack(self.source,self.base/'not-created')
        self.assertFalse((self.base/'not-created/manifest.json').exists())

    def test_platform_path_aliases_and_code_extensions_are_rejected(self):
        for path in ['/etc/passwd','../out.wav','Sources/KeyDance/Resources/Music/../evil.wav',
                     'Sources\\KeyDance\\Resources\\Music\\x.wav','Sources/KeyDance/Resources/Music/CON.wav',
                     'Sources/KeyDance/Resources/Music/a.wav:code','Sources/KeyDance/Resources/Music/./x.wav',
                     'Sources/KeyDance/Resources/Music/x.swift','Resources/Other.png',
                     'Sources/KeyDance/Resources/Music/x\x00.wav','Sources/KeyDance/Resources/Music/dot./x.wav']:
            with self.subTest(path=path), self.assertRaises(prepare.AssetError):prepare.checked_path(path)

    def test_manifest_duplicate_keys_case_collision_and_check_only(self):
        with self.assertRaisesRegex(prepare.AssetError,'Missing or mismatched'):prepare.prepare(self.target,self.output,check_only=True)
        self.assert_empty_target()
        file=dict(self.manifest['files'][1]);file['path']=file['path'].replace('samples.wav','SAMPLES.wav')
        self.manifest['files'].append(file);self.manifest['files'].sort(key=lambda x:x['path']);self.save_manifest()
        with self.assertRaisesRegex(prepare.AssetError,'case-colliding'):prepare.load_manifest(self.output)
        (self.output/'manifest.json').write_text('{"schema":1,"schema":1}')
        with self.assertRaisesRegex(prepare.AssetError,'Duplicate JSON'):prepare.load_manifest(self.output)

if __name__=='__main__':unittest.main(verbosity=2)

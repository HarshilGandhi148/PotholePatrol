"""Static project checks; optional tree-sitter Swift syntax validation, never an Xcode build."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--swift-parser-path', help='Optional directory containing tree_sitter and tree_sitter_swift')
args = parser.parse_args()
project_dir = Path(__file__).resolve().parents[1]
repo = project_dir.parents[1]
app = project_dir / 'YOLOiOSApp'
project = (project_dir / 'YOLOiOSApp.xcodeproj/project.pbxproj').read_text(encoding='utf-8-sig')
sources = sorted((app / 'Patrol').glob('*.swift'))
ids = re.findall(r'^\t\t([A-F0-9]{24})(?: /\*.*?\*/)? = \{', project, re.M)
assert len(ids) == len(set(ids)), 'Duplicate project IDs'
assert set(re.findall(r'\b[A-F0-9]{24}\b', project)) <= set(ids), 'Dangling project reference'
for source in sources:
    ref = re.search(r'([A-F0-9]{24}) /\* ' + re.escape(source.name) + r' \*/ = \{isa = PBXFileReference;.*?path = Patrol/' + re.escape(source.name) + r';', project)
    assert ref, f'Missing file reference: {source.name}'
    assert f'/* {source.name} in Sources */,' in project, f'Missing compile source: {source.name}'
    assert f'{ref[1]} /* {source.name} */,' in project, f'Missing app group entry: {source.name}'
print(f'PASS: {len(sources)} app Swift files referenced in target, with no dangling or duplicate project IDs')
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['NSCameraUsageDescription'] and info['NSLocationWhenInUseUsageDescription']
assert info['CFBundleDisplayName'] == 'Pothole Patrol'
assert 'UIMainStoryboardFile' not in info
for scene in info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication']:
    assert 'UISceneStoryboardFile' not in scene
assert 'NSAppTransportSecurity' not in info, 'Do not add blanket transport exceptions'
print('PASS: permission plist, native root startup, HTTPS transport policy')
model = project_dir / 'Models/Detect/pothole-yolo11n.mlpackage'
manifest = json.loads((model / 'Manifest.json').read_text())
assert (model / 'Data/com.apple.CoreML/weights/weight.bin').stat().st_size > 1_000_000
print('PASS: selected YOLO11n resources exist')
for path in [app / 'SceneDelegate.swift', app / 'AppDelegate.swift', *sources]:
    assert 'ngrok-free.app' not in path.read_text(encoding='utf-8-sig'), 'Do not bundle the temporary backend URL'
for name in ['CitizenViews.swift', 'DetectionReviewView.swift', 'LiveScannerView.swift']:
    text = (app / 'Patrol' / name).read_text(encoding='utf-8-sig')
    assert '.priority.' not in text and '.setStatus(' not in text, 'Staff fields/actions in citizen view'
    assert 'seeclickfix.com' not in text, 'Agency links come from the backend send plan'
print('PASS: citizen/staff presentation separation; no bundled ngrok URL or legacy reporting flow')
if args.swift_parser_path:
    sys.path.insert(0, args.swift_parser_path)
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    swift = Parser(Language(tree_sitter_swift.language()))
    files = [app / 'SceneDelegate.swift', app / 'AppDelegate.swift', *sources, project_dir / 'Validation/ContractChecks.swift']
    errors = []
    for path in files:
        tree = swift.parse(path.read_bytes())
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == 'ERROR' or node.is_missing:
                errors.append(f'{path.name}:{node.start_point.row + 1} {node.type}')
            stack.extend(node.children)
    assert not errors, '\n'.join(errors)
    print(f'PASS: Swift syntax parser, {len(files)} files, no parse errors (not type checking)')
else:
    print('SKIP: optional Swift syntax parser; supply --swift-parser-path to enable')
print('Xcode compilation, API harness execution, signing, camera, and device behavior require macOS/iPhone validation.')

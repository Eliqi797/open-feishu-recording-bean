"""Create a NEW ordinary-app workspace from the user's installed/cached DevEco project.
Does not download SDKs/dependencies, copy signing material, or overwrite a project.
"""
import argparse
import json
import shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('baseline',type=Path);p.add_argument('destination',type=Path);args=p.parse_args()
if args.destination.exists():p.error('目标目录已存在；不会覆盖')
ignored=shutil.ignore_patterns('build','.hvigor','.git','.idea','local.properties','*.p12','*.p7b','*.cer','build-profile.json5')
# Root build profile is always sanitized. Module build profiles contain no signing config.
shutil.copytree(args.baseline,args.destination,ignore=ignored)
for source in args.baseline.glob('*/build-profile.json5'):
 shutil.copy2(source,args.destination/source.relative_to(args.baseline))
shutil.copy2(ROOT/'harmony/project/build-profile.template.json5',args.destination/'build-profile.json5')
base=args.destination/'entry/src/main/ets'
shutil.copytree(ROOT/'harmony/entry/src/main/ets',base,dirs_exist_ok=True)
shutil.copytree(ROOT/'harmony/standard-overlay',base,dirs_exist_ok=True)
shutil.copytree(ROOT/'harmony/resources',args.destination/'entry/src/main/resources',dirs_exist_ok=True)
shutil.copy2(ROOT/'harmony/project/AppScope/resources/base/media/app_icon.png',args.destination/'AppScope/resources/base/media/app_icon.png')
p=args.destination/'AppScope/app.json5';data=json.loads(p.read_text());data['app']['bundleType']='app';data['app']['bundleName']='com.example.recordingbean.app';p.write_text(json.dumps(data,ensure_ascii=False,indent=2))
p=args.destination/'entry/src/main/module.json5';data=json.loads(p.read_text());data['module']['installationFree']=False
for ability in data['module']['abilities']:
 ability['icon']='$media:recordingbean_white';ability['startWindowIcon']='$media:recordingbean_white'
for name in ['ohos.permission.SET_WIFI_INFO','ohos.permission.GET_WIFI_INFO','ohos.permission.GET_NETWORK_INFO']:
 if not any(x['name']==name for x in data['module']['requestPermissions']):data['module']['requestPermissions'].append({'name':name})
p.write_text(json.dumps(data,ensure_ascii=False,indent=2))
for relative,key in [('entry/src/main/resources/base/element/string.json','EntryAbility_label'),('AppScope/resources/base/element/string.json','app_name')]:
 p=args.destination/relative;data=json.loads(p.read_text())
 for item in data['string']:
  if item['name']==key:item['value']='录音豆'
 p.write_text(json.dumps(data,ensure_ascii=False,indent=2))
print(args.destination)
